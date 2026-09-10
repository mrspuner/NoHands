import FluidAudio
import Foundation
import Testing
@testable import Core

@Test func aSegmentKnowsHowLongItLasted() {
    let segment = VoiceSegment(cluster: "S1", start: 3, end: 7.5, embedding: [1, 0])
    #expect(segment.durationSeconds == 4.5)
}

// A segment whose end precedes its start is not a shorter segment, it is a broken one; letting
// the duration go negative would make it *subtract* speech from a voice's total further down.
@Test func aBackwardsSegmentLastsNothing() {
    let segment = VoiceSegment(cluster: "S1", start: 9, end: 4, embedding: [1, 0])
    #expect(segment.durationSeconds == 0)
}

@Test func librarySegmentsBecomeOurs() {
    let library = [
        TimedSpeakerSegment(
            speakerId: "S1", embedding: [0.5, 0.5], startTimeSeconds: 1, endTimeSeconds: 2,
            qualityScore: 1
        ),
        TimedSpeakerSegment(
            speakerId: "S2", embedding: [0, 1], startTimeSeconds: 4, endTimeSeconds: 9,
            qualityScore: 1
        ),
    ]
    let ours = VoiceSegment.from(library)
    #expect(ours.count == 2)
    #expect(ours[0] == VoiceSegment(cluster: "S1", start: 1, end: 2, embedding: [0.5, 0.5]))
    #expect(ours[1].cluster == "S2")
    #expect(ours[1].durationSeconds == 5)
}

// The pipeline weighs a voice by how long it spoke and averages its embedding over that time.
// A segment without an embedding cannot take part in either, and carrying it forward as a
// zero-length vector would poison the centroid with a vector of nothing.
@Test func aSegmentWithoutAnEmbeddingIsDropped() {
    let library = [
        TimedSpeakerSegment(
            speakerId: "S1", embedding: [], startTimeSeconds: 1, endTimeSeconds: 2, qualityScore: 1
        )
    ]
    #expect(VoiceSegment.from(library).isEmpty)
}
