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

/// A draft that has been left running: the prompt has collapsed, the recording continues.
private func recordingConfirmed() -> MeetingMachine {
    var subject = drafting()
    _ = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
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
    #expect(effects == [
        .stopCapture(at: start.addingTimeInterval(5), reason: .manual),
        .discardDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
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
    #expect(effects == [
        .stopCapture(at: start.addingTimeInterval(600), reason: .manual),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
    // Not `.idle`: the application is still holding the devices, and coming to rest here would
    // let the next poll start the same meeting over. See "The three doors into a refusal".
    #expect(subject.state == .declined(pid: 501))
}

// A manual stop on an unconfirmed draft closes the files and asks: the recording is already
// over, so there is no point keeping it running just for the question.
@Test func stoppingADraftByHandClosesTheFilesAndAsksWhetherToKeepThem() {
    var subject = drafting()
    let effects = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(effects == [
        .stopCapture(at: start.addingTimeInterval(600), reason: .manual),
        .blockDictation(false),
        .show(.savePrompt(duration: 600)),
    ])
    #expect(subject.state == .savePending(
        app: telemost, since: start, stoppedAt: start.addingTimeInterval(600)
    ))
}

@Test func savingFromTheSavePromptPromotesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.keepPressed(at: start.addingTimeInterval(605))) == [.keepDraft, .hide(after: 0)])
    #expect(subject.state == .declined(pid: 501))
}

@Test func deletingFromTheSavePromptRemovesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.deletePressed(at: start.addingTimeInterval(605))) == [.discardDraft, .hide(after: 0)])
    #expect(subject.state == .declined(pid: 501))
}

// Silence saves here as well, and — just as important — the question ends. An unanswered save
// prompt used to stand forever: the machine ignored ticks in this state, so a recording nobody
// answered for was never handed over, and the panel it held kept taking the mouse over the Dock.
@Test func anUnansweredSavePromptSavesTheRecording() {
    var subject = drafting()
    let stopped = start.addingTimeInterval(600)
    _ = subject.handle(.stopPressed(at: stopped))

    #expect(subject.handle(.tick(stopped.addingTimeInterval(119))) == [])
    #expect(subject.handle(.tick(stopped.addingTimeInterval(120))) == [.keepDraft, .hide(after: 0)])
    #expect(subject.state == .declined(pid: 501))
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

// Capture never actually started, so there is nothing to stop — only the draft folder, which
// holds no usable audio, needs to go.
@Test func captureFailingAtStartDiscardsTheDraftFromRecording() {
    var subject = drafting()
    let effects = subject.handle(.captureFailedAtStart("нет разрешения на запись экрана"))
    #expect(effects == [
        .discardDraft,
        .blockDictation(false),
        .show(.failure("нет разрешения на запись экрана")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

@Test func captureFailingAtStartDiscardsTheDraftFromStopOffered() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let effects = subject.handle(.captureFailedAtStart("нет разрешения на запись экрана"))
    #expect(effects == [
        .discardDraft,
        .blockDictation(false),
        .show(.failure("нет разрешения на запись экрана")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

// Spec §10: a stream that dies mid-meeting stops the recording but keeps what was already
// captured — a forty-minute meeting must not be thrown away over a transient capture error.
@Test func captureFailingWhileRecordingKeepsTheDraftFromRecording() {
    var subject = recordingConfirmed()
    let died = start.addingTimeInterval(2400)
    let effects = subject.handle(.captureFailedWhileRecording("поток захвата прервался", at: died))
    #expect(effects == [
        .stopCapture(at: died, reason: .failure),
        .keepDraft,
        .blockDictation(false),
        .show(.failure("поток захвата прервался")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

@Test func captureFailingWhileRecordingKeepsTheDraftFromStopOffered() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let died = quiet.addingTimeInterval(70)
    let effects = subject.handle(.captureFailedWhileRecording("поток захвата прервался", at: died))
    #expect(effects == [
        .stopCapture(at: died, reason: .failure),
        .keepDraft,
        .blockDictation(false),
        .show(.failure("поток захвата прервался")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

// Muting releases the input and leaves the output taken: the app keeps playing back the
// other participants. This is the middle of the meeting, not its end.
@Test func muteReleasesTheInputAndChangesNothing() {
    var subject = recordingConfirmed()
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: false, output: true, at: start.addingTimeInterval(60))
    )
    #expect(effects == [])
    _ = subject.handle(.tick(start.addingTimeInterval(600)))
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: true, promptShown: false, quietSince: nil))
}

@Test func bothDevicesGoingFreeStartsTheSilenceClockButOffersNothingYet() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    #expect(subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet)) == [])
    #expect(subject.handle(.tick(quiet.addingTimeInterval(59))) == [])
}

@Test func silenceLongerThanTheThresholdOffersToStopWhileStillRecording() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let effects = subject.handle(.tick(quiet.addingTimeInterval(61)))
    #expect(effects == [.show(.stopPrompt(duration: 121))])
    #expect(subject.state == .stopOffered(app: telemost, since: start, confirmed: true, offeredAt: quiet.addingTimeInterval(61), cause: .automatic))
}

// The meeting came back to life — the prompt is withdrawn, recording continues in the same file.
@Test func devicesComingBackToLifeWithdrawTheStopPrompt() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let alive = quiet.addingTimeInterval(70)
    let effects = subject.handle(.streamsChanged(app: telemost, input: true, output: true, at: alive))
    #expect(effects == [.show(.recording(since: start, confirmed: true))])
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: true, promptShown: false, quietSince: nil))
}

@Test func theProcessExitingOffersToStopAtOnce() {
    var subject = recordingConfirmed()
    let effects = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(600)))
    #expect(effects == [.show(.stopPrompt(duration: 600))])
}

// Silence saves: the prompt is easy to miss, and inattention should cost disk space, not the
// meeting itself.
@Test func anUnansweredStopPromptSavesTheRecording() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    let effects = subject.handle(.tick(offered.addingTimeInterval(121)))
    #expect(effects == [
        .stopCapture(at: offered.addingTimeInterval(121), reason: .automatic),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
    #expect(subject.state == .idle)
}

@Test func answeringTheStopPromptWithKeepSavesImmediately() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let pressed = quiet.addingTimeInterval(70)
    #expect(subject.handle(.keepPressed(at: pressed)) == [
        .stopCapture(at: pressed, reason: .automatic),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
}

@Test func answeringTheStopPromptWithDeleteRemovesTheFolder() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let pressed = quiet.addingTimeInterval(70)
    #expect(subject.handle(.deletePressed(at: pressed)) == [
        .stopCapture(at: pressed, reason: .automatic),
        .discardDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
}

// The length limit stops at once rather than asking: it exists precisely so a forgotten
// recording cannot eat the disk.
@Test func theLengthLimitStopsWithoutAsking() {
    var subject = recordingConfirmed()
    let effects = subject.handle(.tick(start.addingTimeInterval(14400)))
    #expect(effects == [
        .stopCapture(at: start.addingTimeInterval(14400), reason: .lengthLimit),
        .keepDraft,
        .blockDictation(false),
        .show(.limitReached),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

// The collapsed start prompt changes only how the panel looks: the meeting stays a draft and
// will ask about itself when it stops.
@Test func theStartPromptCollapsesButTheRecordingStaysADraft() {
    var subject = drafting()
    let effects = subject.handle(.tick(start.addingTimeInterval(31)))
    #expect(effects == [.show(.recording(since: start, confirmed: false))])
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: false, promptShown: false, quietSince: nil))
    let stop = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(stop.contains(.show(.savePrompt(duration: 600))))
}

@Test func theStopPromptOfADraftAsksAboutSavingRatherThanSavingSilently() {
    var subject = drafting()
    _ = subject.handle(.tick(start.addingTimeInterval(31)))
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    #expect(subject.handle(.tick(offered.addingTimeInterval(121))) == [
        .stopCapture(at: offered.addingTimeInterval(121), reason: .automatic),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
}

// Revival must restore the original `confirmed`, not force it to true: an unconfirmed draft
// that went quiet once and then came back to life still has to ask when it eventually stops.
@Test func aRevivedUnconfirmedDraftStillAsksWhenItStops() {
    var subject = drafting()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    #expect(subject.state == .stopOffered(app: telemost, since: start, confirmed: false, offeredAt: offered, cause: .automatic))

    let alive = offered.addingTimeInterval(9)
    let revival = subject.handle(.streamsChanged(app: telemost, input: true, output: true, at: alive))
    #expect(revival == [.show(.recording(since: start, confirmed: false))])
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: false, promptShown: false, quietSince: nil))

    let stop = subject.handle(.stopPressed(at: alive.addingTimeInterval(10)))
    #expect(stop == [
        .stopCapture(at: alive.addingTimeInterval(10), reason: .manual),
        .blockDictation(false),
        .show(.savePrompt(duration: 140)),
    ])
}

@Test func manualStopFromTheStopPromptOfAConfirmedRecordingSavesRatherThanAsking() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let effects = subject.handle(.stopPressed(at: quiet.addingTimeInterval(70)))
    #expect(effects == [
        .stopCapture(at: quiet.addingTimeInterval(70), reason: .manual),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
    #expect(subject.state == .declined(pid: 501))
}

// MARK: - Why the recording stopped

// The whole reason the field exists: a meeting whose application quit and a meeting that merely
// went quiet finish through the same tick, and only this tells them apart afterwards. The cause
// has to be carried from the offer to the stop, because the stop always arrives later.
@Test func aMeetingWhoseApplicationQuitSaysSoWhenItStops() {
    var subject = recordingConfirmed()
    let exited = start.addingTimeInterval(600)
    _ = subject.handle(.appExited(pid: 501, at: exited))
    let stopped = exited.addingTimeInterval(121)
    #expect(subject.handle(.tick(stopped)) == [
        .stopCapture(at: stopped, reason: .appExited),
        .keepDraft,
        .blockDictation(false),
        .hide(after: 0),
    ])
}

@Test func aMeetingThatOnlyWentQuietStopsAutomatically() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    let stopped = offered.addingTimeInterval(121)
    #expect(subject.handle(.tick(stopped)).first == .stopCapture(at: stopped, reason: .automatic))
}

// Answering the prompt does not change what ended the meeting: the application had already quit,
// and the click only says what to do with what was recorded.
@Test func answeringTheStopPromptKeepsTheCauseThatRaisedIt() {
    var subject = recordingConfirmed()
    _ = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(600)))
    let pressed = start.addingTimeInterval(605)
    #expect(subject.handle(.keepPressed(at: pressed)).first
        == .stopCapture(at: pressed, reason: .appExited))
}

// Stopping by hand from the prompt is the owner's own decision, not the cause that raised it.
@Test func stoppingByHandFromTheStopPromptIsManual() {
    var subject = recordingConfirmed()
    _ = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(600)))
    let pressed = start.addingTimeInterval(605)
    #expect(subject.handle(.stopPressed(at: pressed)).first
        == .stopCapture(at: pressed, reason: .manual))
}

@Test func theLengthLimitNamesItselfInTheMetadata() {
    var subject = recordingConfirmed()
    let stopped = start.addingTimeInterval(14400)
    #expect(subject.handle(.tick(stopped)).first == .stopCapture(at: stopped, reason: .lengthLimit))
}

@Test func stoppingARecordingByHandIsManual() {
    var subject = recordingConfirmed()
    let stopped = start.addingTimeInterval(600)
    #expect(subject.handle(.stopPressed(at: stopped)).first
        == .stopCapture(at: stopped, reason: .manual))
}

// MARK: - A refusal that ends

// Refusing remembers one process until it lets the devices go — and a process that quit lets
// them go without ever saying so, because it disappears from the list instead of reporting
// empty streams. Without this the refusal would outlive the meeting it refused.
@Test func aRefusedMeetingIsForgottenWhenItsApplicationQuits() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    #expect(subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(10))) == [])
    #expect(subject.state == .idle)
}

// MARK: - The three doors into a refusal

// The watcher repeats itself once a second, and every repeat reads as "an application has just
// taken the input". Without a memory of the process, a meeting stopped by hand starts over on
// the next tick: a fresh draft, a fresh prompt, and — thirty seconds later, once the prompt
// collapses — a recording that runs to the end of the meeting. The stop button would not stop.
@Test func stoppingByHandRemembersTheProcessTheWayARefusalDoes() {
    var subject = recordingConfirmed()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.state == .declined(pid: 501))
    #expect(subject.handle(
        .streamsChanged(app: telemost, input: true, output: true, at: start.addingTimeInterval(601))
    ) == [])
}

// "Delete" is the other explicit no in this feature, and it has to be remembered for the same
// reason: an unconfirmed draft that comes back a second later is saved by silence, so a
// recording the owner deleted on purpose would end up in the archive anyway.
@Test func deletingFromTheSavePromptRemembersTheProcessToo() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    _ = subject.handle(.deletePressed(at: start.addingTimeInterval(605)))
    #expect(subject.state == .declined(pid: 501))
    #expect(subject.handle(
        .streamsChanged(app: telemost, input: true, output: true, at: start.addingTimeInterval(606))
    ) == [])
}

// The door was the stop, not the answer: what the owner said about the folder does not change
// the fact that they ended this meeting's recording by hand.
@Test func savingFromTheSavePromptRemembersTheProcessAsWell() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    _ = subject.handle(.keepPressed(at: start.addingTimeInterval(605)))
    #expect(subject.state == .declined(pid: 501))
}

@Test func aSavePromptThatSavedItselfRemembersTheProcessAsWell() {
    var subject = drafting()
    let stopped = start.addingTimeInterval(600)
    _ = subject.handle(.stopPressed(at: stopped))
    _ = subject.handle(.tick(stopped.addingTimeInterval(120)))
    #expect(subject.state == .declined(pid: 501))
}

@Test func deletingFromTheStopPromptRemembersTheProcessToo() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    _ = subject.handle(.deletePressed(at: quiet.addingTimeInterval(70)))
    #expect(subject.state == .declined(pid: 501))
}

@Test func stoppingByHandFromTheStopPromptRemembersTheProcessToo() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    _ = subject.handle(.stopPressed(at: quiet.addingTimeInterval(70)))
    #expect(subject.state == .declined(pid: 501))
}

// Remembered exactly as long as a refusal is, and no longer: the meeting that was stopped by
// hand ends when the application lets the devices go, and the next one is a new meeting.
@Test func aStopByHandIsForgottenWhenTheDevicesGoFree() {
    var subject = recordingConfirmed()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    _ = subject.handle(
        .streamsChanged(app: telemost, input: false, output: false, at: start.addingTimeInterval(700))
    )
    #expect(subject.state == .idle)
    let again = start.addingTimeInterval(800)
    #expect(subject.handle(.streamsChanged(app: telemost, input: true, output: false, at: again)).first
        == .startCapture(app: telemost, at: again))
}

@Test func aStopByHandIsForgottenWhenTheApplicationQuits() {
    var subject = recordingConfirmed()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    _ = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(700)))
    #expect(subject.state == .idle)
}

// A refusal only ends two ways, and both need the process to still be there to end it: empty
// streams, or an exit reported once. An application that quits while the save prompt is up has
// already spent its one exit — remembering it afterwards would settle the machine into a
// refusal nothing can ever lift, and no meeting would be noticed again until a restart.
@Test func anApplicationThatQuitWhileTheSavePromptWasUpIsNotRememberedAfterwards() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    _ = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(610)))
    _ = subject.handle(.keepPressed(at: start.addingTimeInterval(620)))
    #expect(subject.state == .idle)
}

// Same hazard from the other prompt: the stop was offered *because* the application quit, so
// there is no process left to wait on.
@Test func aStopPromptRaisedByAnExitRemembersNothingWhenItIsAnswered() {
    var subject = recordingConfirmed()
    _ = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(600)))
    _ = subject.handle(.deletePressed(at: start.addingTimeInterval(605)))
    #expect(subject.state == .idle)
}

// The manual start is the owner's last resort for when detection let them down, so it may never
// be the thing that stopped working: refusing one meeting must not disable the menu item.
@Test func theManualStartWorksEvenAfterARefusal() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    let pressed = start.addingTimeInterval(10)
    #expect(subject.handle(.startPressed(app: telemost, at: pressed)) == [
        .startCapture(app: telemost, at: pressed),
        .blockDictation(true),
        .show(.recording(since: pressed, confirmed: true)),
    ])
}

// MARK: - What the menu bar is allowed to offer

// The menu offers "stop" only while there is a recording to stop, and the elapsed time it puts
// into that item has to come from the recording itself rather than from a second clock the menu
// would keep for itself.
@Test func theMenuIsOfferedAStopForAsLongAsSomethingIsBeingRecorded() {
    var subject = machine()
    #expect(subject.state.activity == .ready)

    _ = subject.handle(.startPressed(app: telemost, at: start))
    #expect(subject.state.activity == .recording(since: start))

    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(2820)))
    #expect(subject.state.activity == .ready)
}

// A meeting whose room went quiet is still being recorded: the prompt asks what to do with it,
// and until it is answered the menu must keep offering to stop that recording rather than to
// start a second one.
@Test func aMeetingWaitingOutItsStopPromptIsStillARecording() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))

    #expect(subject.state.activity == .recording(since: start))
}

// Stopping a recording nobody ever confirmed leaves the question "keep it?" on the panel, and
// only the panel can answer it: the machine ignores a start pressed in this state, so a menu
// item offering one would do nothing at all.
@Test func anUnansweredSavePromptLeavesTheMenuNothingToOffer() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(90)))
    #expect(subject.state.activity == .awaitingAnswer)

    _ = subject.handle(.keepPressed(at: start.addingTimeInterval(95)))
    #expect(subject.state.activity == .ready)
}

// A refusal is "ready" to the menu on purpose — the manual start is exactly what the owner
// reaches for after refusing one by mistake. It is emphatically not ready to be rebuilt
// around, which is a different question and lives in `MeetingCoordinator.canBeRebuilt`.
@Test func aRefusedMeetingStillOffersTheMenuAStart() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))

    #expect(subject.state.activity == .ready)
}
