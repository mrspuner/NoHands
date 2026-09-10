import Foundation
import Testing
@testable import Core

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("voices-\(UUID().uuidString)")
        .appendingPathComponent(".voices.json")
}

@Test func aMissingFileReadsAsAnEmptyBook() async throws {
    let store = VoiceStore(url: temporaryURL())
    #expect(try await store.book() == VoiceBook.empty)
}

@Test func whatIsSavedIsReadBack() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    try await store.save(book)
    #expect(try await store.book().name(of: id) == "Настя")
}

// The fingerprints cannot be rebuilt once the audio is gone — a week after the meeting there is
// nothing left to re-derive them from. So a file that does not parse is a refusal, never an
// empty book: an empty book would be written back over the only copy at the next save.
@Test func aBrokenFileIsRefusedRatherThanReplaced() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{ not json".utf8).write(to: url)
    let store = VoiceStore(url: url)
    await #expect(throws: (any Error).self) { try await store.book() }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "{ not json")
}

@Test func theStoreCreatesItsDirectory() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    try await store.save(VoiceBook.empty)
    #expect(FileManager.default.fileExists(atPath: url.path))
}
