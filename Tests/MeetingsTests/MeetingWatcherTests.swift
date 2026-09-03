import Core
import Foundation
import Testing
@testable import Meetings

private let config = MeetingsConfig(
    triggerApps: [MeetingsConfig.TriggerApp(bundleID: "ru.yandex.telemost", slug: "telemost")],
    excludedApps: [],
    silenceSeconds: 60,
    autoStopSeconds: 120,
    startPromptSeconds: 30,
    maxMeetingSeconds: 14400
)

@Test func onlyTriggerApplicationsAreReported() {
    let states = [
        AudioProcessMonitor.State(pid: 501, bundleID: "ru.yandex.telemost", name: "Телемост", isRunningInput: true, isRunningOutput: true),
        AudioProcessMonitor.State(pid: 777, bundleID: "com.apple.Music", name: "Музыка", isRunningInput: false, isRunningOutput: true),
    ]
    let matched = MeetingWatcher.match(states: states, config: config)
    #expect(matched.count == 1)
    #expect(matched[0].app.pid == 501)
    #expect(matched[0].app.slug == "telemost")
}

// Dictation holds the same microphone a meeting would. If our own process were not excluded,
// dictation would raise a meeting, and that meeting would go on holding the microphone after
// dictation ends — a loop the feature must never enter. The bundle ID here is deliberately a
// real trigger app's, so this only fails for the right reason: without the pid check, this
// state would otherwise match `config.triggerApps` and be reported.
@Test func ourOwnProcessIsNeverAMeeting() {
    let mine = AudioProcessMonitor.State(
        pid: ProcessInfo.processInfo.processIdentifier,
        bundleID: "ru.yandex.telemost",
        name: "NoHands",
        isRunningInput: true,
        isRunningOutput: false
    )
    #expect(MeetingWatcher.match(states: [mine], config: config).isEmpty)
}

@Test func bothFlagsAreCarriedThroughUnchanged() {
    let muted = AudioProcessMonitor.State(
        pid: 501, bundleID: "ru.yandex.telemost", name: "Телемост",
        isRunningInput: false, isRunningOutput: true
    )
    let matched = MeetingWatcher.match(states: [muted], config: config)
    #expect(matched[0].input == false)
    #expect(matched[0].output == true)
}
