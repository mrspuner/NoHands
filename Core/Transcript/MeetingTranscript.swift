import Foundation

/// Puts both tracks of a meeting on one timeline.
///
/// The two tracks come off a single `SCStream` and therefore share a clock, but each output
/// starts delivering when it starts delivering: on the first live meeting the microphone was
/// 0.87 seconds behind the system audio — nearly a whole word. That difference is recorded in
/// `meeting.json` precisely so it can be undone here rather than guessed at from content.
public enum MeetingTranscript {
    /// - Parameters:
    ///   - microphoneStartedAt: capture-clock second of the microphone track's first buffer,
    ///     `nil` when the track never delivered one.
    ///   - systemStartedAt: the same for the system audio track.
    public static func merge(
        mine: [Utterance],
        theirs: [Utterance],
        microphoneStartedAt: Double?,
        systemStartedAt: Double?
    ) -> [Utterance] {
        let zero = [microphoneStartedAt, systemStartedAt].compactMap { $0 }.min()
        let mineOffset = offset(of: microphoneStartedAt, from: zero)
        let theirsOffset = offset(of: systemStartedAt, from: zero)

        let shifted = shift(mine, by: mineOffset) + shift(theirs, by: theirsOffset)
        return shifted.sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            // A deterministic tie-break across the two sides: the other side goes first, because
            // they are the reason there is a meeting to transcribe. Two utterances from the SAME
            // side starting at the same instant would need a further rule, but that case cannot
            // arise: `Utterance.split` produces disjoint spans within one track, one after the
            // other, so no two utterances on the same side ever share a start time.
            return left.speaker == .others && right.speaker == .me
        }
    }

    private static func offset(of startedAt: Double?, from zero: Double?) -> TimeInterval {
        guard let startedAt, let zero else { return 0 }
        return startedAt - zero
    }

    private static func shift(_ utterances: [Utterance], by offset: TimeInterval) -> [Utterance] {
        guard offset != 0 else { return utterances }
        return utterances.map {
            Utterance(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
    }
}
