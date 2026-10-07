import Foundation
import Testing
@testable import TodoistSync

private func tempConfig(_ json: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    if let json { try Data(json.utf8).write(to: url) }
    return url
}

@Test func aMissingFileGivesDefaultsAndIsNotCreated() throws {
    let url = try tempConfig(nil)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url) == .default)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// The dictation and meetings sections live in the same file and must survive the append.
@Test func aMissingSectionIsAppendedWithoutTouchingOthers() throws {
    let url = try tempConfig(#"{"language":"ru","meetings":{"silenceSeconds":5}}"#)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url) == .default)
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(root["language"] as? String == "ru")
    #expect(root["meetings"] != nil)
    #expect(root["todoist"] != nil)
}

@Test func anExistingSectionIsRead() throws {
    let url = try tempConfig(#"{"todoist":{"bigheadPath":"/b","areas":["Сколково"],"claudePath":"/c","pollSeconds":30}}"#)
    let config = try TodoistInboundConfig.loadOrCreate(at: url)
    #expect(config == TodoistInboundConfig(bigheadPath: "/b", areas: ["Сколково"], claudePath: "/c", pollSeconds: 30))
    #expect(config.isComplete)
}

// Edited by hand: a missing key falls back to its default instead of failing the whole section.
@Test func missingKeysFallBackToDefaults() throws {
    let url = try tempConfig(#"{"todoist":{"areas":["RooX"]}}"#)
    let config = try TodoistInboundConfig.loadOrCreate(at: url)
    #expect(config.areas == ["RooX"])
    #expect(config.pollSeconds == 60)
    #expect(!config.isComplete)
}

@Test func aNonObjectFileIsAnError() throws {
    let url = try tempConfig("[]")
    #expect(throws: TodoistInboundConfigError.self) { try TodoistInboundConfig.loadOrCreate(at: url) }
}

@Test func aTooShortPollIsRaisedToTenSeconds() throws {
    let url = try tempConfig(#"{"todoist":{"pollSeconds":1}}"#)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url).pollSeconds == 10)
}
