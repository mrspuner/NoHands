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

// Our own process must never raise a meeting: dictation holds the input too.
@Test func ourOwnProcessIsNeverAMeeting() {
    let mine = AudioProcessMonitor.State(
        pid: ProcessInfo.processInfo.processIdentifier,
        bundleID: "com.nohands.app",
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
