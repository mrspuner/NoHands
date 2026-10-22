import Foundation
import Testing
@testable import Telegram

private func tempConfig(_ json: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    if let json { try Data(json.utf8).write(to: url) }
    return url
}

@Test func missingSectionIsAppendedWithDefaults() throws {
    let url = try tempConfig(#"{"language":"ru"}"#)
    #expect(try TelegramConfig.loadOrCreate(at: url) == .default)
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let section = try #require(root["telegram"] as? [String: Any])
    #expect(section["enabled"] as? Bool == false)
    #expect(section["replyTimeoutSeconds"] as? Double == 900)
    #expect(root["language"] as? String == "ru")
}

@Test func missingKeysTakeDefaults() throws {
    let url = try tempConfig(#"{"telegram":{"ownerUserId":42}}"#)
    let config = try TelegramConfig.loadOrCreate(at: url)
    #expect(config.enabled == false)
    #expect(config.ownerUserId == 42)
    #expect(config.replyTimeoutSeconds == 900)
    #expect(!config.isComplete)
}

@Test func enabledWithOwnerIsComplete() throws {
    let url = try tempConfig(#"{"telegram":{"enabled":true,"ownerUserId":42}}"#)
    #expect(try TelegramConfig.loadOrCreate(at: url).isComplete)
}

@Test func missingFileIsNotCreated() throws {
    let url = try tempConfig(nil)
    #expect(try TelegramConfig.loadOrCreate(at: url) == .default)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
