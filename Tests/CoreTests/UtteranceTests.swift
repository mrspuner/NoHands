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
        speaker: .voice("v1"), gap: 1.0, maxLength: 40
    )
    #expect(result.count == 1)
    #expect(result[0].text == "раз два")
    #expect(result[0].speaker == .voice("v1"))
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

@Test func aChangeOfVoiceStartsANewUtterance() {
    let assigned = [
        AssignedWord(word: TimedWord(text: "привет", start: 0, end: 1, confidence: 1), voice: "v1"),
        AssignedWord(word: TimedWord(text: "здравствуйте", start: 1.1, end: 2, confidence: 1), voice: "v2"),
    ]
    let utterances = Utterance.split(assigned: assigned, gap: 0.5, maxLength: 40)
    #expect(utterances.count == 2)
    #expect(utterances[0].speaker == .voice("v1"))
    #expect(utterances[1].speaker == .voice("v2"))
    #expect(utterances[1].text == "здравствуйте")
}

@Test func onePersonSpeakingOnKeepsOneUtterance() {
    let assigned = (0..<4).map { index in
        AssignedWord(
            word: TimedWord(
                text: "слово\(index)", start: Double(index), end: Double(index) + 0.3, confidence: 1
            ),
            voice: "v1"
        )
    }
    let utterances = Utterance.split(assigned: assigned, gap: 1.0, maxLength: 40)
    #expect(utterances.count == 1)
    #expect(utterances[0].text == "слово0 слово1 слово2 слово3")
}

@Test func theOldRulesStillApplyWithinOneVoice() {
    let assigned = [
        AssignedWord(word: TimedWord(text: "раз", start: 0, end: 1, confidence: 1), voice: "v1"),
        AssignedWord(word: TimedWord(text: "два", start: 5, end: 6, confidence: 1), voice: "v1"),
    ]
    let utterances = Utterance.split(assigned: assigned, gap: 0.5, maxLength: 40)
    #expect(utterances.count == 2)
}
