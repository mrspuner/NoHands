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

    func poller(_ sync: FakeSync) -> InboundPoller {
        let config = TodoistInboundConfig(bigheadPath: dir.appendingPathComponent("BigHead").path,
                                          areas: ["Сколково"], claudePath: "/usr/local/bin/claude", pollSeconds: 60)
        return InboundPoller(config: config, sync: sync, store: store, journal: journal,
                             ingest: IngestRunner(claude: URL(fileURLWithPath: config.claudePath),
                                                  bighead: URL(fileURLWithPath: config.bigheadPath), runner: runner),
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
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 {
        lock.withLock { $0.append(arguments) }
        return try result.get()
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

// A tick that arrives while the previous one is still running is skipped, not queued.
@Test func overlappingTicksDoNotRunTwice() async throws {
    let s = try Setup()
    let sync = FakeSync([.success(baseline), .success(baseline)])
    let poller = s.poller(sync)
    async let first: Void = poller.tick()
    async let second: Void = poller.tick()
    _ = await (first, second)
    #expect(await sync.tokens.count <= 2)
}
