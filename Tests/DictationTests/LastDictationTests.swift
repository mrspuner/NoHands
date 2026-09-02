import Foundation
import Testing
@testable import Dictation

private func scratchFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-last-\(UUID().uuidString).wav")
    try Data([0]).write(to: url)
    return url
}

@Test func nothingIsRememberedAtFirst() async {
    #expect(await LastDictation().current() == nil)
}

@Test func theLastEntryIsReturned() async throws {
    let store = LastDictation()
    let audio = try scratchFile()
    defer { try? FileManager.default.removeItem(at: audio) }

    await store.remember(LastDictation.Entry(audio: audio, raw: "эээ привет", cleaned: "Привет."))
    let current = await store.current()
    #expect(current?.raw == "эээ привет")
    #expect(current?.cleaned == "Привет.")
}

// Exactly one recording is kept. Keeping more would grow without bound on a 256 GB disk, and
// keeping none would leave nothing to examine when a word comes out wrong.
@Test func rememberingAgainDeletesThePreviousAudio() async throws {
    let store = LastDictation()
    let first = try scratchFile()
    let second = try scratchFile()
    defer { try? FileManager.default.removeItem(at: second) }

    await store.remember(LastDictation.Entry(audio: first, raw: "один", cleaned: nil))
    await store.remember(LastDictation.Entry(audio: second, raw: "два", cleaned: nil))

    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(await store.current()?.raw == "два")
}

@Test func aDictationWithoutCleanupIsStillRemembered() async throws {
    let store = LastDictation()
    let audio = try scratchFile()
    defer { try? FileManager.default.removeItem(at: audio) }

    await store.remember(LastDictation.Entry(audio: audio, raw: "сырой", cleaned: nil))
    #expect(await store.current()?.cleaned == nil)
}

// `DictationCoordinator.stop()` clears its store on teardown so a rebuild does not abandon the
// previous store's file in the temp directory — nothing else would ever call `remember` on it
// again to replace it.
@Test func clearingDeletesTheFileAndForgetsTheEntry() async throws {
    let store = LastDictation()
    let audio = try scratchFile()

    await store.remember(LastDictation.Entry(audio: audio, raw: "раз", cleaned: nil))
    await store.clear()

    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(await store.current() == nil)
}

@Test func clearingAnEmptyStoreDoesNothing() async {
    let store = LastDictation()
    await store.clear()
    #expect(await store.current() == nil)
}
