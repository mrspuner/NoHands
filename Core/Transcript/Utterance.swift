import Foundation

/// One continuous stretch of speech by one side of the conversation.
///
/// Two speakers and no more, because phase 2б has no way to tell one interlocutor from another
/// — that is 2г's job. What it does know for free is which track a word came from, and that is
/// exactly the difference between the owner and everyone else.
public struct Utterance: Equatable, Sendable {
    public enum Speaker: String, Equatable, Sendable, CaseIterable {
        case me
        case others
    }

    public var speaker: Speaker
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    /// Cuts a stream of words into utterances on two rules: a silence longer than `gap`, and a
    /// hard ceiling of `maxLength`.
    ///
    /// Silence rather than the recogniser's punctuation: full stops from a decoder are a guess,
    /// while a second of nothing between two words is a fact about the audio. The ceiling is
    /// there for the speaker who never gives one — without it a monologue becomes a single line.
    public static func split(
        words: [TimedWord],
        speaker: Speaker,
        gap: TimeInterval,
        maxLength: TimeInterval
    ) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            utterances.append(
                Utterance(
                    speaker: speaker,
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " ")
                )
            )
            current = []
        }

        for word in words {
            if let last = current.last, let first = current.first {
                if word.start - last.end > gap || word.end - first.start > maxLength { flush() }
            }
            current.append(word)
        }
        flush()
        return utterances
    }
}
