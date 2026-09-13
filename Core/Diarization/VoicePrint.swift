import Foundation

/// A voice reduced to one vector of unit length.
///
/// Normalised on the way in so that every comparison downstream is a plain dot product and no
/// caller has to remember whose vector was scaled. Measured on 2026-09-10: the same person
/// across meetings sits at 0.94–0.995, different people inside one meeting at 0.08–0.43.
public struct VoicePrint: Equatable, Sendable {
    public var vector: [Float]

    public init(vector: [Float]) {
        var length: Float = 0
        for value in vector { length += value * value }
        length = length.squareRoot()
        self.vector = length > 0 ? vector.map { $0 / length } : vector
    }

    /// Zero for vectors of different width: they cannot come from one model, so this is a defect
    /// upstream rather than a pair of distant voices, and zero refuses the match without
    /// claiming to have measured one.
    public static func cosine(_ left: VoicePrint, _ right: VoicePrint) -> Float {
        guard left.vector.count == right.vector.count, !left.vector.isEmpty else { return 0 }
        var dot: Float = 0
        for index in left.vector.indices { dot += left.vector[index] * right.vector[index] }
        return dot
    }

    /// Weighted by how long each segment lasted: a voice is what it said for a minute, not what
    /// it said in a one-second interjection.
    public static func centroid(of segments: [VoiceSegment]) -> VoicePrint? {
        guard let width = segments.first?.embedding.count, width > 0 else { return nil }
        var sum = [Float](repeating: 0, count: width)
        var weighted = false
        for segment in segments where segment.embedding.count == width {
            let weight = Float(segment.durationSeconds)
            guard weight > 0 else { continue }
            for index in 0..<width { sum[index] += segment.embedding[index] * weight }
            weighted = true
        }
        guard weighted else { return nil }
        return VoicePrint(vector: sum)
    }
}
