import Foundation
import Testing
@testable import Core

private func mine(_ start: Double, _ text: String) -> Utterance {
    Utterance(speaker: .me, start: start, end: start + 1, text: text)
}

private func theirs(_ start: Double, _ text: String) -> Utterance {
    Utterance(speaker: .others, start: start, end: start + 1, text: text)
}

@Test func theLaterTrackIsShiftedForward() {
    let merged = MeetingTranscript.merge(
        mine: [mine(0, "я")],
        theirs: [theirs(0, "они")],
        microphoneStartedAt: 503221.034,
        systemStartedAt: 503220.169
    )
    // The system track started earlier, so its zero is the timeline's zero, and the microphone
    // shifts to 0.865.
    #expect(merged.map(\.text) == ["они", "я"])
    #expect(abs(merged[0].start - 0) < 0.001)
    #expect(abs(merged[1].start - 0.865) < 0.001)
}

@Test func repliesInterleaveByTime() {
    let merged = MeetingTranscript.merge(
        mine: [mine(1, "второй"), mine(5, "четвёртый")],
        theirs: [theirs(0, "первый"), theirs(3, "третий")],
        microphoneStartedAt: 100,
        systemStartedAt: 100
    )
    #expect(merged.map(\.text) == ["первый", "второй", "третий", "четвёртый"])
}

// A track that never delivered a single buffer is `nil`. There is nothing to shift, and no words
// come from it anyway.
@Test func aTrackThatNeverStartedDoesNotMoveTheZero() {
    let merged = MeetingTranscript.merge(
        mine: [],
        theirs: [theirs(0, "они"), theirs(2, "ещё они")],
        microphoneStartedAt: nil,
        systemStartedAt: 500
    )
    #expect(merged.map(\.start) == [0, 2])
}

@Test func bothTracksMissingLeavesTimesAsTheyAre() {
    let merged = MeetingTranscript.merge(
        mine: [mine(1, "я")],
        theirs: [],
        microphoneStartedAt: nil,
        systemStartedAt: nil
    )
    #expect(merged.map(\.start) == [1])
}

// Equal timestamps are resolved deterministically, or the same run would produce a different file
// each time.
@Test func aTieIsBrokenTowardsTheOtherSide() {
    let merged = MeetingTranscript.merge(
        mine: [mine(0, "я")],
        theirs: [theirs(0, "они")],
        microphoneStartedAt: 100,
        systemStartedAt: 100
    )
    #expect(merged.map(\.text) == ["они", "я"])
}
