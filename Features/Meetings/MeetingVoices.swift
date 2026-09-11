import Core
import Foundation

/// Matches the voices of one meeting against the book: what they are called, and what the book
/// should remember about them afterwards.
///
/// Separated from `MeetingQueue` because it is the whole of the decision-making and none of the
/// input/output — the queue reads the book, calls this, writes the book back.
public enum MeetingVoices {
    public struct Resolution: Equatable, Sendable {
        /// Meeting-local identity to name, for the voices the book can name.
        public var names: [String: String]
        /// Meeting-local identity to the book's identity, for the voices the book keeps.
        ///
        /// Deliberately not a rendered label: what a voice is *called* is decided once, by
        /// `SpeakerLabels`, from the merged transcript. Working it out a second time here would
        /// be two rules for one string — and they would disagree exactly when a voice loses all
        /// its words to a neighbour, at which point the archive pass would read an ordinary
        /// file as a rename and attach a name to a voice that never said it.
        public var identities: [String: String]

        public init(names: [String: String], identities: [String: String]) {
            self.names = names
            self.identities = identities
        }
    }

    public static func resolve(
        voices: [MeetingVoice],
        meeting: String,
        book: inout VoiceBook,
        config: MeetingsConfig
    ) -> Resolution {
        let threshold = Float(config.voiceMatchThreshold)
        var names: [String: String] = [:]
        var identities: [String: String] = [:]

        for voice in voices {
            let matched = book.match(voice.print, threshold: threshold)
            var identity = matched?.id

            if voice.speechSeconds >= config.minVoicePrintSeconds {
                identity = book.remember(
                    voice.print,
                    meeting: meeting,
                    seconds: voice.speechSeconds,
                    as: identity,
                    maxPrints: config.maxVoicePrints
                )
            }

            if let name = identity.flatMap({ book.name(of: $0) }) { names[voice.id] = name }
            // A voice too brief to store and unknown to the book leaves no identity here. It is
            // still labelled in the file — it spoke, after all — and it still gets a row in the
            // book's meeting record, built by the caller, with no voice behind it.
            if let identity { identities[voice.id] = identity }
        }
        return Resolution(names: names, identities: identities)
    }
}
