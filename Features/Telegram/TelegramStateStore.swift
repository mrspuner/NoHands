import Foundation

public struct SentMessage: Codable, Equatable, Sendable {
    public var ref: String?
    public var buttons: [String]
    public var sentAt: Date

    /// The text is not stored: on a reply Telegram sends `reply_to_message.text` itself.
    public init(ref: String?, buttons: [String], sentAt: Date) {
        self.ref = ref
        self.buttons = buttons
        self.sentAt = sentAt
    }
}

public struct Conversation: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var lastReplyAt: Date

    public init(sessionID: UUID, lastReplyAt: Date) {
        self.sessionID = sessionID
        self.lastReplyAt = lastReplyAt
    }
}

public struct TelegramState: Codable, Equatable, Sendable {
    /// Next `offset` for `getUpdates`.
    public var updateOffset: Int64 = 0
    public var sentInboxRefs: [String] = []
    /// Keyed by `message_id` as a string; capped at `maxSentMessages`, oldest by `sentAt` dropped.
    public var sentMessages: [String: SentMessage] = [:]
    public var conversation: Conversation?
    /// Outbox files already sent whose removal has not been seen yet, oldest first; capped at
    /// `maxDeliveredOutbox`. A file that could not be deleted is skipped by name instead of resent.
    public var deliveredOutbox: [String] = []

    public static let maxSentMessages = 500
    public static let maxDeliveredOutbox = 100

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case updateOffset, sentInboxRefs, sentMessages, conversation, deliveredOutbox
    }

    // Keys added later are optional, so a file written by an earlier build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateOffset = try c.decode(Int64.self, forKey: .updateOffset)
        sentInboxRefs = try c.decode([String].self, forKey: .sentInboxRefs)
        sentMessages = try c.decode([String: SentMessage].self, forKey: .sentMessages)
        conversation = try c.decodeIfPresent(Conversation.self, forKey: .conversation)
        deliveredOutbox = try c.decodeIfPresent([String].self, forKey: .deliveredOutbox) ?? []
    }
}

/// Persists the bot state. Both the bot and the reply agent write it, so every
/// read-modify-write goes through `update`, which runs entirely inside the actor.
public actor TelegramStateStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// No file means an empty state (nothing is written). An unreadable file throws and is left as is.
    public func load() throws -> TelegramState {
        guard FileManager.default.fileExists(atPath: url.path) else { return TelegramState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TelegramState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: TelegramState) throws {
        var state = state
        if state.sentMessages.count > TelegramState.maxSentMessages {
            let keep = state.sentMessages
                .sorted { $0.value.sentAt > $1.value.sentAt }
                .prefix(TelegramState.maxSentMessages)
            state.sentMessages = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        state.deliveredOutbox = Array(state.deliveredOutbox.suffix(TelegramState.maxDeliveredOutbox))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// Loads, applies `body`, saves and returns its result with no suspension in between.
    public func update<T>(_ body: (inout TelegramState) throws -> T) throws -> T {
        var state = try load()
        let result = try body(&state)
        try save(state)
        return result
    }
}
