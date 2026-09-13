import Foundation
import Testing
@testable import Core

private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end, confidence: 1)
}

private func voice(_ id: String, _ spans: [(Double, Double)]) -> MeetingVoice {
    let segments = spans.map {
        VoiceSegment(cluster: id, start: $0.0, end: $0.1, embedding: [1, 0])
    }
    return MeetingVoice(
        id: id, segments: segments, print: VoicePrint(vector: [1, 0]),
        speechSeconds: segments.reduce(0) { $0 + $1.durationSeconds }
    )
}

@Test func aWordGoesToTheVoiceItOverlapsMost() {
    let assigned = VoiceAssignment.assign(
        words: [word("привет", 10, 11)],
        to: [voice("v1", [(0, 10.4)]), voice("v2", [(10.4, 20)])]
    )
    #expect(assigned.map(\.voice) == ["v2"])
}

// The diarizer drops stretches shorter than a second, so words fall into the gaps between its
// segments routinely. Such a word belongs to somebody who is already in the meeting; inventing
// an extra participant out of it, or dropping it, would both be worse than picking the nearest.
@Test func aWordInNobodysSegmentGoesToTheNearest() {
    let assigned = VoiceAssignment.assign(
        words: [word("ага", 12, 12.4)],
        to: [voice("v1", [(0, 10)]), voice("v2", [(13, 20)])]
    )
    #expect(assigned.map(\.voice) == ["v2"])
}

@Test func everyWordKeepsItsPlace() {
    let assigned = VoiceAssignment.assign(
        words: [word("раз", 0, 1), word("два", 14, 15), word("три", 16, 17)],
        to: [voice("v1", [(0, 5)]), voice("v2", [(13, 20)])]
    )
    #expect(assigned.map(\.word.text) == ["раз", "два", "три"])
    #expect(assigned.map(\.voice) == ["v1", "v2", "v2"])
}

// A track the diarizer found nothing in is still a track full of speech — the meeting simply
// stays as phase 2б wrote it, one unnamed interlocutor.
@Test func withoutVoicesEverythingIsOneVoice() {
    let assigned = VoiceAssignment.assign(words: [word("раз", 0, 1), word("два", 9, 10)], to: [])
    #expect(assigned.map(\.voice) == ["v1", "v1"])
}
