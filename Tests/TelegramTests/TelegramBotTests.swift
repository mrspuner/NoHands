import Foundation
import os
import Testing
@testable import Telegram

private let owner: Int64 = 777
private let stranger: Int64 = 999
private let start = Date(timeIntervalSince1970: 1_790_000_000)

private final class Clock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: start)
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

/// Records successful sends; `failing` makes every send throw, `rejectTags` answers 400 to any
/// part containing a tag, the way Telegram rejects malformed HTML.
private actor FakeAPI: TelegramAPI {
    struct Sent: Equatable {
        var chatID: Int64
        var html: String
        var replyTo: Int64?
        var buttons: [String]
    }

    var sent: [Sent] = []
    var answered: [String] = []
    var offsets: [Int64] = []
    var failing = false
    var rejectTags = false
    private var queued: [TelegramUpdate] = []
    private var nextID: Int64 = 100

    func setFailing(_ value: Bool) { failing = value }
    func setRejectTags(_ value: Bool) { rejectTags = value }
    func queue(_ updates: [TelegramUpdate]) { queued += updates }

    func updates(offset: Int64, timeout: Int) async throws -> [TelegramUpdate] {
        offsets.append(offset)
        defer { queued = [] }
        return queued
    }

    func send(chatID: Int64, html: String, replyTo: Int64?, buttons: [String]) async throws -> Int64 {
        if failing { throw TelegramError.transport("offline") }
        if rejectTags, html.contains("<") { throw TelegramError.api(code: 400, description: "can't parse entities") }
        sent.append(Sent(chatID: chatID, html: html, replyTo: replyTo, buttons: buttons))
        defer { nextID += 1 }
        return nextID
    }

    func answerCallback(id: String) async throws {
        answered.append(id)
    }
}

/// Records replies together with the persisted offset at the moment each arrived.
private actor FakeReplies: ReplySink {
    var replies: [Reply] = []
    var offsetsSeen: [Int64] = []
    let store: TelegramStateStore

    init(store: TelegramStateStore) { self.store = store }

    func enqueue(_ reply: Reply) async {
        replies.append(reply)
        offsetsSeen.append((try? await store.load().updateOffset) ?? -1)
    }
}

private final class Notices: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: [Notice]())
    var all: [Notice] { value.withLock { $0 } }
    func append(_ notice: Notice) { value.withLock { $0.append(notice) } }
}

private struct Fixture {
    let dir: URL
    let inbox: URL
    let outbox: URL
    let store: TelegramStateStore
    let api = FakeAPI()
    let clock = Clock()
    let notices = Notices()
    let replies: FakeReplies
    let bot: TelegramBot

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tgbot-\(UUID().uuidString)")
        inbox = dir.appendingPathComponent("inbox.md")
        outbox = dir.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        store = TelegramStateStore(url: dir.appendingPathComponent("telegram-state.json"))
        replies = FakeReplies(store: store)
        let clock = clock, notices = notices
        bot = TelegramBot(
            api: api, ownerID: owner, inbox: inbox, outbox: outbox, store: store, replies: replies,
            now: { clock.now }, report: { notices.append($0) })
    }

    /// Writes the inbox and backdates it by `age` seconds relative to the fake clock.
    func writeInbox(_ text: String, age: TimeInterval = 60) throws {
        try text.write(to: inbox, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now.addingTimeInterval(-age)], ofItemAtPath: inbox.path)
    }

    func writeOutbox(_ name: String, _ text: String) throws {
        try text.write(to: outbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

private func update(_ id: Int64, message: TelegramUpdate.Message? = nil,
                    callback: TelegramUpdate.Callback? = nil) throws -> TelegramUpdate {
    // `TelegramUpdate` only decodes; build the wire JSON.
    var json: [String: Any] = ["update_id": id]
    if let m = message {
        var wire: [String: Any] = ["message_id": m.messageID, "from": ["id": m.fromID], "chat": ["id": m.chatID]]
        if let text = m.text { wire["text"] = text }
        if let r = m.replyTo {
            var reply: [String: Any] = ["message_id": r.messageID]
            if let text = r.text { reply["text"] = text }
            wire["reply_to_message"] = reply
        }
        json["message"] = wire
    }
    if let c = callback {
        json["callback_query"] = [
            "id": c.id, "from": ["id": c.fromID], "data": c.data,
            "message": ["message_id": c.messageID, "chat": ["id": c.fromID]],
        ]
    }
    return try JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: json))
}

private let inboxA = """
    # Входящие

    ## Ждёт ответа

    ### Отпуск в ноябре
    Согласовать даты?
    <!-- кнопки
    Да
    Нет
    -->
    """

// MARK: - Delivery

@Test func newInboxBlockIsSentOnce() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA)
    #expect(await f.bot.deliverOnce())
    #expect(await f.bot.deliverOnce())
    let sent = await f.api.sent
    #expect(sent.count == 1)
    #expect(sent.first?.chatID == owner)
    #expect(sent.first?.html == "<b>Отпуск в ноябре</b>\nСогласовать даты?")
    #expect(sent.first?.buttons == ["Да", "Нет"])
    let state = try await f.store.load()
    #expect(state.sentInboxRefs == ["Отпуск в ноябре"])
    #expect(state.sentMessages["100"] == SentMessage(ref: "Отпуск в ноябре", buttons: ["Да", "Нет"], sentAt: start))
}

@Test func editedBlockIsNotResent() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA)
    await f.bot.deliverOnce()
    try f.writeInbox(inboxA.replacingOccurrences(of: "Согласовать даты?", with: "Согласовать даты? Уже решено."))
    await f.bot.deliverOnce()
    #expect(await f.api.sent.count == 1)
}

@Test func freshInboxWaitsForQuiet() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA, age: 2)
    try f.writeOutbox("20261022-120000-aaaaaa.md", "Ответ")
    await f.bot.deliverOnce()
    // The outbox is not held back by a busy inbox.
    #expect(await f.api.sent.map(\.html) == ["Ответ"])
    f.clock.advance(5)
    await f.bot.deliverOnce()
    #expect(await f.api.sent.count == 2)
}

@Test func outboxFileIsSentAndDeleted() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeOutbox("20261022-120000-aaaaaa.md", "---\nref: Отпуск в ноябре\n---\n**Готово**")
    await f.bot.deliverOnce()
    #expect(await f.api.sent.map(\.html) == ["<b>Готово</b>"])
    #expect(Outbox.pending(in: f.outbox).isEmpty)
    #expect(try await f.store.load().sentMessages["100"]?.ref == "Отпуск в ноябре")
}

@Test func sendFailureKeepsEverythingAndRetriesInOrder() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA)
    try f.writeOutbox("20261022-120000-aaaaaa.md", "Ответ")
    await f.api.setFailing(true)
    #expect(await f.bot.deliverOnce() == false)
    #expect(Outbox.pending(in: f.outbox).count == 1)
    #expect(try await f.store.load().sentInboxRefs.isEmpty)

    await f.api.setFailing(false)
    #expect(await f.bot.deliverOnce())
    await f.bot.deliverOnce()
    #expect(await f.api.sent.map(\.html) == ["<b>Отпуск в ноябре</b>\nСогласовать даты?", "Ответ"])
    #expect(Outbox.pending(in: f.outbox).isEmpty)
}

@Test func stalledOverAnHourIsReportedOnce() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeOutbox("20261022-120000-aaaaaa.md", "Ответ")
    await f.api.setFailing(true)
    await f.bot.deliverOnce()
    f.clock.advance(1800)
    await f.bot.deliverOnce()
    #expect(f.notices.all.isEmpty)
    f.clock.advance(1801)
    await f.bot.deliverOnce()
    f.clock.advance(600)
    await f.bot.deliverOnce()
    #expect(f.notices.all == [.deliveryStalled(since: start)])

    // A successful pass ends the episode; the next one is reported again.
    await f.api.setFailing(false)
    await f.bot.deliverOnce()
    try f.writeOutbox("20261022-130000-bbbbbb.md", "Ещё")
    await f.api.setFailing(true)
    let second = f.clock.now
    await f.bot.deliverOnce()
    f.clock.advance(3601)
    await f.bot.deliverOnce()
    #expect(f.notices.all == [.deliveryStalled(since: start), .deliveryStalled(since: second)])
}

@Test func htmlRejectedPartIsResentWithoutTags() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeOutbox("20261022-120000-aaaaaa.md", "**Итог**: a < b")
    await f.api.setRejectTags(true)
    #expect(await f.bot.deliverOnce())
    #expect(await f.api.sent.map(\.html) == ["Итог: a &lt; b"])
    #expect(Outbox.pending(in: f.outbox).isEmpty)
}

@Test func unreadableStateIsReportedOnceAndStopsBothLoops() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try "not json".write(to: f.dir.appendingPathComponent("telegram-state.json"), atomically: true, encoding: .utf8)
    try f.writeOutbox("20261022-120000-aaaaaa.md", "Ответ")
    #expect(await f.bot.deliverOnce() == false)
    #expect(await f.bot.pollOnce() == false)
    #expect(await f.bot.deliverOnce() == false)
    #expect(f.notices.all == [.stateUnreadable])
    #expect(await f.api.sent.isEmpty)
    #expect(await f.api.offsets.isEmpty)
}

// MARK: - Receiving

@Test func strangerIsIgnored() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    await f.api.queue([
        try update(1, message: .init(messageID: 5, fromID: stranger, chatID: stranger, text: "привет", replyTo: nil)),
        try update(2, callback: .init(id: "cb", fromID: stranger, data: "b:0", messageID: 100)),
    ])
    await f.bot.pollOnce()
    #expect(await f.api.sent.isEmpty)
    #expect(await f.api.answered.isEmpty)
    #expect(await f.replies.replies.isEmpty)
    #expect(try await f.store.load().updateOffset == 3)
}

@Test func ownerMessageGetsAckAndIsQueued() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    await f.api.queue([
        try update(1, message: .init(messageID: 5, fromID: owner, chatID: owner, text: "купи молоко", replyTo: nil)),
        try update(2, message: .init(messageID: 6, fromID: owner, chatID: owner, text: nil, replyTo: nil)),
    ])
    await f.bot.pollOnce()
    #expect(await f.api.sent == [.init(chatID: owner, html: "Принял", replyTo: 5, buttons: [])])
    #expect(await f.replies.replies == [Reply(text: "купи молоко", at: start, ref: nil, quoted: nil)])
    // The ack is not something the owner can reply into a ref.
    #expect(try await f.store.load().sentMessages.isEmpty)
}

@Test func ackFailureStillQueues() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    await f.api.setFailing(true)
    await f.api.queue([
        try update(1, message: .init(messageID: 5, fromID: owner, chatID: owner, text: "купи молоко", replyTo: nil)),
    ])
    await f.bot.pollOnce()
    #expect(await f.replies.replies.count == 1)
}

@Test func replyToInboxMessageCarriesRef() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA)
    await f.bot.deliverOnce()
    f.clock.advance(30)
    await f.api.queue([
        try update(1, message: .init(
            messageID: 5, fromID: owner, chatID: owner, text: "давай с 10-го",
            replyTo: .init(messageID: 100, text: "Отпуск в ноябре\nСогласовать даты?"))),
    ])
    await f.bot.pollOnce()
    #expect(await f.replies.replies == [Reply(
        text: "давай с 10-го", at: start.addingTimeInterval(30), ref: "Отпуск в ноябре",
        quoted: "Отпуск в ноябре\nСогласовать даты?")])
}

@Test func callbackMapsToButtonText() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.writeInbox(inboxA)
    await f.bot.deliverOnce()
    await f.api.queue([
        try update(1, callback: .init(id: "cb1", fromID: owner, data: "b:1", messageID: 100)),
        try update(2, callback: .init(id: "cb2", fromID: owner, data: "b:7", messageID: 100)),
        try update(3, callback: .init(id: "cb3", fromID: owner, data: "b:0", messageID: 555)),
    ])
    await f.bot.pollOnce()
    #expect(await f.api.answered == ["cb1", "cb2", "cb3"])
    #expect(await f.replies.replies == [Reply(text: "Нет", at: start, ref: "Отпуск в ноябре", quoted: nil)])
    #expect(await f.api.sent.count == 1)  // the inbox message only: callbacks get no "Принял"
}

@Test func offsetIsPersistedPerUpdate() async throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    await f.api.queue([
        try update(41, message: .init(messageID: 5, fromID: owner, chatID: owner, text: "раз", replyTo: nil)),
        try update(42, message: .init(messageID: 6, fromID: owner, chatID: owner, text: "два", replyTo: nil)),
    ])
    await f.bot.pollOnce()
    #expect(await f.replies.offsetsSeen == [42, 43])
    await f.bot.pollOnce()
    #expect(await f.api.offsets == [0, 43])
}
