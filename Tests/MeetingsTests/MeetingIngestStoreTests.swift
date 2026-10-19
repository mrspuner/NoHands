import Foundation
import Testing
@testable import Meetings

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ingest-store-\(UUID().uuidString)")
        .appendingPathComponent("meeting-ingest-state.json")
}

// Whole seconds: ISO 8601 drops the fraction, so a date with one would not survive the round trip.
private let firstDay = Date(timeIntervalSince1970: 1_800_000_000)
private let laterDay = Date(timeIntervalSince1970: 1_800_086_400)

@Test func aMissingFileStartsTodayAndIsSaved() async throws {
    let url = tempURL()
    let store = MeetingIngestStore(url: url, now: { firstDay })
    let state = try await store.load()
    #expect(state.enabledAt == firstDay)
    #expect(state.handedOver == [])
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func enabledAtNeverMoves() async throws {
    let url = tempURL()
    _ = try await MeetingIngestStore(url: url, now: { firstDay }).load()
    let state = try await MeetingIngestStore(url: url, now: { laterDay }).load()
    #expect(state.enabledAt == firstDay)
}

@Test func markedNamesPersist() async throws {
    let url = tempURL()
    let store = MeetingIngestStore(url: url, now: { firstDay })
    try await store.markHandedOver("a.md")
    try await store.markHandedOver("a.md")
    let state = try await MeetingIngestStore(url: url, now: { laterDay }).load()
    #expect(state.handedOver == ["a.md"])
    #expect(state.enabledAt == firstDay)
}

@Test func aCorruptFileThrowsAndIsLeftAlone() async throws {
    let url = tempURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let garbage = Data("{".utf8)
    try garbage.write(to: url)
    let store = MeetingIngestStore(url: url, now: { firstDay })
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == garbage)
}
