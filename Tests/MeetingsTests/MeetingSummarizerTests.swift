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

/// An ordinary Obsidian note living in the same folder — `~/Meetings` is an Obsidian directory
/// by design, so this is expected, not a broken meeting file.
private let strayNote = """
    Заметка про понедельник. Никакой встречи здесь нет.

    - купить молока

    """

private struct FakeRunner: SummaryRunning {
    let answer: MeetingSummary?
    // A closure, not `any Error`: `Error` does not imply `Sendable`, and `SummaryRunning`
    // requires it — a bare existential here simply would not compile under Swift 6.
    let failure: (@Sendable () -> any Error)?
    let calls: Counter
    /// Makes the runner actually suspend, so an overlapping pass has a window to enter the
    /// actor. Without it the overlap test would pass by accident on timing.
    var slow = false
    /// Chunk counts of every call, so a test can prove the meeting arrived cut up rather than whole.
    let chunkCounts: Counts

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func record(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func summarize(chunks: [String]) async throws -> MeetingSummary {
        calls.bump()
        chunkCounts.record(chunks.count)
        if slow { try? await Task.sleep(for: .milliseconds(100)) }
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
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, chunkCounts: FakeRunner.Counts()) },
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
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, chunkCounts: FakeRunner.Counts()) },
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
        makeRunner: { FakeRunner(answer: nil, failure: { TemporaryFailure() }, calls: counter, chunkCounts: FakeRunner.Counts()) },
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
        makeRunner: { FakeRunner(answer: nil, failure: { PermanentFailure() }, calls: counter, chunkCounts: FakeRunner.Counts()) },
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
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, chunkCounts: FakeRunner.Counts()) },
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

// Три входа зовут заход: исход очереди, запуск приложения и «Перечитать конфиг». Актор
// реентерабелен, а заход висит на модели минутами — второй проход прочитал бы файл, который
// первый уже разбирает, но ещё не записал, и наложил бы вставку на устаревший текст, стерев
// ручную правку. Ровно то, ради ненаступления чего вставка вообще устроена вставкой.
@Test func twoOverlappingScansSummariseEachFileOnce() async throws {
    let directory = try archive(files: ["a.md": meetingFile, "b.md": meetingFile])
    let counter = FakeRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, slow: true, chunkCounts: FakeRunner.Counts()) },
        report: { _ in }
    )
    async let first: Void = summarizer.scanArchive()
    // Долго достаточно, чтобы первый заход уже висел на бегунке, когда придёт второй.
    try await Task.sleep(for: .milliseconds(20))
    await summarizer.scanArchive()
    await first

    #expect(counter.count == 2)
    for name in ["a.md", "b.md"] {
        let written = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        #expect(written.components(separatedBy: "## Саммари").count == 2)
    }
}

// `~/Meetings` — папка Obsidian, и заметка без транскрипта в ней ожидаема. Раньше такая
// заметка получала отказ, который некуда было записать, и он всплывал уведомлением при каждом
// запуске до конца времён.
@Test func aNoteWithoutATranscriptHeadingIsSkippedWithoutAWord() async throws {
    let directory = try archive(files: [
        "заметка.md": strayNote, "2026-09-04-1053-telemost.md": meetingFile,
    ])
    let counter = FakeRunner.Counter()
    let outcomes = OutcomeBox()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, chunkCounts: FakeRunner.Counts()) },
        report: { outcomes.add($0) }
    )
    await summarizer.scanArchive()

    #expect(counter.count == 1)
    #expect(outcomes.all.map(\.file) == ["2026-09-04-1053-telemost.md"])
    let note = try String(contentsOf: directory.appendingPathComponent("заметка.md"), encoding: .utf8)
    #expect(note == strayNote)
    let meeting = try String(
        contentsOf: directory.appendingPathComponent("2026-09-04-1053-telemost.md"), encoding: .utf8
    )
    #expect(meeting.contains("## Саммари"))
}

@Test func theSwitchInTheConfigActuallySwitchesItOff() async throws {
    let directory = try archive(files: ["a.md": meetingFile])
    var config = MeetingsConfig.default
    config.summaryEnabled = false
    let counter = FakeRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: config,
        makeRunner: { FakeRunner(answer: summary, failure: nil, calls: counter, chunkCounts: FakeRunner.Counts()) },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counter.count == 0)
}

// A meeting longer than the chunk limit must reach the runner cut into pieces: that is the whole
// point of the change, and nothing else in the pass would reveal it.
@Test func aLongMeetingReachesTheRunnerInChunks() async throws {
    var lines: [String] = []
    for minute in 0..<40 {
        lines.append("[\(MeetingMarkdown.timestamp(TimeInterval(minute) * 60))] Я: реплика \(minute)")
    }
    let long = """
        ---
        date: 2026-09-07
        ---

        ## Транскрипт

        \(lines.joined(separator: "\n"))

        """
    let directory = try archive(files: ["long.md": long])
    let counts = FakeRunner.Counts()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: {
            FakeRunner(answer: summary, failure: nil, calls: FakeRunner.Counter(), chunkCounts: counts)
        },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counts.all == [3])
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
