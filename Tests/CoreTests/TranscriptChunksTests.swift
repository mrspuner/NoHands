import Foundation
import Testing

@testable import Core

private func index(_ lines: [(TimeInterval, String)]) -> TranscriptIndex {
    let body = lines.map { "[\(MeetingMarkdown.timestamp($0.0))] Я: \($0.1)" }.joined(separator: "\n")
    return TranscriptIndex.parse("## Транскрипт\n\n" + body)
}

private func index(_ lines: [(Double, String, String)]) -> TranscriptIndex {
    TranscriptIndex.parse(
        ([TranscriptIndex.heading]
            + lines.map { "[\(MeetingMarkdown.timestamp($0.0))] \($0.1): \($0.2)" })
            .joined(separator: "\n")
    )
}

// Every existing test below predates the turn budget and uses a single speaker throughout, so a
// large `maxTurns` never trips — the point of these tests is the other two limits.
private let noTurnBudget = 1000

@Test func aShortMeetingIsOneChunk() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (60, "два"), (120, "три")]),
        maxSeconds: 900, maxCharacters: 100_000, maxTurns: noTurnBudget
    )
    #expect(chunks.count == 1)
    #expect(chunks[0].text.contains("[00:00:00] Я: раз"))
    #expect(chunks[0].text.contains("[00:02:00] Я: три"))
}

// The span is measured from the chunk's own first reply, not from the meeting's start:
// otherwise every chunk after the first would be cut immediately.
@Test func aChunkEndsWhenItsOwnSpanReachesTheLimit() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (800, "два"), (1000, "три"), (1900, "четыре")]),
        maxSeconds: 900, maxCharacters: 100_000, maxTurns: noTurnBudget
    )
    #expect(chunks.count == 3)
    #expect(chunks[0].text.contains("раз") && chunks[0].text.contains("два"))
    #expect(chunks[1].text.contains("три"))
    #expect(chunks[2].text.contains("четыре"))
}

@Test func aReplyIsNeverCutInHalf() {
    let long = String(repeating: "слово ", count: 50)
    let chunks = TranscriptChunks.split(
        index([(0, long), (10, long)]), maxSeconds: 900, maxCharacters: 200, maxTurns: noTurnBudget
    )
    #expect(chunks.count == 2)
    for chunk in chunks {
        #expect(chunk.text.hasPrefix("["))
        #expect(chunk.text.components(separatedBy: "\n").count == 1)
    }
}

// Dense speech hits the character budget before the clock runs out. Both limits are live at
// once and the first one to trip wins.
@Test func theCharacterBudgetCutsBeforeTheClockOnDenseSpeech() {
    let line = String(repeating: "а", count: 90)
    let chunks = TranscriptChunks.split(
        index([(0, line), (1, line), (2, line)]),
        maxSeconds: 900, maxCharacters: 220, maxTurns: noTurnBudget
    )
    #expect(chunks.count == 2)
}

@Test func aReplyLongerThanTheBudgetTravelsAlone() {
    let huge = String(repeating: "б", count: 500)
    let chunks = TranscriptChunks.split(
        index([(0, "коротко"), (5, huge), (10, "снова коротко")]),
        maxSeconds: 900, maxCharacters: 200, maxTurns: noTurnBudget
    )
    #expect(chunks.count == 3)
    #expect(chunks[1].text.contains(huge))
}

@Test func aTranscriptWithNoLinesGivesNoChunks() {
    #expect(
        TranscriptChunks.split(
            TranscriptIndex.parse("нет заголовка"),
            maxSeconds: 900, maxCharacters: 100, maxTurns: noTurnBudget
        ).isEmpty
    )
}

// Every reply of the meeting has to end up in exactly one chunk: a summary of a meeting with a
// silently dropped middle is worse than no summary, because nothing about it looks wrong.
@Test func everyReplyEndsUpInExactlyOneChunk() {
    let source = index((0..<40).map { (TimeInterval($0) * 120, "реплика \($0)") })
    let chunks = TranscriptChunks.split(
        source, maxSeconds: 900, maxCharacters: 100_000, maxTurns: noTurnBudget
    )
    let rejoined = chunks.map(\.text).joined(separator: "\n")
    #expect(rejoined == source.body)
}

// The `index()` helper above renders lines with the same template `split` uses internally, so
// `everyReplyEndsUpInExactlyOneChunk` cannot tell a byte-exact reproduction of `index.body` from
// one that merely reads the same. This test parses a hand-written file with irregular
// whitespace — the kind hand-edited speaker labels introduce — where `TranscriptIndex.parse`
// trims the parsed fields but `body` keeps the raw source line, so byte-exact reproduction does
// not hold. What does hold, and is what this pins: every reply survives once, none merged or
// dropped.
@Test func everyReplySurvivesIrregularWhitespace() {
    // Built from an array, not a triple-quoted literal, so the trailing space on the third line
    // is an explicit character rather than whitespace an editor could silently trim away.
    let markdown = [
        "## Транскрипт",
        "",
        "[00:00:00]  Я: раз",  // extra space after "]"
        "[00:13:20] Я:  два",  // two spaces after the speaker's colon
        "[00:31:40] Я: три" + " ",  // trailing space
    ].joined(separator: "\n")
    let source = TranscriptIndex.parse(markdown)
    #expect(source.lines.count == 3)

    let chunks = TranscriptChunks.split(
        source, maxSeconds: 900, maxCharacters: 100_000, maxTurns: noTurnBudget
    )

    let replyLineCount = chunks.reduce(0) { $0 + $1.text.components(separatedBy: "\n").count }
    #expect(replyLineCount == source.lines.count)

    for line in source.lines {
        let containingChunks = chunks.filter { $0.text.contains(line.text) }
        #expect(containingChunks.count == 1)
    }
}

// The property no other limit has: a chunk closed by the turn budget ends where one person
// stopped and another started, never inside somebody's speech.
@Test func theTurnBudgetCutsOnASpeakerBoundary() {
    let transcript = index([
        (0, "Я", "раз"), (1, "Настя", "два"), (2, "Я", "три"), (3, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 2)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.contains("Я: раз"))
    #expect(chunks[0].text.contains("Настя: два"))
    #expect(!chunks[0].text.contains("три"))
    #expect(chunks[1].text.contains("Я: три"))
}

// Consecutive lines by one speaker are one turn, however many there are.
@Test func linesOfOneSpeakerInARowAreOneTurn() {
    let transcript = index([
        (0, "Я", "раз"), (1, "Я", "два"), (2, "Я", "три"), (3, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 2)
    #expect(chunks.count == 1)
}

// A monologue has no turns to spend, so the clock is what cuts it — the same behaviour as before
// this task, which is the point: the budget is a ceiling for dense stretches, not a replacement.
@Test func aMonologueIsCutByTheClockRatherThanTheBudget() {
    let transcript = index((0..<20).map { (Double($0) * 60, "Я", "слово\($0)") })
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 300, maxCharacters: 100_000, maxTurns: 25)
    #expect(chunks.count == 4)
}

@Test func everyLineLandsInExactlyOneChunkInOrder() {
    let transcript = index((0..<40).map { (number: Int) -> (Double, String, String) in
        (Double(number) * 3, number % 2 == 0 ? "Я" : "Настя", "слово\(number)")
    })
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 7)
    let rejoined = chunks.map(\.text).joined(separator: "\n").components(separatedBy: "\n")
    #expect(rejoined.count == 40)
    for number in 0..<40 {
        #expect(rejoined[number].contains("слово\(number)"))
    }
}

// Three limits, and whichever comes first wins.
@Test func theFirstLimitToTripIsTheOneThatCuts() {
    let dense = index((0..<40).map { (number: Int) -> (Double, String, String) in
        (Double(number), number % 2 == 0 ? "Я" : "Настя", "слово\(number)")
    })
    // Turns trip first: 40 lines alternate, so the budget of 5 is reached long before 900 seconds.
    #expect(TranscriptChunks.split(dense, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 5).count == 8)
    // Characters trip first: a budget nothing else can reach.
    #expect(TranscriptChunks.split(dense, maxSeconds: 900, maxCharacters: 60, maxTurns: 100).count > 8)
}

// The numbers the owner needs to turn the budget come out of the cut itself rather than being
// recomputed from its text, where a second implementation could disagree with the first.
@Test func aChunkReportsItsLengthAndItsTurns() {
    let transcript = index([
        (0, "Я", "раз"), (10, "Настя", "два"), (20, "Я", "три"), (200, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 3)
    #expect(chunks.count == 2)
    #expect(chunks[0].turns == 3)
    #expect(chunks[0].seconds == 20)
    #expect(chunks[1].turns == 1)
    #expect(chunks[1].seconds == 0)
}

@Test func aTurnBudgetOfOneGivesOneChunkPerSpeakerStretch() {
    let transcript = index([(0, "Я", "раз"), (1, "Я", "два"), (2, "Настя", "три")])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 1)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.contains("раз") && chunks[0].text.contains("два"))
    #expect(chunks[1].text.contains("три"))
}
