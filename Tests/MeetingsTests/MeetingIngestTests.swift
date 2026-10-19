import Core
import Foundation
import os
import Testing
@testable import Meetings

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let bighead = URL(fileURLWithPath: "/Users/x/BigHead")
private let settings = MeetingIngest.Settings(claude: claude, bighead: bighead, timeout: 900)
/// Long before every fixture name, so `enabledAt` cuts nothing unless a test says otherwise.
private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

private let meeting = """
---
date: 2026-10-19
---

## Саммари
Обсудили релиз.

## Транскрипт
[00:00:01] Я: привет
"""

/// Holds runs until opened, so a test can stack scans while the agent is busy.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Records every launch and answers by file name: names in `failing` exit with code 1.
private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var directory: URL
    }

    private let failing: Set<String>
    private let gate: Gate?
    private let state = OSAllocatedUnfairLock(initialState: [Call]())
    /// Called once a launch is recorded, before the gate; lets a test act while the agent is busy.
    var onRun: (@Sendable (String) -> Void)?

    init(failing: Set<String> = [], gate: Gate? = nil) {
        self.failing = failing
        self.gate = gate
    }

    var calls: [Call] { state.withLock { $0 } }
    /// File names in launch order, read back from the prompt.
    var files: [String] {
        calls.compactMap { call in
            call.arguments.dropFirst().first.flatMap { prompt in
                prompt.split(separator: " ").first { $0.hasSuffix(".md") }
                    .map { URL(fileURLWithPath: String($0)).lastPathComponent }
            }
        }
    }

    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun {
        state.withLock { $0.append(Call(arguments: arguments, directory: directory)) }
        let name = files.last ?? ""
        onRun?(name)
        await gate?.wait()
        if failing.contains(name) {
            return AgentRun(exitCode: 1, result: nil, stderrLine: "boom")
        }
        return AgentRun(exitCode: 0, result: AgentResult(isError: false, terminalReason: nil), stderrLine: nil)
    }
}

private final class Reports: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [MeetingIngest.Outcome]())
    var all: [MeetingIngest.Outcome] { state.withLock { $0 } }
    func add(_ outcome: MeetingIngest.Outcome) { state.withLock { $0.append(outcome) } }
}

private struct Fixture {
    let archive: URL
    let stateURL: URL
    let store: MeetingIngestStore
    let runner: FakeRunner
    let reports = Reports()
    let ingest: MeetingIngest

    init(files: [String: String], runner: FakeRunner = FakeRunner(), now: Date = longAgo,
         settings: MeetingIngest.Settings? = settings) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        archive = root.appendingPathComponent("Meetings")
        stateURL = root.appendingPathComponent("meeting-ingest-state.json")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: archive.appendingPathComponent(name))
        }
        store = MeetingIngestStore(url: stateURL, now: { now })
        self.runner = runner
        let reports = reports
        ingest = MeetingIngest(archive: archive, store: store,
                               agent: BigHeadAgent(runner: runner, pidFile: nil),
                               settings: settings, report: { reports.add($0) })
    }

    func scanned() async {
        await ingest.scan()
        await ingest.waitUntilIdle()
    }

    func handedOver() async throws -> [String] { try await store.load().handedOver }
}

@Test func aSummarizedMeetingIsHandedOverOnce() async throws {
    let fixture = try Fixture(files: ["2026-10-19-1430-telemost.md": meeting])
    await fixture.scanned()

    let file = fixture.archive.appendingPathComponent("2026-10-19-1430-telemost.md")
    #expect(fixture.runner.calls == [FakeRunner.Call(
        arguments: MeetingIngest.arguments(file: file, meetings: fixture.archive), directory: bighead)])
    #expect(try await fixture.handedOver() == ["2026-10-19-1430-telemost.md"])
    #expect(fixture.reports.all == [MeetingIngest.Outcome(file: "2026-10-19-1430-telemost.md", failure: nil)])

    await fixture.scanned()
    await fixture.scanned()
    #expect(fixture.runner.calls.count == 1)
}

@Test func filesWithoutSummaryOrHeadingAreSkipped() async throws {
    let noSummary = meeting.replacingOccurrences(of: "## Саммари\n", with: "")
    let note = "## Саммари\nзаметка без транскрипта\n"
    let fixture = try Fixture(files: [
        "2026-10-19-1430-telemost.md": noSummary,
        "2026-10-19-1500-notes.md": note,
    ])
    await fixture.scanned()
    #expect(fixture.runner.calls.isEmpty)
    #expect(fixture.reports.all.isEmpty)
}

@Test func meetingsBeforeEnabledAtAreSkipped() async throws {
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 10, 19, 12, 0)
    let enabledAt = try #require(Calendar.current.date(from: parts))
    let fixture = try Fixture(files: [
        "2026-10-19-1130-zoom.md": meeting,
        "2026-10-19-1200-zoom.md": meeting,
        "notes.md": meeting,
    ], now: enabledAt)
    await fixture.scanned()
    #expect(fixture.runner.files == ["2026-10-19-1200-zoom.md"])
}

@Test func theTimestampIsReadInTheLocalZone() throws {
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 10, 19, 14, 30)
    #expect(MeetingIngest.timestamp(ofName: "2026-10-19-1430-telemost.md") == Calendar.current.date(from: parts))
    #expect(MeetingIngest.timestamp(ofName: "notes.md") == nil)
    #expect(MeetingIngest.timestamp(ofName: "2026-10-19.md") == nil)
}

@Test func oldestFirst() async throws {
    let fixture = try Fixture(files: [
        "2026-10-21-0900-zoom.md": meeting,
        "2026-10-19-1430-telemost.md": meeting,
        "2026-10-20-1000-zoom.md": meeting,
    ])
    await fixture.scanned()
    #expect(fixture.runner.files == [
        "2026-10-19-1430-telemost.md", "2026-10-20-1000-zoom.md", "2026-10-21-0900-zoom.md",
    ])
}

@Test func repeatedScansDoNotDuplicate() async throws {
    let gate = Gate()
    let fixture = try Fixture(files: [
        "2026-10-19-1430-telemost.md": meeting,
        "2026-10-20-1000-zoom.md": meeting,
    ], runner: FakeRunner(gate: gate))
    await fixture.ingest.scan()
    await fixture.ingest.scan()
    await fixture.ingest.scan()
    await gate.release()
    await fixture.ingest.waitUntilIdle()
    await fixture.scanned()
    #expect(fixture.runner.files == ["2026-10-19-1430-telemost.md", "2026-10-20-1000-zoom.md"])
}

@Test func aFailureIsReportedNotMarkedAndNotRetriedThisSession() async throws {
    let name = "2026-10-19-1430-telemost.md"
    let fixture = try Fixture(files: [name: meeting], runner: FakeRunner(failing: [name]))
    await fixture.scanned()
    #expect(fixture.reports.all == [MeetingIngest.Outcome(file: name, failure: .exitCode(1))])
    #expect(try await fixture.handedOver() == [])

    await fixture.scanned()
    #expect(fixture.runner.calls.count == 1)

    await fixture.ingest.clearFailures()
    await fixture.scanned()
    #expect(fixture.runner.calls.count == 2)
}

@Test func aFailureDoesNotStopTheRest() async throws {
    let fixture = try Fixture(files: [
        "2026-10-19-1430-telemost.md": meeting,
        "2026-10-20-1000-zoom.md": meeting,
    ], runner: FakeRunner(failing: ["2026-10-19-1430-telemost.md"]))
    await fixture.scanned()
    #expect(fixture.runner.files == ["2026-10-19-1430-telemost.md", "2026-10-20-1000-zoom.md"])
    #expect(try await fixture.handedOver() == ["2026-10-20-1000-zoom.md"])
}

@Test func aFileGoneBeforeItsTurnIsNotRun() async throws {
    let gate = Gate()
    let runner = FakeRunner(gate: gate)
    let fixture = try Fixture(files: [
        "2026-10-19-1430-telemost.md": meeting,
        "2026-10-20-1000-zoom.md": meeting,
    ], runner: runner)
    let second = fixture.archive.appendingPathComponent("2026-10-20-1000-zoom.md")
    // Removed while the first file's run is in flight: the second is already queued by then.
    runner.onRun = { name in
        if name == "2026-10-19-1430-telemost.md" { try? FileManager.default.removeItem(at: second) }
    }
    await fixture.ingest.scan()
    await gate.release()
    await fixture.ingest.waitUntilIdle()
    #expect(runner.files == ["2026-10-19-1430-telemost.md"])
    #expect(try await fixture.handedOver() == ["2026-10-19-1430-telemost.md"])
}

@Test func aCorruptStateReportsAndRunsNothing() async throws {
    let fixture = try Fixture(files: ["2026-10-19-1430-telemost.md": meeting])
    try Data("{ not json".utf8).write(to: fixture.stateURL)
    await fixture.scanned()
    #expect(fixture.runner.calls.isEmpty)
    #expect(fixture.reports.all.count == 1)
    #expect(fixture.reports.all.first?.file == "")
    if case .launchFailed = fixture.reports.all.first?.failure {} else {
        Issue.record("expected launchFailed, got \(String(describing: fixture.reports.all.first?.failure))")
    }
    // The broken file is left as it was: replacing it would move `enabledAt` to today.
    #expect(try String(contentsOf: fixture.stateURL, encoding: .utf8) == "{ not json")
}

@Test func nilSettingsRunNothing() async throws {
    let fixture = try Fixture(files: ["2026-10-19-1430-telemost.md": meeting], settings: nil)
    await fixture.scanned()
    #expect(fixture.runner.calls.isEmpty)

    await fixture.ingest.update(settings: settings)
    await fixture.scanned()
    #expect(fixture.runner.calls.count == 1)
}

@Test func theCommandIsExactlyTheSpecOne() {
    let arguments = MeetingIngest.arguments(
        file: URL(fileURLWithPath: "/Users/x/Meetings/a.md"),
        meetings: URL(fileURLWithPath: "/Users/x/Meetings"))
    #expect(arguments == [
        "-p", "Обработай созвон /Users/x/Meetings/a.md по разделу «Созвоны → входящие» в AGENTS.md.",
        "--restricted", "--strict-mcp-config",
        "--tools", "Read,Edit,Write,Glob,Grep,ListAgents,SendMessage",
        "--add-dir", "/Users/x/Meetings",
        "--permission-mode", "acceptEdits",
        "--output-format", "json",
    ])
    #expect(!arguments.joined(separator: " ").contains("Bash"))
}
