import Foundation

public protocol TelegramAPI: Sendable {
    func updates(offset: Int64, timeout: Int) async throws -> [TelegramUpdate]
    /// Returns the `message_id` of the sent message.
    func send(chatID: Int64, html: String, replyTo: Int64?, buttons: [String]) async throws -> Int64
    func answerCallback(id: String) async throws
}

public struct TelegramUpdate: Decodable, Equatable, Sendable {
    public struct ReplyTo: Equatable, Sendable {
        public let messageID: Int64
        public let text: String?

        public init(messageID: Int64, text: String?) {
            self.messageID = messageID
            self.text = text
        }
    }

    public struct Message: Equatable, Sendable {
        public let messageID: Int64
        public let fromID: Int64
        public let chatID: Int64
        public let text: String?
        public let replyTo: ReplyTo?

        public init(messageID: Int64, fromID: Int64, chatID: Int64, text: String?, replyTo: ReplyTo?) {
            self.messageID = messageID
            self.fromID = fromID
            self.chatID = chatID
            self.text = text
            self.replyTo = replyTo
        }
    }

    public struct Callback: Equatable, Sendable {
        public let id: String
        public let fromID: Int64
        public let data: String
        public let messageID: Int64

        public init(id: String, fromID: Int64, data: String, messageID: Int64) {
            self.id = id
            self.fromID = fromID
            self.data = data
            self.messageID = messageID
        }
    }

    public let updateID: Int64
    public let message: Message?
    public let callback: Callback?

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id", message, callback = "callback_query"
    }

    // Wire shapes; the public types stay flat.
    private struct Ref: Decodable { let id: Int64 }
    private struct WireMessage: Decodable {
        let message_id: Int64
        let from: Ref?
        let chat: Ref
        let text: String?
        let reply_to_message: Reply?
        struct Reply: Decodable { let message_id: Int64; let text: String? }
    }
    private struct WireCallback: Decodable {
        let id: String
        let from: Ref
        let data: String?
        let message: WireMessage?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateID = try c.decode(Int64.self, forKey: .updateID)
        // A message without `from` (channel post) is not addressed to the bot by a user: treat as unknown.
        if let m = try c.decodeIfPresent(WireMessage.self, forKey: .message), let from = m.from {
            message = Message(
                messageID: m.message_id, fromID: from.id, chatID: m.chat.id, text: m.text,
                replyTo: m.reply_to_message.map { ReplyTo(messageID: $0.message_id, text: $0.text) }
            )
        } else {
            message = nil
        }
        if let cb = try c.decodeIfPresent(WireCallback.self, forKey: .callback), let data = cb.data, let m = cb.message {
            callback = Callback(id: cb.id, fromID: cb.from.id, data: data, messageID: m.message_id)
        } else {
            callback = nil
        }
    }
}

public enum TelegramError: LocalizedError, Equatable, Sendable {
    case api(code: Int, description: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .api(let code, let description): "Telegram API error \(code): \(description)"
        case .transport(let message): "Telegram request failed: \(message)"
        }
    }

    /// Removes the bot token from text; URLSession errors embed the request URL, which carries it.
    static func scrub(_ text: String, token: String) -> String {
        guard !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "<token>")
    }

    static func wrapping(_ error: Error, token: String) -> TelegramError {
        .transport(scrub(error.localizedDescription, token: token))
    }
}
