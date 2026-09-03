import Foundation
import Testing
@testable import Dictation

// The level bars read as a voice only within one dictation. Carrying them into the next one
// — because a panel was already showing something when a new recording started — used to make
// a fresh dictation open showing the previous one's levels.

@Test func noPreviousStateResetsLevelsOnANewRecording() {
    let transition = PanelTransition.transition(from: nil, to: .recording(latched: false))
    #expect(transition == .showResettingLevels)
}

@Test func insertingIntoANewRecordingResetsLevels() {
    let previous = PanelState.inserting(cleanupSkipped: nil)
    let transition = PanelTransition.transition(
        from: previous, to: .recording(latched: false)
    )
    #expect(transition == .showResettingLevels)
}

// Latching re-announces `.recording` with `latched: true` — the same dictation continuing, not
// a new one starting.
@Test func recordingIntoRecordingKeepsLevels() {
    let previous = PanelState.recording(latched: false)
    let transition = PanelTransition.transition(
        from: previous, to: .recording(latched: true)
    )
    #expect(transition == .showKeepingLevels)
}

@Test func recordingIntoTranscribingKeepsLevels() {
    let previous = PanelState.recording(latched: false)
    let transition = PanelTransition.transition(from: previous, to: .transcribing)
    #expect(transition == .showKeepingLevels)
}
