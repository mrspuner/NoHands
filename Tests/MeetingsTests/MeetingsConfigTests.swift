import AppKit
import Foundation
import Testing
@testable import Core
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

@Test func pipelineKeysHaveDefaults() throws {
    let config = try MeetingsConfig.decode(Data("{}".utf8))
    #expect(config.phraseGapSeconds == 0.5)
    #expect(config.maxPhraseSeconds == 40)
    // Measured on the live meeting of 2026-09-04, not a placeholder any more — see the constant.
    #expect(config.micThresholdDBFS == -40)
    #expect(config.audioRetentionDays == 7)
    #expect(config.aacBitrate == 32000)
}

@Test func pipelineKeysAreReadFromTheFile() throws {
    let json = """
    {"phraseGapSeconds": 1.5, "maxPhraseSeconds": 20, "micThresholdDBFS": -42,
     "audioRetentionDays": 3, "aacBitrate": 24000}
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.phraseGapSeconds == 1.5)
    #expect(config.maxPhraseSeconds == 20)
    #expect(config.micThresholdDBFS == -42)
    #expect(config.audioRetentionDays == 3)
    #expect(config.aacBitrate == 24000)
    // Keys absent from the file stayed at their defaults — the general rule for this config.
    #expect(config.autoStopSeconds == MeetingsConfig.default.autoStopSeconds)
}

@Test func summaryDefaultsAreTheMeasuredOnes() {
    let config = MeetingsConfig.default
    #expect(config.summaryEnabled)
    #expect(config.summaryModel == "mlx-community/Qwen3-8B-4bit")
    #expect(config.uvPath == "~/.local/bin/uv")
    // Half an hour, not the original fifteen minutes: the timeout covers one model load, one
    // generation per chunk and the merge pass, and the number it used to cite — "2 minutes on a
    // 71-minute meeting" — was superseded the same week by a live 68-minute run that took
    // 5 min 51 s.
    #expect(config.summaryTimeoutSeconds == 1800)
    // Still the model's window minus the answer, and deliberately not raised past it to make the
    // merge guard's arithmetic come out — see
    // `theSupportedMeetingLengthIsWhateverTheMergeGuardAllows`.
    #expect(config.summaryContextTokens == 28_000)
    #expect(config.quoteMatchRatio == 0.4)
}

// How long a meeting this app can summarise at all. Four constants across two modules decide it
// between them, and this is the only place that says the answer out loud.
//
// The merge call holds one partial summary per chunk, each up to `maxTokens`, plus its own answer
// at `mergeMaxTokens`, all inside `summaryContextTokens` — the model's window. That division is
// the ceiling: (28000 - 3000) / 2500 = 10 chunks, and at fifteen minutes a chunk that is 150
// minutes of meeting. Longer than that is refused by name — `tooManyChunks`, permanent, the
// reason recorded in the meeting file — instead of crashing inside the subprocess. Note that
// `maxMeetingSeconds` is 240 minutes: the app will record meetings it then refuses to summarise.
// That is the honest state of this branch, not an oversight.
//
// Four numbers move this line: `maxTokens` and `mergeMaxTokens` in `MLXSummaryRunner`,
// `summaryContextTokens` and `summaryChunkSeconds` here. When this test goes red the failure
// message carries the supported length the new numbers produce — read it, decide whether it is
// acceptable, then update these expectations. What must not be done is raising
// `summaryContextTokens` past the model's window to make the arithmetic come out: the guard would
// admit a merge call the model physically cannot take, trading a named refusal for a crash the
// pipeline has no way to explain.
//
// Lifting the ceiling for real means merging hierarchically, so that the merge holds a fixed
// number of partials however long the meeting was. That is deliberately not in this branch — the
// owner's longest meeting today is 68 minutes, which is five chunks.
@Test func theSupportedMeetingLengthIsWhateverTheMergeGuardAllows() {
    let config = MeetingsConfig.default
    let chunkLimit =
        (config.summaryContextTokens - MLXSummaryRunner.mergeMaxTokens) / MLXSummaryRunner.maxTokens
    let supportedMinutes = Double(chunkLimit) * config.summaryChunkSeconds / 60
    #expect(chunkLimit == 10, "the merge guard now allows \(chunkLimit) chunks")
    #expect(
        supportedMinutes == 150,
        "the longest meeting that can be summarised is now \(supportedMinutes) minutes"
    )
}

// A config the owner already wrote has none of the new keys. A missing key is a default,
// not a reason to refuse reading the whole file.
@Test func aConfigWrittenBeforePhase2vStillReads() throws {
    let json = """
        {"silenceSeconds": 0, "micThresholdDBFS": -40}
        """
    let decoded = try JSONDecoder().decode(MeetingsConfig.self, from: Data(json.utf8))
    #expect(decoded.micThresholdDBFS == -40)
    #expect(decoded.quoteMatchRatio == 0.4)
    #expect(decoded.uvPath == "~/.local/bin/uv")
}
