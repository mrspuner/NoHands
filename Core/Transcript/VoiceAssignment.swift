import Foundation

/// One recognised word together with the voice that said it.
public struct AssignedWord: Equatable, Sendable {
    public var word: TimedWord
    public var voice: String

    public init(word: TimedWord, voice: String) {
        self.word = word
        self.voice = voice
    }
}

/// Puts the recogniser's words and the diarizer's segments on the same timeline.
///
/// Both come from the same file, so their clocks are the same one and no shifting is needed —
/// unlike the two tracks of a meeting, which start at different instants and are reconciled in
/// `MeetingTranscript`.
public enum VoiceAssignment {
    /// - Parameter voices: the meeting's voices, already merged out of the diarizer's clusters.
    ///   Empty means the diarizer found nothing at all, and then every word belongs to a single
    ///   nameless voice — the file phase 2б used to write.
    public static func assign(words: [TimedWord], to voices: [MeetingVoice]) -> [AssignedWord] {
        guard !voices.isEmpty else {
            return words.map { AssignedWord(word: $0, voice: "v1") }
        }
        return words.map { word in
            AssignedWord(word: word, voice: voice(for: word, among: voices))
        }
    }

    private static func voice(for word: TimedWord, among voices: [MeetingVoice]) -> String {
        var bestOverlap: (voice: String, seconds: TimeInterval)?
        var nearest: (voice: String, distance: TimeInterval)?

        for voice in voices {
            for segment in voice.segments {
                let overlap = min(word.end, segment.end) - max(word.start, segment.start)
                if overlap > 0 {
                    if bestOverlap == nil || overlap > bestOverlap!.seconds {
                        bestOverlap = (voice.id, overlap)
                    }
                    continue
                }
                // Distance to the segment, zero-length overlap counting as touching.
                let distance = max(segment.start - word.end, word.start - segment.end)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (voice.id, distance)
                }
            }
        }
        // `voices` is non-empty and every voice carries at least one segment, so one of the two
        // is always set; the last fallback exists so the type does not have to be optional.
        return bestOverlap?.voice ?? nearest?.voice ?? voices[0].id
    }
}
