import Foundation
import Testing
@testable import Dictation

@MainActor
private func scratchFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-recent-\(UUID().uuidString).wav")
    try Data([0]).write(to: url)
    return url
}

@MainActor
@Test func nothingIsRememberedAtFirst() {
    #expect(RecentDictations().entries().isEmpty)
}

@MainActor
@Test func theNewestComesFirst() {
    let store = RecentDictations()
    store.remember(raw: "один", cleaned: nil, audio: nil)
    store.remember(raw: "два", cleaned: nil, audio: nil)
    #expect(store.entries().map(\.raw) == ["два", "один"])
}

// Ten covers a working session; the eleventh pushes the oldest out rather than growing without
// bound.
@MainActor
@Test func theEleventhPushesTheOldestOut() {
    let store = RecentDictations()
    for index in 1...11 {
        store.remember(raw: "\(index)", cleaned: nil, audio: nil)
    }
    #expect(store.entries().count == RecentDictations.capacity)
    #expect(store.entries().first?.raw == "11")
    #expect(store.entries().last?.raw == "2")
}

// Exactly one recording is ever on disk: the previous newest gives up its file the moment a
// new dictation arrives.
@MainActor
@Test func onlyTheNewestKeepsItsAudio() throws {
    let store = RecentDictations()
    let first = try scratchFile()
    let second = try scratchFile()
    defer { try? FileManager.default.removeItem(at: second) }

    store.remember(raw: "один", cleaned: nil, audio: first)
    store.remember(raw: "два", cleaned: nil, audio: second)

    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(store.entries().first?.audio == second)
    #expect(store.entries().last?.audio == nil)
}

// The texts are the safety net and outlive the coordinator; the audio belongs to the
// coordinator and does not.
@MainActor
@Test func discardingAudioKeepsTheTexts() throws {
    let store = RecentDictations()
    let audio = try scratchFile()
    store.remember(raw: "сырой", cleaned: "Чистый.", audio: audio)

    store.discardAudio()

    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(store.entries().count == 1)
    #expect(store.entries().first?.audio == nil)
    #expect(store.entries().first?.cleaned == "Чистый.")
}

@MainActor
@Test func discardingAudioOnAnEmptyStoreDoesNothing() {
    RecentDictations().discardAudio()
}

// What gets copied out of the menu is what was inserted, and cleanup may not have run.
@MainActor
@Test func insertedIsTheCleanedTextWhenThereIsOne() {
    let store = RecentDictations()
    store.remember(raw: "эээ привет", cleaned: "Привет.", audio: nil)
    let entry = try! #require(store.entries().first)
    #expect(entry.inserted == "Привет.")
    #expect(entry.wasCleaned)
}

@MainActor
@Test func insertedFallsBackToTheRawText() {
    let store = RecentDictations()
    store.remember(raw: "эээ привет", cleaned: nil, audio: nil)
    let entry = try! #require(store.entries().first)
    #expect(entry.inserted == "эээ привет")
    #expect(!entry.wasCleaned)
}
