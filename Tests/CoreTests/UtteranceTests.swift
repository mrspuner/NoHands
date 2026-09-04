import Foundation
import Testing
@testable import Core

private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end, confidence: 1)
}

@Test func aLongPauseStartsANewUtterance() {
    let result = Utterance.split(
        words: [word("раз", 0, 0.4), word("два", 0.5, 0.9), word("три", 3.0, 3.4)],
        speaker: .me, gap: 1.0, maxLength: 40
    )
    #expect(result.count == 2)
    #expect(result[0].text == "раз два")
    #expect(result[0].start == 0)
    #expect(result[0].end == 0.9)
    #expect(result[1].text == "три")
    #expect(result[1].start == 3.0)
}

@Test func aShortPauseKeepsOneUtterance() {
    let result = Utterance.split(
        words: [word("раз", 0, 0.4), word("два", 1.2, 1.6)],
        speaker: .others, gap: 1.0, maxLength: 40
    )
    #expect(result.count == 1)
    #expect(result[0].text == "раз два")
    #expect(result[0].speaker == .others)
}

// A monologue with not one sufficient pause still has to be cut, or the transcript ends up as
// one line filling the whole screen.
@Test func theLengthCeilingCutsAMonologue() {
    let words = (0..<20).map { index -> TimedWord in
        let start = Double(index) * 1.0
        return word("слово", start, start + 0.9)
    }
    let result = Utterance.split(words: words, speaker: .me, gap: 1.5, maxLength: 5)
    #expect(result.count > 1)
    for utterance in result {
        #expect(utterance.end - utterance.start <= 5.5)
    }
}

@Test func noWordsGiveNoUtterances() {
    #expect(Utterance.split(words: [], speaker: .me, gap: 1, maxLength: 40).isEmpty)
}

@Test func aSingleWordIsAnUtterance() {
    let result = Utterance.split(words: [word("да", 2, 2.3)], speaker: .me, gap: 1, maxLength: 40)
    #expect(result.count == 1)
    #expect(result[0].text == "да")
    #expect(result[0].start == 2)
    #expect(result[0].end == 2.3)
}
