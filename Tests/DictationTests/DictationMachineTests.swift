import Foundation
import Testing
@testable import Dictation

private let start = Date(timeIntervalSince1970: 1_000_000)

private func machine() -> DictationMachine {
    DictationMachine(limits: DictationMachine.Limits(
        minimumHold: 0.3, maximumRecording: 300, failureDwell: 3, successDwell: 0.6
    ))
}

/// Drives a machine up to a recording that has already been announced — the state most tests
/// start from.
private func recording(latched: Bool = false) -> DictationMachine {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    _ = subject.handle(.tick(start.addingTimeInterval(0.35)))
    if latched {
        _ = subject.handle(.spaceDown)
    }
    return subject
}

@Test func pressingFnStartsRecordingAndSwallowsBothKeys() {
    var subject = machine()
    let effects = subject.handle(.fnDown(at: start))
    #expect(effects == [.startRecording, .swallow(space: true, escape: true)])
}

// The panel and the start sound deliberately do not appear on the press: a brush against fn
// would give a flash and a beep for nothing.
@Test func nothingIsShownBeforeTheHoldThreshold() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    #expect(subject.handle(.tick(start.addingTimeInterval(0.2))) == [])
}

@Test func panelAndSoundAppearOnceTheHoldIsLongEnough() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    let effects = subject.handle(.tick(start.addingTimeInterval(0.31)))
    #expect(effects == [.play(.start), .show(.recording(latched: false))])
}

@Test func theAnnouncementHappensOnlyOnce() {
    var subject = recording()
    #expect(subject.handle(.tick(start.addingTimeInterval(1))) == [])
}

@Test func aBrushAgainstFnIsDiscardedSilently() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(0.1)))
    #expect(effects == [.discardRecording, .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

// The threshold is measured from the timestamps, not from whether a tick happened to arrive:
// a dropped tick must not throw away a real dictation.
@Test func aLongHoldIsKeptEvenIfNoTickArrived() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing),
    ])
}

@Test func releasingFnAfterARealHoldStopsTheRecording() {
    var subject = recording()
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing),
    ])
}

@Test func spaceLatchesTheRecordingAndStopsSwallowingSpace() {
    var subject = recording()
    let effects = subject.handle(.spaceDown)
    #expect(effects == [
        .swallow(space: false, escape: true),
        .show(.recording(latched: true)),
    ])
}

// Latching before the panel has ever appeared must not conjure one up early, and must not
// lose the fact that the recording is latched once the deferred announcement does happen.
@Test func latchingBeforeAnnouncementStaysSilentUntilTheThresholdIsReached() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    _ = subject.handle(.tick(start.addingTimeInterval(0.1)))
    let latchEffects = subject.handle(.spaceDown)
    #expect(latchEffects == [.swallow(space: false, escape: true)])
    let announceEffects = subject.handle(.tick(start.addingTimeInterval(0.35)))
    #expect(announceEffects == [.play(.start), .show(.recording(latched: true))])
}

@Test func releasingFnAfterLatchingDoesNothing() {
    var subject = recording(latched: true)
    #expect(subject.handle(.fnUp(at: start.addingTimeInterval(2))) == [])
}

@Test func pressingFnAgainStopsALatchedRecording() {
    var subject = recording(latched: true)
    let effects = subject.handle(.fnDown(at: start.addingTimeInterval(5)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing),
    ])
}

// Protection against a latched recording nobody remembered to stop.
@Test func recordingIsCutOffAtTheMaximum() {
    var subject = recording(latched: true)
    let effects = subject.handle(.tick(start.addingTimeInterval(301)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing),
    ])
}

@Test func escapeDuringRecordingThrowsTheAudioAway() {
    var subject = recording()
    let effects = subject.handle(.escapeDown)
    #expect(effects == [.discardRecording, .hidePanel(after: 0), .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

@Test func escapeWhileWorkingCancelsTheWork() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.escapeDown)
    #expect(effects == [.cancelWork, .hidePanel(after: 0), .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

@Test func theStoppedFileGoesToRecognition() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    let url = URL(fileURLWithPath: "/tmp/a.wav")
    #expect(subject.handle(.recordingStopped(url)) == [.transcribe(url)])
}

@Test func recognizedTextGoesToCleanup() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcribed("эээ привет"))
    #expect(effects == [.show(.cleaning), .clean("эээ привет")])
}

private func cleaning() -> DictationMachine {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    _ = subject.handle(.transcribed("эээ привет"))
    return subject
}

@Test func cleanedTextIsInserted() {
    var subject = cleaning()
    let effects = subject.handle(.cleaned("Привет."))
    #expect(effects == [
        .swallow(space: false, escape: false),
        .remember(raw: "эээ привет", cleaned: "Привет."),
        .show(.inserting(cleanupSkipped: nil)),
        .insert(text: "Привет.", cleaned: true),
    ])
}

// The one place where work continues after a failure. It is not a silent fallback: the reason
// is named on the panel and the error sound plays.
@Test func failedCleanupInsertsTheRawTextAndSaysSo() {
    var subject = cleaning()
    let effects = subject.handle(.cleanupFailed("offline"))
    #expect(effects == [
        .play(.error),
        .swallow(space: false, escape: false),
        .remember(raw: "эээ привет", cleaned: nil),
        .show(.inserting(cleanupSkipped: "offline")),
        .insert(text: "эээ привет", cleaned: false),
    ])
}

// A dictation that never reached cleanup has nothing worth keeping: the audio is thrown away
// with it, so a failed recognition cannot leave a file behind.
@Test func aFailedRecognitionRemembersNothing() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcriptionFailed("Transcription returned no text"))
    #expect(!effects.contains { if case .remember = $0 { return true } else { return false } })
}

// `insertionFailed` is the only modelled exit from `inserting` besides success — a paste that
// fails, most likely Accessibility permission revoked mid-session.
@Test func insertionFailureIsReported() {
    var subject = cleaning()
    _ = subject.handle(.cleaned("Привет."))
    let effects = subject.handle(.insertionFailed("Accessibility permission was revoked"))
    #expect(effects == [
        .discardRecording,
        .play(.error),
        .show(.failure("Accessibility permission was revoked")),
        .hidePanel(after: 3),
        .swallow(space: false, escape: false),
    ])
    #expect(subject.state == .idle)
}

@Test func aCleanInsertionEndsWithTheDoneSound() {
    var subject = cleaning()
    _ = subject.handle(.cleaned("Привет."))
    let effects = subject.handle(.inserted)
    #expect(effects == [.swallow(space: false, escape: false), .play(.done), .hidePanel(after: 0.6)])
    #expect(subject.state == .idle)
}

// The error sound already played when cleanup failed; a success chime right after it would say
// the opposite of what happened.
@Test func insertionAfterSkippedCleanupIsSilent() {
    var subject = cleaning()
    _ = subject.handle(.cleanupFailed("offline"))
    let effects = subject.handle(.inserted)
    #expect(effects == [.swallow(space: false, escape: false), .hidePanel(after: 0.6)])
}

@Test func recognitionFailureIsNamedOnThePanel() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcriptionFailed("Transcription returned no text"))
    #expect(effects == [
        .discardRecording,
        .play(.error),
        .show(.failure("Transcription returned no text")),
        .hidePanel(after: 3),
        .swallow(space: false, escape: false),
    ])
}

// A failure must never be a resting state: the next press of fn has to work.
@Test func theNextDictationWorksAfterAFailure() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingFailed("No audio was captured"))
    #expect(subject.state == .idle)
    #expect(subject.handle(.fnDown(at: start.addingTimeInterval(10)))
        == [.startRecording, .swallow(space: true, escape: true)])
}

// A microphone that is not there fails when the engine starts, not when it stops: without
// this the owner would hold fn, hear nothing, release it and never learn why.
@Test func aRecordingThatNeverStartedIsReported() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    let effects = subject.handle(.recordingFailed("No audio input device is available"))
    #expect(effects == [
        .discardRecording,
        .play(.error),
        .show(.failure("No audio input device is available")),
        .hidePanel(after: 3),
        .swallow(space: false, escape: false),
    ])
    #expect(subject.state == .idle)
}

// `Limits.init(config:)` is the single seam where the config's thresholds reach the machine.
// `minimumHold` and `maximumRecording` are both `Double` — nothing but this test stops them
// from being transposed, which would compile cleanly and change how dictation behaves without
// a single type error anywhere.
@Test func limitsInitReadsHoldAndRecordingSecondsIntoTheRightFields() {
    let config = DictationConfig(
        language: "ru",
        minimumHoldSeconds: 0.42,
        maxRecordingSeconds: 123,
        model: "deepseek-chat",
        timeoutSeconds: 10,
        prompt: "prompt",
        sounds: DictationConfig.default.sounds
    )
    let limits = DictationMachine.Limits(config: config)
    #expect(limits.minimumHold == 0.42)
    #expect(limits.maximumRecording == 123)
}

@Test func strayEventsInIdleAreIgnored() {
    var subject = machine()
    #expect(subject.handle(.spaceDown) == [])
    #expect(subject.handle(.escapeDown) == [])
    #expect(subject.handle(.fnUp(at: start)) == [])
    #expect(subject.handle(.tick(start)) == [])
    #expect(subject.state == .idle)
}
