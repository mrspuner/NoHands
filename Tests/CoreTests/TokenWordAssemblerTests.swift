import FluidAudio
import Foundation
import Testing
@testable import Core

private func timing(_ token: String, _ start: Double, _ end: Double, _ confidence: Float = 1) -> TokenTiming {
    TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
}

@Test func leadingSpaceStartsNewWord() {
    let words = TokenWordAssembler.words(from: [
        timing(" при", 0.0, 0.2),
        timing("вет", 0.2, 0.4),
        timing(" мир", 0.5, 0.7),
    ])
    #expect(words.map(\.text) == ["привет", "мир"])
    #expect(words[0].start == 0.0)
    #expect(words[0].end == 0.4)
    #expect(words[1].start == 0.5)
    #expect(words[1].end == 0.7)
}

// The first token usually arrives without a leading space: it starts a word simply by being first.
@Test func firstTokenWithoutSpaceStillStartsAWord() {
    let words = TokenWordAssembler.words(from: [
        timing("да", 1.0, 1.2),
        timing(" нет", 1.4, 1.6),
    ])
    #expect(words.map(\.text) == ["да", "нет"])
}

// The SentencePiece marker is handled the same as a space: `normalizedTimingToken` always
// replaces it, but the library's output shows both forms, and relying on just one would be
// a needless risk.
@Test func sentencePieceMarkerAlsoStartsAWord() {
    let words = TokenWordAssembler.words(from: [
        timing("\u{2581}один", 0.0, 0.3),
        timing("\u{2581}два", 0.4, 0.7),
    ])
    #expect(words.map(\.text) == ["один", "два"])
}

@Test func specialAndEmptyTokensAreSkipped() {
    let words = TokenWordAssembler.words(from: [
        timing("<blank>", 0.0, 0.1),
        timing(" слово", 0.1, 0.4),
        timing("", 0.4, 0.5),
        timing("<pad>", 0.5, 0.6),
    ])
    #expect(words.map(\.text) == ["слово"])
}

@Test func emptyTokenListGivesNoWords() {
    #expect(TokenWordAssembler.words(from: []).isEmpty)
}

@Test func confidenceIsAveragedOverTheWordsTokens() {
    let words = TokenWordAssembler.words(from: [
        timing(" сло", 0.0, 0.2, 1.0),
        timing("во", 0.2, 0.4, 0.5),
    ])
    #expect(words.count == 1)
    #expect(abs(words[0].confidence - 0.75) < 0.001)
}
