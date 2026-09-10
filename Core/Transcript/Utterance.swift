import Foundation

/// One continuous stretch of speech by one side of the conversation.
public struct Utterance: Equatable, Sendable {
    /// Who said it: the owner, or one of the voices this meeting found on the other track.
    ///
    /// The voice carries an identity, not a label. What it is called in the file — `Настя`,
    /// `Собеседник 2` — is decided at render time by `SpeakerLabels`, because the owner edits
    /// those names by hand and one name can even cover two voices.
    public enum Speaker: Equatable, Hashable, Sendable {
        case me
        case voice(String)
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

    /// The same two rules as above — a silence longer than `gap`, a ceiling of `maxLength` —
    /// plus a third: a change of voice ends the utterance. Without it two people would share a
    /// line whenever they spoke without a pause between them, and the archive would attribute
    /// one person's words to another. That is the failure phase 2б already paid for once, when
    /// leaked speech was merged into the owner's own replies.
    public static func split(
        assigned: [AssignedWord],
        gap: TimeInterval,
        maxLength: TimeInterval
    ) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [TimedWord] = []
        var currentVoice: String?

        func flush() {
            guard let first = current.first, let last = current.last, let voice = currentVoice else {
                current = []
                return
            }
            utterances.append(
                Utterance(
                    speaker: .voice(voice),
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " ")
                )
            )
            current = []
        }

        for item in assigned {
            if let last = current.last, let first = current.first {
                let broken = item.word.start - last.end > gap
                    || item.word.end - first.start > maxLength
                    || item.voice != currentVoice
                if broken { flush() }
            }
            currentVoice = item.voice
            current.append(item.word)
        }
        flush()
        return utterances
    }
}
