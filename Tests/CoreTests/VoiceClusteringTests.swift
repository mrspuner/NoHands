import Foundation
import Testing
@testable import Core

private func segment(_ cluster: String, _ start: Double, _ end: Double, _ vector: [Float]) -> VoiceSegment {
    VoiceSegment(cluster: cluster, start: start, end: end, embedding: vector)
}

@Test func aPrintIsUnitLength() {
    let print = VoicePrint(vector: [3, 4])
    #expect(abs(print.vector[0] - 0.6) < 0.0001)
    #expect(abs(print.vector[1] - 0.8) < 0.0001)
}

@Test func cosineIsOneForTheSameDirection() {
    #expect(abs(VoicePrint.cosine(VoicePrint(vector: [1, 1]), VoicePrint(vector: [5, 5])) - 1) < 0.0001)
    #expect(abs(VoicePrint.cosine(VoicePrint(vector: [1, 0]), VoicePrint(vector: [0, 1]))) < 0.0001)
}

// Vectors of different width never come from one model, so comparing them is a bug upstream,
// not a distant pair of voices. Zero says "no match" without pretending to have measured one.
@Test func cosineOfMismatchedWidthsIsZero() {
    #expect(VoicePrint.cosine(VoicePrint(vector: [1, 0]), VoicePrint(vector: [1, 0, 0])) == 0)
}

@Test func theCentroidIsWeightedBySpeech() {
    // Ten seconds pointing one way against one second pointing the other: the long one wins.
    let centroid = VoicePrint.centroid(of: [
        segment("S1", 0, 10, [1, 0]),
        segment("S1", 20, 21, [0, 1]),
    ])
    #expect(centroid != nil)
    #expect(centroid!.vector[0] > centroid!.vector[1])
}

@Test func farApartClustersStayTwoVoices() {
    let voices = VoiceClustering.voices(
        from: [segment("S1", 0, 30, [1, 0]), segment("S2", 30, 60, [0, 1])],
        threshold: 0.7
    )
    #expect(voices.count == 2)
    #expect(voices.map(\.id) == ["v1", "v2"])
    #expect(voices[0].speechSeconds == 30)
}

// The defect this whole task exists for: on 2026-09-10 one person came back as two clusters at
// cosine 0.923 and 0.930 inside single meetings.
@Test func aSplitSpeakerIsPutBackTogether() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S1", 0, 30, [1, 0]),
            segment("S2", 30, 50, [0.99, 0.14]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 1)
    #expect(voices[0].speechSeconds == 50)
    #expect(voices[0].segments.count == 2)
}

// Transitivity is what makes this a clustering and not a pairwise test: A pulls in B, B pulls in
// C, and C joins even though it is under the threshold away from A.
@Test func closenessCarriesThroughAChain() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S1", 0, 10, [1, 0]),
            segment("S2", 10, 20, [0.8, 0.6]),
            segment("S3", 20, 30, [0.35, 0.94]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 1)
}

// Identity is by order of first appearance, not by the diarizer's own numbering: the file the
// owner reads names people in the order they speak.
@Test func voicesAreNumberedByFirstAppearance() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S7", 5, 15, [0, 1]),
            segment("S2", 0, 4, [1, 0]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 2)
    #expect(voices[0].id == "v1")
    #expect(voices[0].segments[0].cluster == "S2")
    #expect(voices[1].segments[0].cluster == "S7")
}

@Test func nothingInNothingOut() {
    #expect(VoiceClustering.voices(from: [], threshold: 0.7).isEmpty)
}
