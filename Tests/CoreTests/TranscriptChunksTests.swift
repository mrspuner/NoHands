import Foundation
import Testing

@testable import Core

private func index(_ lines: [(TimeInterval, String)]) -> TranscriptIndex {
    let body = lines.map { "[\(MeetingMarkdown.timestamp($0.0))] Я: \($0.1)" }.joined(separator: "\n")
    return TranscriptIndex.parse("## Транскрипт\n\n" + body)
}

@Test func aShortMeetingIsOneChunk() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (60, "два"), (120, "три")]),
        maxSeconds: 900, maxCharacters: 100_000
    )
    #expect(chunks.count == 1)
    #expect(chunks[0].contains("[00:00:00] Я: раз"))
    #expect(chunks[0].contains("[00:02:00] Я: три"))
}

// The span is measured from the chunk's own first reply, not from the meeting's start:
// otherwise every chunk after the first would be cut immediately.
@Test func aChunkEndsWhenItsOwnSpanReachesTheLimit() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (800, "два"), (1000, "три"), (1900, "четыре")]),
        maxSeconds: 900, maxCharacters: 100_000
    )
    #expect(chunks.count == 3)
    #expect(chunks[0].contains("раз") && chunks[0].contains("два"))
    #expect(chunks[1].contains("три"))
    #expect(chunks[2].contains("четыре"))
}

@Test func aReplyIsNeverCutInHalf() {
    let long = String(repeating: "слово ", count: 50)
    let chunks = TranscriptChunks.split(
        index([(0, long), (10, long)]), maxSeconds: 900, maxCharacters: 200
    )
    #expect(chunks.count == 2)
    for chunk in chunks {
        #expect(chunk.hasPrefix("["))
        #expect(chunk.components(separatedBy: "\n").count == 1)
    }
}

// Dense speech hits the character budget before the fifteen minutes are up. Both limits are
// live at once and the first one to trip wins.
@Test func theCharacterBudgetCutsBeforeTheClockOnDenseSpeech() {
    let line = String(repeating: "а", count: 90)
    let chunks = TranscriptChunks.split(
        index([(0, line), (1, line), (2, line)]), maxSeconds: 900, maxCharacters: 220
    )
    #expect(chunks.count == 2)
}

@Test func aReplyLongerThanTheBudgetTravelsAlone() {
    let huge = String(repeating: "б", count: 500)
    let chunks = TranscriptChunks.split(
        index([(0, "коротко"), (5, huge), (10, "снова коротко")]),
        maxSeconds: 900, maxCharacters: 200
    )
    #expect(chunks.count == 3)
    #expect(chunks[1].contains(huge))
}

@Test func aTranscriptWithNoLinesGivesNoChunks() {
    #expect(TranscriptChunks.split(TranscriptIndex.parse("нет заголовка"), maxSeconds: 900, maxCharacters: 100).isEmpty)
}

// Every reply of the meeting has to end up in exactly one chunk: a summary of a meeting with a
// silently dropped middle is worse than no summary, because nothing about it looks wrong.
@Test func everyReplyEndsUpInExactlyOneChunk() {
    let source = index((0..<40).map { (TimeInterval($0) * 120, "реплика \($0)") })
    let chunks = TranscriptChunks.split(source, maxSeconds: 900, maxCharacters: 100_000)
    let rejoined = chunks.joined(separator: "\n")
    #expect(rejoined == source.body)
}
