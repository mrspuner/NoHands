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

@Test func mutateAppliesAndPersistsAChange() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    let id = try await store.mutate { book in
        book.remember(VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10)
    }
    try await store.mutate { book in book.rename(id, to: "Настя") }
    #expect(try await store.book().name(of: id) == "Настя")
}

// The whole point of `mutate` over a plain `book()`/`save(_:)` pair is that nothing else can
// land a write inside the span — a throwing body must leave that guarantee intact by writing
// nothing at all, not even the state the body reached before it threw.
@Test func aThrowingBodyLeavesTheFileUntouched() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10
    )
    try await store.save(book)

    struct Marker: Error {}
    await #expect(throws: Marker.self) {
        try await store.mutate { book in
            book.rename(id, to: "someone else's name")
            throw Marker()
        }
    }

    #expect(try await store.book().name(of: id) == nil)
}

// Same property as `aBrokenFileIsRefusedRatherThanReplaced`, but through `mutate`: a corrupt
// book must still refuse instead of quietly becoming the empty book `body` would have started
// from, which would then be saved right over the only copy of fingerprints that cannot be
// rebuilt.
@Test func aCorruptBookMakesMutateThrowWithoutOverwriting() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{ not json".utf8).write(to: url)
    let store = VoiceStore(url: url)

    var bodyRan = false
    await #expect(throws: (any Error).self) {
        try await store.mutate { book in
            bodyRan = true
            book.rename("whatever", to: "irrelevant")
        }
    }

    #expect(!bodyRan)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "{ not json")
}
