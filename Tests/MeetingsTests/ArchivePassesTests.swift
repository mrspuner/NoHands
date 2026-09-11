import Core
import Foundation
import Testing
@testable import Meetings

private let meetingFile = """
    ---
    date: 2026-09-04
    participants: [Я, Настя]
    ---

    ## Транскрипт

    [00:00:03] Собеседник 1: привет
    [00:00:11] Я: привет и тебе

    """

/// Sleeps like the real MLX subprocess, so an overlapping call has a window to land while a
/// round is still in flight — the same trick `MeetingSummarizerTests` uses for its own overlap
/// test, needed here because the danger is specifically what happens to `SpeakerNaming` during
/// that window.
private struct SlowRunner: SummaryRunning {
    let calls: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func summarize(chunks: [String]) async throws -> MeetingSummary {
        calls.bump()
        try? await Task.sleep(for: .milliseconds(100))
        return MeetingSummary(title: "Синк", summary: ["обсудили статус"], decisions: [])
    }
}

private func archive() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("archive-passes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(meetingFile.utf8).write(to: directory.appendingPathComponent("2026-09-04-1053-telemost.md"))
    return directory
}

/// Reproduces the exact failure `ArchivePasses` exists to prevent: a naming pass that lands while
/// a slow summary round is still holding the text it read at the start. Without serialization,
/// the naming pass renames the file *and updates the book's row* while the summarizer sleeps; the
/// summarizer then writes its own stale copy — reverting the label in the file — over that
/// rename. Because the book's row was already updated, a later naming pass sees no mismatch and
/// never revisits the file: the label is wrong in the file forever, silently.
@Test func namingSurvivesASlowSummaryRoundAcrossTwoOverlappingScans() async throws {
    let directory = try archive()
    let file = directory.appendingPathComponent("2026-09-04-1053-telemost.md")
    let store = VoiceStore(url: directory.appendingPathComponent(".voices.json"))
    var initialBook = VoiceBook.empty
    let voiceId = initialBook.remember(
        VoicePrint(vector: [1, 0]), meeting: "2026-09-04-1053-telemost",
        seconds: 120, as: nil, maxPrints: 10
    )
    initialBook.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: [MeetingLabels.Label(position: 1, voiceId: voiceId, renderedName: "Собеседник 1")]
        )
    )
    try await store.save(initialBook)

    let calls = SlowRunner.Counter()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: { SlowRunner(calls: calls) },
        report: { _ in }
    )
    let naming = SpeakerNaming(archive: directory, store: store, report: { _ in })
    let passes = ArchivePasses(summarizer: summarizer, naming: naming)

    // Long enough that the first round's summarizer is still asleep when the second call lands —
    // exactly the window in which an unserialized naming pass would race the stale write.
    async let first: Void = passes.scanArchive()
    try await Task.sleep(for: .milliseconds(20))
    await passes.scanArchive()
    await first

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("## Саммари"))
    #expect(text.contains("[00:00:03] Настя: привет"))
    let finalBook = try await store.book()
    #expect(finalBook.name(of: voiceId) == "Настя")
    #expect(finalBook.labels(for: file.lastPathComponent)?.labels.first?.renderedName == "Настя")
    // The summarizer only ever runs the model once: the second, coalesced round finds the file
    // already summarised and skips it, exactly as `MeetingSummarizer` already does on its own.
    #expect(calls.count == 1)
}
