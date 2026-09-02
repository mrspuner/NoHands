import Foundation
import Testing
@testable import Dictation

// A config file that is missing keys must not be a failure: the owner edits this file by hand,
// and deleting a line to "reset it" is the natural thing to try.
@Test func missingKeysFallBackToDefaults() throws {
    let config = try DictationConfig.decode(Data("{}".utf8))
    #expect(config == DictationConfig.default)
}

@Test func onlyTheGivenKeyChanges() throws {
    let config = try DictationConfig.decode(Data(#"{"minimumHoldSeconds": 0.8}"#.utf8))
    #expect(config.minimumHoldSeconds == 0.8)
    #expect(config.maxRecordingSeconds == DictationConfig.default.maxRecordingSeconds)
    #expect(config.prompt == DictationConfig.default.prompt)
}

@Test func nestedSoundsAlsoFallBack() throws {
    let config = try DictationConfig.decode(Data(#"{"sounds": {"enabled": false}}"#.utf8))
    #expect(config.sounds.enabled == false)
    #expect(config.sounds.start == DictationConfig.default.sounds.start)
}

@Test func languageCanBeNull() throws {
    let config = try DictationConfig.decode(Data(#"{"language": null}"#.utf8))
    #expect(config.language == nil)
}

// Broken JSON is an error, not a silent reset: quietly falling back to defaults would leave
// the owner editing a file the app has stopped reading.
@Test func brokenJSONThrows() {
    #expect(throws: (any Error).self) {
        try DictationConfig.decode(Data("{ not json".utf8))
    }
}

@Test func missingFileIsCreatedWithDefaults() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-config-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let config = try DictationConfig.loadOrCreate(at: url)
    #expect(config == DictationConfig.default)
    #expect(FileManager.default.fileExists(atPath: url.path))

    // And what was written is readable back as the same thing.
    #expect(try DictationConfig.loadOrCreate(at: url) == DictationConfig.default)
}

@Test func existingFileIsRead() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"timeoutSeconds": 3}"#.utf8).write(to: url)

    #expect(try DictationConfig.loadOrCreate(at: url).timeoutSeconds == 3)
}

// A file that exists but cannot be read (permissions, a transient I/O error, an editor holding
// it mid-write) must not be treated the same as a file that does not exist: that would silently
// replace the owner's hand-edited config with the defaults. A directory at the config path is a
// reliable, permissions-independent way to make the read fail.
@Test func unreadableFileThrowsRatherThanBeingOverwritten() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-config-\(UUID().uuidString)")
    let configPath = directory.appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: (any Error).self) {
        try DictationConfig.loadOrCreate(at: configPath)
    }

    // Nothing was written over it: the path is still a directory, not a defaults file.
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: configPath.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

// `language: nil` means "let Parakeet detect it" and must survive a write-then-read cycle
// unchanged. The synthesized encoder would drop the key when the value is nil, which on
// decode reads back as "key absent" — the default language, not nil.
@Test func nullLanguageRoundTripsThroughEncoding() throws {
    var config = DictationConfig.default
    config.language = nil

    let data = try JSONEncoder().encode(config)
    let decoded = try DictationConfig.decode(data)

    #expect(decoded.language == nil)
}
