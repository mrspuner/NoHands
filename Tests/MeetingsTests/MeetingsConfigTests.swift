import Foundation
import Testing
@testable import Meetings

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

// Слаг необязателен: без него берётся последний компонент идентификатора бандла, чтобы
// добавление приложения стоило одной строки.
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

// Первый запуск должен оставить владельцу полный файл: иначе имена ключей придётся вспоминать.
// Ключи диктовки при этом обязаны уцелеть — секция дописывается в разобранный объект, а не
// поверх файла целиком.
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
