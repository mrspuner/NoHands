import Foundation
import Testing
@testable import Meetings

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func metadataSurvivesAWriteAndARead() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(2820),
        app: MeetingMetadata.App(bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: MeetingMetadata.InputDevice(name: "Yeti", sampleRate: 48000, isNarrowband: false),
        stopReason: .automatic,
        excludedApps: ["com.spotify.client"],
        gaps: [MeetingMetadata.Gap(track: .microphone, from: noon.addingTimeInterval(60), to: noon.addingTimeInterval(75))],
        systemStartedAt: 0.42,
        microphoneStartedAt: 0.58,
        trailingMicrophoneSilenceSeconds: 12.5
    )

    let url = directory.appendingPathComponent("meeting.json")
    try metadata.write(to: url)
    #expect(try MeetingMetadata.read(from: url) == metadata)
}

// A track that never delivered a buffer has no start offset to report — `nil` must round-trip
// as cleanly as a real value, or a missing track would look like one that started at zero.
@Test func trackStartOffsetsRoundTripWhenAbsent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(60),
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: .manual,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil,
        trailingMicrophoneSilenceSeconds: nil
    )

    let url = directory.appendingPathComponent("meeting.json")
    try metadata.write(to: url)
    let read = try MeetingMetadata.read(from: url)
    #expect(read == metadata)
    #expect(read.systemStartedAt == nil)
    #expect(read.microphoneStartedAt == nil)
}

// The stop reason is read by a human working out "why does this recording look like that", so
// it is written as a word, not a number.
@Test func theStopReasonIsWrittenAsAWord() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meeting.json")

    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(60),
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: .lengthLimit,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil,
        trailingMicrophoneSilenceSeconds: nil
    )
    try metadata.write(to: url)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["stopReason"] as? String == "lengthLimit")
    #expect(raw?["app"] == nil)
}

// Немота дорожки записывается рядом с самими дорожками — это то, чем объясняется файл встречи
// без единой реплики «Я». Ключ называет ровно то, что в нём лежит: тишину **в конце** дорожки,
// потому что любой ненулевой сэмпл обнуляет счётчик. Оговорка про это есть в свифтовом
// комментарии, но папка очереди читается как JSON, а не как исходник.
@Test func trailingSilenceOfTheMicrophoneTrackSurvivesInTheFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(60),
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: .manual,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil,
        trailingMicrophoneSilenceSeconds: nil
    )
    metadata.trailingMicrophoneSilenceSeconds = 5598.8
    try metadata.write(to: url)

    let read = try MeetingMetadata.read(from: url)
    #expect(read.trailingMicrophoneSilenceSeconds == 5598.8)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["trailingMicrophoneSilenceSeconds"] as? Double == 5598.8)
    #expect(raw?["microphoneSilentSeconds"] == nil)
}

// Файлы со старым ключом лежат в очереди прямо сейчас. Поле опциональное, значит ключ просто не
// находится — папка читается дальше, а не отвергается целиком.
@Test func aFileCarryingTheOldSilenceKeyStillDecodes() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(60),
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: .manual,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil,
        trailingMicrophoneSilenceSeconds: nil
    )
    try metadata.write(to: url)
    var raw = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    raw["microphoneSilentSeconds"] = 12.5
    try JSONSerialization.data(withJSONObject: raw).write(to: url)

    let read = try MeetingMetadata.read(from: url)

    #expect(read.startedAt == noon)
    #expect(read.trailingMicrophoneSilenceSeconds == nil)
}
