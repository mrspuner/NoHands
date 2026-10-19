import Core
import Foundation
import os
import Testing
@testable import TodoistSync

private actor FakeSync: TodoistSyncing {
    var responses: [Result<SyncResponse, any Error>]
    var tokens: [String] = []
    init(_ responses: [Result<SyncResponse, any Error>]) { self.responses = responses }
    func sync(token: String) async throws -> SyncResponse {
        tokens.append(token)
        return try responses.removeFirst().get()
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String?]())
    func add(_ value: String?) { lock.withLock { $0.append(value) } }
    var all: [String?] { lock.withLock { $0 } }
}

private struct Setup {
    let dir: URL
    let raw: URL
    let store: SyncStateStore
    let journal: ActionJournal
    let runner: RecordingRunner
    let reports = Reports()

    init(exit: Result<Int32, any Error> = .success(0)) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("poll-\(UUID().uuidString)")
        raw = dir.appendingPathComponent("BigHead/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        store = SyncStateStore(url: dir.appendingPathComponent("state.json"))
        journal = ActionJournal(url: dir.appendingPathComponent("journal.jsonl"))
        runner = RecordingRunner(exit)
    }

    func config(areas: [String] = ["Сколково"]) -> TodoistInboundConfig {
        TodoistInboundConfig(bigheadPath: dir.appendingPathComponent("BigHead").path,
                             areas: areas, claudePath: "/usr/local/bin/claude", pollSeconds: 60)
    }

    func poller(_ sync: any TodoistSyncing) -> InboundPoller {
        let config = config()
        return InboundPoller(config: config, sync: sync, store: store, journal: journal,
                             ingest: IngestRunner(claude: URL(fileURLWithPath: config.claudePath),
                                                  bighead: URL(fileURLWithPath: config.bigheadPath),
                                                  agent: BigHeadAgent(runner: runner, pidFile: nil)),
                             report: { [reports] in reports.add($0) })
    }

    var rawFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []).sorted()
    }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<Int32, any Error>
    private let lock = OSAllocatedUnfairLock(initialState: [[String]]())
    init(_ result: Result<Int32, any Error>) { self.result = result }
    var calls: [[String]] { lock.withLock { $0 } }
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun {
        lock.withLock { $0.append(arguments) }
        let code = try result.get()
        return AgentRun(exitCode: code, result: code == 0 ? .init(isError: false, terminalReason: "completed") : nil,
                        stderrLine: nil)
    }
}

private let projects = [
    SyncProject(id: "a", name: "Сколково", parentID: nil, isArchived: false, isDeleted: false),
    SyncProject(id: "k", name: "Хибины", parentID: "a", isArchived: false, isDeleted: false),
]
private func closedItem(_ id: String) -> SyncItem {
    SyncItem(id: id, content: "T", description: nil, dueDate: nil, projectID: "k", checked: true, isDeleted: false,
             addedAt: nil, updatedAt: "2026-10-07T15:00:00.000000Z")
}
private let baseline = SyncResponse(syncToken: "t1", fullSync: true, items: [closedItem("old")], projects: projects)

// The very first poll only learns where things are: every existing task would otherwise
// arrive in BigHead as new.
@Test func theFirstPollIsABaselineWithoutEvents() async throws {
    let s = try Setup()
    await s.poller(FakeSync([.success(baseline)])).tick()
    #expect(s.rawFiles.isEmpty)
    #expect(s.runner.calls.isEmpty)
    let state = try await s.store.load()
    #expect(state.syncToken == "t1")
    #expect(state.projects["k"]?.name == "Хибины")
    #expect(s.reports.all == [nil])
    // Only non-deleted items placed inside an area are remembered as work.
    #expect(state.workItems == ["old"])
}

@Test func theBaselineSeedsWorkItemsAndTheirDeletionIsHeard() async throws {
    let s = try Setup()
    let personal = SyncItem(id: "p", content: "x", description: nil, dueDate: nil, projectID: "home", checked: false,
                            isDeleted: false, addedAt: nil, updatedAt: nil)
    let seeded = SyncResponse(syncToken: "t1", fullSync: true, items: [closedItem("w"), personal],
                              projects: projects + [SyncProject(id: "home", name: "Дом", parentID: nil, isArchived: false, isDeleted: false)])
    let tomb = { (id: String) in SyncItem(id: id, content: "", description: nil, dueDate: nil, projectID: "gone", checked: false,
                                          isDeleted: true, addedAt: nil, updatedAt: nil) }
    let poller = s.poller(FakeSync([.success(seeded), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [tomb("w"), tomb("p")], projects: []))]))
    await poller.tick()
    #expect(try await s.store.load().workItems == ["w"])
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    let text = try String(contentsOf: s.raw.appendingPathComponent(s.rawFiles[0]), encoding: .utf8)
    #expect(text.contains("- event: deleted\n  id: w\n"))
    #expect(!text.contains("id: p"))
    #expect(try await s.store.load().workItems == [])
}

@Test func changesAreWrittenAndIngested() async throws {
    let s = try Setup()
    let sync = FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [closedItem("1")], projects: []))])
    let poller = s.poller(sync)
    await poller.tick()
    await poller.tick()
    #expect(await sync.tokens == ["*", "t1"])
    #expect(s.rawFiles.count == 1)
    #expect(s.rawFiles[0].contains("-todoist-"))
    #expect(s.runner.calls.count == 1)
    #expect(s.runner.calls[0][1].contains("raw/\(s.rawFiles[0])"))
    #expect(try await s.store.load().syncToken == "t2")
}

@Test func nothingChangedMeansNoFileAndNoIngest() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
    #expect(s.runner.calls.isEmpty)
}

// Todoist resets the token with a full sync: treated as a new baseline, never as news.
@Test func aFullSyncLaterIsAlsoABaseline() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t9", fullSync: true, items: [closedItem("1")], projects: projects))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
    #expect(try await s.store.load().syncToken == "t9")
}

@Test func newProjectsGoToTheirOwnFileWithoutIngest() async throws {
    let s = try Setup()
    let added = SyncProject(id: "n", name: "Новый", parentID: "a", isArchived: false, isDeleted: false)
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: [added]))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    #expect(s.rawFiles[0].contains("-todoist-project-"))
    #expect(s.runner.calls.isEmpty)
}

// The file and the token are kept even when the agent fails: the file stays unprocessed and
// BigHead picks it up in the next conversation.
@Test func aFailedIngestIsReportedAndNothingIsLost() async throws {
    let s = try Setup(exit: .success(1))
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [closedItem("1")], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    #expect(try await s.store.load().syncToken == "t2")
    #expect(s.reports.all.last??.contains("ingest") == true)
}

@Test func aFailedSyncKeepsTheTokenAndReports() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .failure(URLError(.notConnectedToInternet)),
                                    .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(try await s.store.load().syncToken == "t1")
    #expect(s.reports.all.last! != nil)
    await poller.tick()
    #expect(s.reports.all.last! == nil)
}

@Test func ownChangesNeverReachBigHead() async throws {
    let s = try Setup()
    try await s.journal.record(action: "task.closed", todoistID: "1", name: nil)
    let echo = SyncItem(id: "1", content: "T", description: nil, dueDate: nil, projectID: "k", checked: true, isDeleted: false,
                        addedAt: nil, updatedAt: "2020-01-01T00:00:00.000000Z")
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [echo], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
}

// «Перечитать конфиг» must reach the running poller: areas change from the next tick on.
@Test func updatedConfigChangesTheAreas() async throws {
    let s = try Setup()
    let all = projects + [
        SyncProject(id: "r", name: "RooX", parentID: nil, isArchived: false, isDeleted: false),
        SyncProject(id: "rp", name: "Проект", parentID: "r", isArchived: false, isDeleted: false),
    ]
    func item(_ id: String, _ project: String) -> SyncItem {
        SyncItem(id: id, content: "T", description: nil, dueDate: nil, projectID: project, checked: true,
                 isDeleted: false, addedAt: nil, updatedAt: "2026-10-07T15:00:00.000000Z")
    }
    let base = SyncResponse(syncToken: "t1", fullSync: true, items: [], projects: all)
    let next = SyncResponse(syncToken: "t2", fullSync: false, items: [item("s", "k"), item("r1", "rp")], projects: [])
    let poller = s.poller(FakeSync([.success(base), .success(next)]))
    await poller.tick()
    await poller.update(config: s.config(areas: ["RooX"]))
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    let text = try String(contentsOf: s.raw.appendingPathComponent(s.rawFiles[0]), encoding: .utf8)
    #expect(text.contains("RooX"))
    #expect(!text.contains("Сколково"))
}

// Nothing new: the state file is not rewritten.
@Test func anUnchangedEmptyPollDoesNotSaveState() async throws {
    let s = try Setup()
    let same = SyncResponse(syncToken: "t1", fullSync: false, items: [], projects: [])
    let poller = s.poller(FakeSync([.success(baseline), .success(same)]))
    await poller.tick()
    let stateURL = s.dir.appendingPathComponent("state.json")
    let old = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stateURL.path)
    await poller.tick()
    let after = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date
    #expect(after == old)
}

// A tick that arrives while the previous one is still running is skipped, not queued.
@Test func overlappingTicksDoNotRunTwice() async throws {
    let s = try Setup()
    let sync = GatedSync(baseline)
    let poller = s.poller(sync)
    let first = Task { await poller.tick() }
    await sync.waitForFirstCall()
    await poller.tick()  // returns at once: the first tick still holds the poll
    #expect(await sync.calls == 1)
    await sync.release()
    await first.value
    #expect(await sync.calls == 1)
}

private actor GatedSync: TodoistSyncing {
    let response: SyncResponse
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var released = false
    init(_ response: SyncResponse) { self.response = response }
    func sync(token: String) async throws -> SyncResponse {
        calls += 1
        entered?.resume()
        entered = nil
        if calls == 1, !released { await withCheckedContinuation { gate = $0 } }
        return response
    }
    func waitForFirstCall() async {
        if calls == 0 { await withCheckedContinuation { entered = $0 } }
    }
    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

@Test func aTokenResetKeepsRememberedWorkItems() async throws {
    let s = try Setup()
    try await s.store.saveSync(token: "t0", projects: [:], workItems: ["closedOne"])
    let item = SyncItem(id: "a", content: "x", description: nil, dueDate: nil, projectID: "k", checked: false,
                        isDeleted: false, addedAt: nil, updatedAt: nil)
    await s.poller(FakeSync([.success(SyncResponse(syncToken: "t9", fullSync: true, items: [item], projects: projects))])).tick()
    #expect(Set(try await s.store.load().workItems) == ["closedOne", "a"])
}
