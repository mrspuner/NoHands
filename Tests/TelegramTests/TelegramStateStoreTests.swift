import Foundation
import Testing
@testable import Telegram

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tgstate-\(UUID().uuidString)")
        .appendingPathComponent("telegram-state.json")
}

@Test func missingFileIsEmptyState() async throws {
    let url = tempURL()
    let state = try await TelegramStateStore(url: url).load()
    #expect(state == TelegramState())
    #expect(state.updateOffset == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func roundTrip() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = TelegramStateStore(url: url)
    var state = TelegramState()
    state.updateOffset = 42
    state.sentInboxRefs = ["a", "b"]
    state.sentMessages["7"] = SentMessage(ref: "a", buttons: ["Да", "Нет"], sentAt: Date(timeIntervalSince1970: 1000))
    state.conversation = Conversation(sessionID: UUID(), lastReplyAt: Date(timeIntervalSince1970: 2000))
    try await store.save(state)
    #expect(try await TelegramStateStore(url: url).load() == state)
}

@Test func unreadableFileThrowsAndIsKept() async throws {
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "not json".write(to: url, atomically: true, encoding: .utf8)
    let store = TelegramStateStore(url: url)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
}

@Test func sentMessagesAreCappedAt500OldestFirst() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = TelegramStateStore(url: url)
    var state = TelegramState()
    for i in 0..<510 {
        state.sentMessages[String(i)] = SentMessage(ref: nil, buttons: [], sentAt: Date(timeIntervalSince1970: Double(i)))
    }
    try await store.save(state)
    let loaded = try await store.load()
    #expect(loaded.sentMessages.count == 500)
    #expect(loaded.sentMessages["9"] == nil)
    #expect(loaded.sentMessages["10"] != nil)
    #expect(loaded.sentMessages["509"] != nil)
}

@Test func updateKeepsOtherFields() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = TelegramStateStore(url: url)
    var state = TelegramState()
    state.updateOffset = 5
    state.sentInboxRefs = ["x"]
    try await store.save(state)
    let result = try await store.update { s -> Int in
        s.sentMessages["1"] = SentMessage(ref: nil, buttons: [], sentAt: Date(timeIntervalSince1970: 1))
        return s.sentMessages.count
    }
    #expect(result == 1)
    let loaded = try await store.load()
    #expect(loaded.updateOffset == 5)
    #expect(loaded.sentInboxRefs == ["x"])
    #expect(loaded.sentMessages.count == 1)
}

@Test func fileWithoutDeliveredOutboxLoads() async throws {
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try #"{"updateOffset": 5, "sentInboxRefs": ["a"], "sentMessages": {}}"#
        .write(to: url, atomically: true, encoding: .utf8)
    let state = try await TelegramStateStore(url: url).load()
    #expect(state.updateOffset == 5)
    #expect(state.sentInboxRefs == ["a"])
    #expect(state.deliveredOutbox.isEmpty)
}

@Test func deliveredOutboxIsCappedOldestFirst() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = TelegramStateStore(url: url)
    var state = TelegramState()
    state.deliveredOutbox = (0..<(TelegramState.maxDeliveredOutbox + 3)).map { "f\($0).md" }
    try await store.save(state)
    let loaded = try await store.load().deliveredOutbox
    #expect(loaded.count == TelegramState.maxDeliveredOutbox)
    #expect(loaded.first == "f3.md")
}
