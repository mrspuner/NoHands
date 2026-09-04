import AppKit
import Foundation
import Testing
@testable import Meetings

// A trigger identifier is the one thing in this feature nothing else can check. A wrong one
// compiles, parses, saves back into `config.json` and then simply never matches — the spec says
// as much: "угаданный идентификатор молча не сработает, и это ровно тот случай, где ошибка не
// видна ни в коде, ни в тестах". This asks the machine instead of the headers, the way
// `AudioProcessMonitorTests` asks CoreAudio: every identifier shipped as a default has to name an
// application this Mac can actually find.
//
// It caught the real thing. `ru.yandex.telemost` was a guess, and the installed client is
// `ru.yandex.desktop.telemost` — detection would never once have fired on the owner's main
// platform.
//
// The trade-off, stated plainly: uninstalling one of these applications fails this test. That is
// deliberate — a trigger for an application that is not here is dead configuration, and the
// failure names which one — but it is one line to delete if it ever gets in the way.
@Test @MainActor func everyDefaultTriggerNamesAnApplicationThisMachineCanFind() {
    for trigger in MeetingsConfig.default.triggerApps {
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trigger.bundleID)
        #expect(found != nil, "\(trigger.bundleID) is not installed — a guessed identifier?")
    }
}

@Test func defaultsFillEveryMissingKey() throws {
    let config = try MeetingsConfig.decode(Data("{}".utf8))
    #expect(config == MeetingsConfig.default)
}

@Test func triggerAppsAreReadWithTheirSlugs() throws {
    let json = """
    { "triggerApps": [{ "bundleId": "ru.yandex.telemost", "slug": "telemost" }] }
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.triggerApps.count == 1)
    #expect(config.triggerApps[0].bundleID == "ru.yandex.telemost")
    #expect(config.triggerApps[0].resolvedSlug == "telemost")
}

// The slug is optional: without it, the last component of the bundle identifier is used, so
// adding an application costs one line.
@Test func aMissingSlugFallsBackToTheLastComponentOfTheBundleID() throws {
    let json = """
    { "triggerApps": [{ "bundleId": "ru.yandex.Telemost" }] }
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.triggerApps[0].resolvedSlug == "telemost")
}

@Test func thresholdsAreReadAndTheRestKeepDefaults() throws {
    let config = try MeetingsConfig.decode(Data("""
    { "silenceSeconds": 90 }
    """.utf8))
    #expect(config.silenceSeconds == 90)
    #expect(config.autoStopSeconds == MeetingsConfig.default.autoStopSeconds)
}

@Test func theMeetingsObjectIsReadFromTheSharedConfigFileWithoutTouchingDictationKeys() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    try Data("""
    { "language": "ru", "meetings": { "silenceSeconds": 45 } }
    """.utf8).write(to: url)

    let config = try MeetingsConfig.loadOrCreate(at: url)
    #expect(config.silenceSeconds == 45)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["language"] as? String == "ru")
}

// The first run must leave the owner a complete file, otherwise the key names have to be
// remembered. The dictation keys must survive alongside it — the section is written into the
// parsed object rather than over the whole file.
@Test func aMissingMeetingsObjectIsWrittenInAndOtherKeysSurvive() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    try Data(#"{ "language": "ru", "model": "deepseek-chat" }"#.utf8).write(to: url)

    let config = try MeetingsConfig.loadOrCreate(at: url)
    #expect(config == MeetingsConfig.default)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["model"] as? String == "deepseek-chat")
    #expect(raw?["meetings"] != nil)
}

// Unlike `DictationConfig.loadOrCreate`, a wholly absent file is not created here: dictation
// owns creating `config.json` with its own defaults, and a file written with only a `meetings`
// section would make `DictationConfig.loadOrCreate` see an existing file on its next call and
// skip writing its own template. `Meetings` only ever appends to a file dictation already made.
@Test func aWhollyMissingFileYieldsDefaultsWithoutCreatingAnything() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    let config = try MeetingsConfig.loadOrCreate(at: url)
    #expect(config == MeetingsConfig.default)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
