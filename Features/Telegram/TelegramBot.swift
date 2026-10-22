import Foundation
import os

/// Where the bot hands the owner's messages; `ReplyAgent` in the app, a recorder in tests.
public protocol ReplySink: Sendable {
    func enqueue(_ reply: Reply) async
}

extension ReplyAgent: ReplySink {}

/// What the bot needs the panel to show.
public enum Notice: Equatable, Sendable {
    /// Something has been failing to send since `since`, for over an hour.
    case deliveryStalled(since: Date)
    /// The state file does not decode; both loops have stopped.
    case stateUnreadable
}

/// Delivers BigHead's inbox items and outbox files to the owner's chat, and passes the owner's
/// messages and button presses to the reply agent.
public actor TelegramBot {
    static let partLimit = 4000
    static let quietSeconds: TimeInterval = 5
    static let passInterval: TimeInterval = 3
    static let firstRetryPause: TimeInterval = 5
    static let maxRetryPause: TimeInterval = 300
    static let stallSeconds: TimeInterval = 3600
    static let pollRetryPause: TimeInterval = 5
    static let pollTimeout = 50
    static let ack = "Принял"

    private static let logger = Logger(subsystem: "com.nohands.app", category: "telegram")

    private let api: any TelegramAPI
    private let ownerID: Int64
    private let inbox: URL
    private let outbox: URL
    private let store: TelegramStateStore
    private let replies: any ReplySink
    private let isAgentBusy: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let report: @Sendable (Notice) -> Void

    /// First failed send since the last fully successful pass.
    private var failingSince: Date?
    private var stallReported = false
    /// Set once the state file fails to decode; nothing runs after that.
    private var stateBroken = false
    /// Guards against a second pass or poll starting while one is suspended: the actor is reentrant.
    private var delivering = false
    private var polling = false
    /// Logged once per episode, reset by the next successful read.
    private var inboxUnreadableLogged = false
    private var loops: [Task<Void, Never>] = []

    private enum PassFailure: Error {
        case send
        case state
    }

    public init(
        api: any TelegramAPI,
        ownerID: Int64,
        inbox: URL,
        outbox: URL,
        store: TelegramStateStore,
        replies: any ReplySink,
        isAgentBusy: @escaping @Sendable () async -> Bool = { false },
        now: @escaping @Sendable () -> Date = Date.init,
        report: @escaping @Sendable (Notice) -> Void
    ) {
        self.api = api
        self.ownerID = ownerID
        self.inbox = inbox
        self.outbox = outbox
        self.store = store
        self.replies = replies
        self.isAgentBusy = isAgentBusy
        self.now = now
        self.report = report
    }

    public func start() {
        guard loops.isEmpty else { return }
        loops = [
            Task { await self.deliveryLoop() },
            Task { await self.pollLoop() },
        ]
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    // MARK: - Loops

    private func deliveryLoop() async {
        var pause = Self.firstRetryPause
        while !Task.isCancelled, !stateBroken {
            let ok = await deliverOnce()
            // A cancelled request surfaces as a transport error: exit rather than back off.
            if Task.isCancelled || stateBroken { return }
            if ok {
                pause = Self.firstRetryPause
                try? await Task.sleep(for: .seconds(Self.passInterval))
            } else {
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 2, Self.maxRetryPause)
            }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled, !stateBroken {
            let ok = await pollOnce()
            if Task.isCancelled || stateBroken { return }
            if !ok { try? await Task.sleep(for: .seconds(Self.pollRetryPause)) }
        }
    }

    // MARK: - Delivery

    /// One pass over the inbox, then the outbox. Returns `false` if a send or the state failed, or
    /// if another pass is already running; it never waits out a backoff itself, that is the loop's job.
    @discardableResult
    public func deliverOnce() async -> Bool {
        guard !stateBroken, !delivering else { return false }
        delivering = true
        defer { delivering = false }
        do {
            // Read up front so a broken state stops the pass before anything goes out.
            let state = try await readState()
            try await deliverInbox(skipping: Set(state.sentInboxRefs))
            try await deliverOutbox(delivered: state.deliveredOutbox)
        } catch PassFailure.send {
            let since = failingSince ?? now()
            failingSince = since
            if !stallReported, now().timeIntervalSince(since) > Self.stallSeconds {
                stallReported = true
                report(.deliveryStalled(since: since))
            }
            return false
        } catch {
            return false
        }
        failingSince = nil
        stallReported = false
        return true
    }

    private func deliverInbox(skipping sent: Set<String>) async throws {
        // A block is keyed by its heading, so one sent half-written is never sent whole. The agent
        // can pause longer than the quiet window between edits; while it runs, the inbox waits.
        guard await !isAgentBusy() else { return }
        guard let markdown = readQuietInbox() else { return }
        for item in InboxItems.parse(markdown) where !sent.contains(item.ref) {
            try await deliver(markdown: item.text, ref: item.ref)
            try await withState { $0.sentInboxRefs.append(item.ref) }
        }
    }

    /// The inbox text if it exists and has not changed for `quietSeconds`, checked on both sides
    /// of the read so a write landing during it is not mistaken for a finished file.
    private func readQuietInbox() -> String? {
        func modified() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: inbox.path))?[.modificationDate] as? Date
        }
        // No inbox yet is not an error: BigHead creates it with its first item.
        guard let before = modified(), now().timeIntervalSince(before) >= Self.quietSeconds else { return nil }
        guard let markdown = try? String(contentsOf: inbox, encoding: .utf8) else {
            if FileManager.default.fileExists(atPath: inbox.path), !inboxUnreadableLogged {
                inboxUnreadableLogged = true
                Self.logger.error("inbox exists but is not readable as UTF-8")
            }
            return nil
        }
        inboxUnreadableLogged = false
        guard modified() == before else { return nil }
        return markdown
    }

    /// `delivered` lists files sent earlier whose removal failed: they are skipped, not resent.
    /// Names whose file is gone are dropped from it.
    private func deliverOutbox(delivered: [String]) async throws {
        let pending = Outbox.pending(in: outbox)
        let present = Set(pending.map(\.url.lastPathComponent))
        if delivered.contains(where: { !present.contains($0) }) {
            try await withState { $0.deliveredOutbox.removeAll { !present.contains($0) } }
        }
        let skip = Set(delivered)
        for message in pending where !skip.contains(message.url.lastPathComponent) {
            try await deliver(markdown: message.body, ref: message.ref)
            let name = message.url.lastPathComponent
            // Recorded before the removal, so a failed removal (or a crash between the two)
            // cannot send the file again.
            try await withState { $0.deliveredOutbox.append(name) }
            do {
                try FileManager.default.removeItem(at: message.url)
            } catch {
                Self.logger.error("outbox file sent but not removed, skipped from now on: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sends every part; the first carries the buttons and is remembered with `ref`, so replies
    /// to it can be routed. A failure midway leaves the item unmarked, and the next pass sends it
    /// from the first part again: the owner may see the parts that already went out twice.
    private func deliver(markdown: String, ref: String?) async throws {
        let (body, buttons) = TelegramText.extractButtons(markdown)
        let parts = TelegramText.chunks(TelegramText.html(fromMarkdown: body), limit: Self.partLimit)
        if parts.isEmpty {
            Self.logger.info("out ref=\(ref ?? "-", privacy: .public) empty, skipped")
            return
        }
        for (index, part) in parts.enumerated() {
            let first = index == 0
            let id = try await send(part, buttons: first ? buttons : [], ref: ref)
            if first {
                let record = SentMessage(ref: ref, buttons: buttons, sentAt: now())
                try await withState { $0.sentMessages[String(id)] = record }
            }
        }
    }

    private func send(_ html: String, buttons: [String], ref: String?) async throws -> Int64 {
        do {
            let id = try await api.send(chatID: ownerID, html: html, replyTo: nil, buttons: buttons)
            Self.logger.info("out ref=\(ref ?? "-", privacy: .public) length=\(html.count, privacy: .public) sent")
            return id
        } catch TelegramError.api(code: 400, _) {
            // A hard split can leave a tag unbalanced, and a part Telegram refuses would block
            // everything behind it forever. Entities stay escaped, so the text is still valid HTML.
            let plain = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            do {
                let id = try await api.send(chatID: ownerID, html: plain, replyTo: nil, buttons: buttons)
                Self.logger.info("out ref=\(ref ?? "-", privacy: .public) length=\(plain.count, privacy: .public) sent without markup")
                return id
            } catch {
                Self.logger.error("out ref=\(ref ?? "-", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                throw PassFailure.send
            }
        } catch {
            Self.logger.error("out ref=\(ref ?? "-", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw PassFailure.send
        }
    }

    // MARK: - Receiving

    /// One `getUpdates` call and its updates. Returns `false` if the call or the state failed, or if
    /// another poll is already running.
    @discardableResult
    public func pollOnce() async -> Bool {
        guard !stateBroken, !polling else { return false }
        polling = true
        defer { polling = false }
        let offset: Int64
        do {
            offset = try await readState().updateOffset
        } catch {
            return false
        }
        let updates: [TelegramUpdate]
        do {
            updates = try await api.updates(offset: offset, timeout: Self.pollTimeout)
        } catch {
            Self.logger.error("getUpdates failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        for update in updates {
            // Persisted before handling: a crash midway loses this update rather than repeating it.
            do {
                try await withState { $0.updateOffset = update.updateID + 1 }
            } catch {
                return false
            }
            if let message = update.message {
                await handle(message)
            } else if let callback = update.callback {
                await handle(callback)
            }
        }
        return true
    }

    private func handle(_ message: TelegramUpdate.Message) async {
        guard message.fromID == ownerID else {
            Self.logger.info("dropped update from non-owner")
            return
        }
        guard let text = message.text else { return }
        Self.logger.info("in message length=\(text.count, privacy: .public)")
        do {
            _ = try await api.send(chatID: ownerID, html: Self.ack, replyTo: message.messageID, buttons: [])
        } catch {
            // The reply still goes to the agent: the ack is a courtesy, the reply is the point.
            Self.logger.error("ack failed: \(error.localizedDescription, privacy: .public)")
        }
        var ref: String?
        if let replyTo = message.replyTo {
            ref = (try? await readState())?.sentMessages[String(replyTo.messageID)]?.ref
        }
        await replies.enqueue(Reply(text: text, at: now(), ref: ref, quoted: message.replyTo?.text))
    }

    private func handle(_ callback: TelegramUpdate.Callback) async {
        guard callback.fromID == ownerID else {
            Self.logger.info("dropped update from non-owner")
            return
        }
        do {
            try await api.answerCallback(id: callback.id)
        } catch {
            Self.logger.error("answerCallback failed: \(error.localizedDescription, privacy: .public)")
        }
        guard callback.data.hasPrefix("b:"), let index = Int(callback.data.dropFirst(2)),
              let sent = (try? await readState())?.sentMessages[String(callback.messageID)],
              sent.buttons.indices.contains(index)
        else {
            Self.logger.info("in callback for unknown message or button")
            return
        }
        Self.logger.info("in button ref=\(sent.ref ?? "-", privacy: .public)")
        await replies.enqueue(Reply(text: sent.buttons[index], at: now(), ref: sent.ref, quoted: nil))
    }

    // MARK: - State

    private func readState() async throws -> TelegramState {
        do {
            return try await store.load()
        } catch {
            stateFailed(error)
            throw PassFailure.state
        }
    }

    /// Every write goes through `update`: the reply agent writes the same file concurrently.
    private func withState(_ body: @Sendable (inout TelegramState) -> Void) async throws {
        do {
            try await store.update(body)
        } catch {
            stateFailed(error)
            throw PassFailure.state
        }
    }

    private func stateFailed(_ error: Error) {
        guard error is DecodingError else {
            Self.logger.error("state not accessible: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !stateBroken else { return }
        stateBroken = true
        Self.logger.error("state unreadable, bot stopped")
        report(.stateUnreadable)
    }
}
