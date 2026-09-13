import FluidAudio
import Foundation

/// One stretch of one voice on the interlocutors' track, with the vector that identifies it.
///
/// `cluster` is what the diarizer decided *inside this file* and nothing more: the same person
/// regularly comes back as two or three clusters — measured on 2026-09-10, two clusters of one
/// speaker at cosine 0.923 — so nothing downstream may treat a cluster as a person. Turning
/// clusters into people is `VoiceClustering`'s job.
public struct VoiceSegment: Equatable, Sendable {
    public var cluster: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var embedding: [Float]

    public var durationSeconds: TimeInterval { max(0, end - start) }

    public init(cluster: String, start: TimeInterval, end: TimeInterval, embedding: [Float]) {
        self.cluster = cluster
        self.start = start
        self.end = end
        self.embedding = embedding
    }

    /// Segments without an embedding are dropped rather than carried: they can take part in
    /// neither the centroid nor the match, and an empty vector inside a weighted average is a
    /// vote for nothing.
    public static func from(_ segments: [TimedSpeakerSegment]) -> [VoiceSegment] {
        segments.compactMap { segment in
            guard !segment.embedding.isEmpty else { return nil }
            return VoiceSegment(
                cluster: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                embedding: segment.embedding
            )
        }
    }
}
