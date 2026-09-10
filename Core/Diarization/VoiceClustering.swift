import Foundation

/// Turns the diarizer's clusters into people.
///
/// The library's own clustering routinely splits one person in two — 0.923 and 0.930 between
/// clusters of a single speaker on the meetings of 2026-09-10 — and its internal threshold
/// cannot be tuned out of it, being non-monotonic. So the split is undone here, by the same
/// comparison that recognises a voice between meetings, with the same threshold. One number
/// answers one question: is this the same person?
public enum VoiceClustering {
    public static func voices(from segments: [VoiceSegment], threshold: Float) -> [MeetingVoice] {
        // Clusters in order of first appearance, so the numbering the owner reads follows the
        // order people spoke in.
        var order: [String] = []
        var grouped: [String: [VoiceSegment]] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if grouped[segment.cluster] == nil { order.append(segment.cluster) }
            grouped[segment.cluster, default: []].append(segment)
        }

        var prints: [String: VoicePrint] = [:]
        for cluster in order {
            guard let centroid = VoicePrint.centroid(of: grouped[cluster] ?? []) else { continue }
            prints[cluster] = centroid
        }
        let clusters = order.filter { prints[$0] != nil }

        // Connected components over "closer than the threshold". Transitive on purpose: a voice
        // split three ways has a middle piece close to both ends and ends that may not reach
        // each other.
        var parent = Dictionary(uniqueKeysWithValues: clusters.map { ($0, $0) })
        func find(_ cluster: String) -> String {
            var current = cluster
            while parent[current] != current { current = parent[current]! }
            return current
        }
        for (index, left) in clusters.enumerated() {
            for right in clusters[(index + 1)...] {
                guard VoicePrint.cosine(prints[left]!, prints[right]!) >= threshold else { continue }
                let (a, b) = (find(left), find(right))
                if a != b { parent[b] = a }
            }
        }

        var merged: [String: [String]] = [:]
        var mergedOrder: [String] = []
        for cluster in clusters {
            let root = find(cluster)
            if merged[root] == nil { mergedOrder.append(root) }
            merged[root, default: []].append(cluster)
        }

        var voices: [MeetingVoice] = []
        for (number, root) in mergedOrder.enumerated() {
            let all = (merged[root] ?? []).flatMap { grouped[$0] ?? [] }.sorted { $0.start < $1.start }
            guard let centroid = VoicePrint.centroid(of: all) else { continue }
            voices.append(
                MeetingVoice(
                    id: "v\(number + 1)",
                    segments: all,
                    print: centroid,
                    speechSeconds: all.reduce(0) { $0 + $1.durationSeconds }
                )
            )
        }
        return voices
    }
}
