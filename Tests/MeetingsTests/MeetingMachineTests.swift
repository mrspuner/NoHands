import Foundation
import Testing
@testable import Meetings

private let start = Date(timeIntervalSince1970: 1_000_000)

private let telemost = MeetingMachine.MeetingApp(
    bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost", pid: 501
)

private func machine() -> MeetingMachine {
    MeetingMachine(limits: MeetingMachine.Limits(
        silence: 60, autoStop: 120, startPrompt: 30, maxMeeting: 14400
    ))
}

/// Drives a machine to a draft that is already recording — the state most tests start from.
private func drafting() -> MeetingMachine {
    var subject = machine()
    _ = subject.handle(.streamsChanged(app: telemost, input: true, output: true, at: start))
    return subject
}

@Test func aTriggerAppTakingTheInputStartsADraftAndAsks() {
    var subject = machine()
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: false, at: start)
    )
    #expect(effects == [
        .startCapture(app: telemost, at: start),
        .blockDictation(true),
        .show(.startPrompt(appName: "Телемост")),
    ])
}

// The draft records from the first second: the half a minute while someone reads the prompt
// is exactly the half a minute where the agenda gets settled.
@Test func theDraftIsAlreadyRecordingBeforeAnyoneAnswered() {
    let subject = drafting()
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: false, promptShown: true, quietSince: nil))
}

@Test func confirmingCollapsesThePromptAndKeepsRecording() {
    var subject = drafting()
    let effects = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
    #expect(effects == [.show(.recording(since: start, confirmed: true))])
}

@Test func decliningDeletesTheDraftImmediately() {
    var subject = drafting()
    let effects = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    #expect(effects == [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)])
    #expect(subject.state == .declined(pid: 501))
}

// A declined meeting is not asked about again while it still holds the devices, or one
// meeting would ask ten times.
@Test func aDeclinedMeetingIsNotAskedAboutAgainWhileItHoldsTheDevices() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: true, at: start.addingTimeInterval(10))
    )
    #expect(effects == [])
}

@Test func releasingTheDevicesForgetsTheDecline() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    _ = subject.handle(
        .streamsChanged(app: telemost, input: false, output: false, at: start.addingTimeInterval(10))
    )
    #expect(subject.state == .idle)
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: false, at: start.addingTimeInterval(20))
    )
    #expect(effects.first == .startCapture(app: telemost, at: start.addingTimeInterval(20)))
}

@Test func stoppingAConfirmedRecordingByHandSavesItWithoutAsking() {
    var subject = drafting()
    _ = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
    let effects = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(effects == [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)])
    #expect(subject.state == .idle)
}

// A manual stop on an unconfirmed draft closes the files and asks: the recording is already
// over, so there is no point keeping it running just for the question.
@Test func stoppingADraftByHandClosesTheFilesAndAsksWhetherToKeepThem() {
    var subject = drafting()
    let effects = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(effects == [.stopCapture, .blockDictation(false), .show(.savePrompt(duration: 600))])
    #expect(subject.state == .savePending(since: start, stoppedAt: start.addingTimeInterval(600)))
}

@Test func savingFromTheSavePromptPromotesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.keepPressed) == [.keepDraft, .hide(after: 0)])
    #expect(subject.state == .idle)
}

@Test func deletingFromTheSavePromptRemovesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.deletePressed) == [.discardDraft, .hide(after: 0)])
    #expect(subject.state == .idle)
}

// Manual start outside a meeting: no app, no auto-stop, the folder slug is manual.
@Test func aManualStartWithNoMeetingAppRecordsWithoutAnAppAndWithoutAPrompt() {
    var subject = machine()
    let effects = subject.handle(.startPressed(app: nil, at: start))
    #expect(effects == [
        .startCapture(app: nil, at: start),
        .blockDictation(true),
        .show(.recording(since: start, confirmed: true)),
    ])
}

@Test func aFailedCaptureReportsAndReturnsToIdle() {
    var subject = drafting()
    let effects = subject.handle(.captureFailed("нет разрешения на запись экрана"))
    #expect(effects == [
        .discardDraft,
        .blockDictation(false),
        .show(.failure("нет разрешения на запись экрана")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}
