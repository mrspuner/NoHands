import Core
import Foundation
import Testing
@testable import Meetings

private let meetingFile = """
    ---
    date: 2026-09-04
    started: 10:53
    duration: 4m
    ---

    ## Транскрипт

    [00:00:07] Я: Помимо неверных, существуют и пустышки.
    [00:41:12] Собеседник: Они тратят время и ресурсы.

    """

/// Carries the heading but no reply lines under it — either not a meeting file at all, or one
/// edited past recognition.
private let meetingFileWithNoReplies = """
    ---
    date: 2026-09-04
    started: 10:53
    duration: 4m
    ---

    ## Транскрипт

    """

private struct FakeRunner: SummaryRunning {
    let answer: MeetingSummary?
    // A closure, not `any Error`: `Error` does not imply `Sendable`, and `SummaryRunning`
    // requires it — a bare existential here simply would not compile under Swift 6.
    let failure: (@Sendable () -> any Error)?
    let calls: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func summarize(transcript: String) async throws -> MeetingSummary {
        calls.bump()
        if let failure { throw failure() }
        return answer!
    }
}

private struct PermanentFailure: SummaryFailure, LocalizedError {
    var isPermanent: Bool { true }
    var errorDescription: String? { "слишком длинная встреча" }
}

private struct TemporaryFailure: SummaryFailure, LocalizedError {
    var isPermanent: Bool { false }
    var errorDescription: String? { "модель недоступна" }
}

private func archive(files: [String: String]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("summarizer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, contents) in files {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }
    return directory
}

private let summary = MeetingSummary(
    title: "Синк",
    summary: ["обсудили статус"],
    decisions: [
        MeetingSummary.Decision(text: "настоящее", quote: "они тратят время и ресурсы"),
        MeetingSummary.Decision(text: "выдуманное", quote: "переозвучить ролик и водность"),
    ]
)

@Test func aTranscriptWithoutASummaryGetsOne() async throws {
    let directory = try archive(files: ["2026-09-04-1053-telemost.md": meetingFile])
    let counter = FakeRunner.Counter()
    let outcomes = OutcomeBox()
    let summarizer = MeetingSummarizer(
        archive: directory,
        config: .default,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter) },
        report: { outcomes.add($0) }
    )
    await summarizer.scanArchive()

    let written = try String(
        contentsOf: directory.appendingPathComponent("2026-09-04-1053-telemost.md"), encoding: .utf8
    )
    #expect(written.contains("## Саммари"))
    #expect(written.contains("title: \"Синк\""))
    #expect(written.contains("- настоящее — [00:41:12]"))
    #expect(written.contains("- выдуманное — основание не найдено"))
    #expect(outcomes.all.map(\.failure) == [nil])
}

@Test func aFileThatAlreadyHasASummaryIsLeftAlone() async throws {
    let done = meetingFile.replacingOccurrences(
        of: "## Транскрипт", with: "## Саммари\n\n- уже есть\n\n## Транскрипт"
    )
    let directory = try archive(files: ["done.md": done])
    let counter = FakeRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter) },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 0)
}

// The model being unavailable means unavailable for everyone: twenty identical notices are noise.
@Test func aTemporaryFailureStopsThePass() async throws {
    let directory = try archive(files: ["a.md": meetingFile, "b.md": meetingFile])
    let counter = FakeRunner.Counter()
    let outcomes = OutcomeBox()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: nil, failure: { TemporaryFailure() }, calls: counter) },
        report: { outcomes.add($0) }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 1)
    #expect(outcomes.all.count == 1)
    let first = try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8)
    #expect(first == meetingFile)
    let second = try String(contentsOf: directory.appendingPathComponent("b.md"), encoding: .utf8)
    #expect(!second.contains("## Саммари"))
}

// A permanent failure concerns one file: it is recorded into it, will not repeat, and the next
// meeting may well be a perfectly ordinary length.
@Test func aPermanentFailureIsWrittenIntoTheFileAndThePassGoesOn() async throws {
    let directory = try archive(files: ["a.md": meetingFile, "b.md": meetingFile])
    let counter = FakeRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: nil, failure: { PermanentFailure() }, calls: counter) },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 2)
    let written = try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8)
    #expect(written.contains("Конспект не сделан: слишком длинная встреча"))
    #expect(SummaryInsertion.hasSummary(written))
}

// A file with no transcript lines is not a model problem and trying again will not change it —
// the refusal has to land in the file itself, or the same meeting is re-attempted and
// re-reported at every launch for ever.
@Test func aFileWithNoTranscriptLinesGetsTheRefusalWrittenAndIsNotRetried() async throws {
    let directory = try archive(files: ["a.md": meetingFileWithNoReplies])
    let counter = FakeRunner.Counter()
    let outcomes = OutcomeBox()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter) },
        report: { outcomes.add($0) }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 0)
    let written = try String(contentsOf: directory.appendingPathComponent("a.md"), encoding: .utf8)
    #expect(written.contains("Конспект не сделан:"))
    #expect(SummaryInsertion.hasSummary(written))
    #expect(outcomes.all.map(\.failure) == ["The file carries no transcript lines"])

    await summarizer.scanArchive()
    #expect(counter.count == 0)
    #expect(outcomes.all.count == 1)
}

@Test func theSwitchInTheConfigActuallySwitchesItOff() async throws {
    let directory = try archive(files: ["a.md": meetingFile])
    var config = MeetingsConfig.default
    config.summaryEnabled = false
    let counter = FakeRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: config,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter) },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 0)
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [MeetingSummarizer.Outcome] = []
    func add(_ outcome: MeetingSummarizer.Outcome) {
        lock.lock(); outcomes.append(outcome); lock.unlock()
    }
    var all: [MeetingSummarizer.Outcome] {
        lock.lock(); defer { lock.unlock() }; return outcomes
    }
}
