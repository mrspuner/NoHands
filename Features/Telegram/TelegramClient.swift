import Foundation

public struct TelegramClient: TelegramAPI {
    private let token: String
    private let session: URLSession

    public init(token: String) {
        self.init(token: token, session: .shared)
    }

    init(token: String, session: URLSession) {
        self.token = token
        self.session = session
    }

    // MARK: TelegramAPI

    public func updates(offset: Int64, timeout: Int) async throws -> [TelegramUpdate] {
        let body = try JSONSerialization.data(withJSONObject: [
            "offset": offset, "timeout": timeout, "allowed_updates": ["message", "callback_query"],
        ] as [String: Any])
        let data = try await call("getUpdates", body: body, timeout: 60)
        return try Self.decodeUpdates(data, token: token)
    }

    public func send(chatID: Int64, html: String, replyTo: Int64?, buttons: [String]) async throws -> Int64 {
        let body = try Self.sendBody(chatID: chatID, html: html, replyTo: replyTo, buttons: buttons)
        let data = try await call("sendMessage", body: body, timeout: 30)
        struct Sent: Decodable { let message_id: Int64 }
        struct Envelope: Decodable { let result: Sent }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).result.message_id
        } catch {
            throw TelegramError.wrapping(error, token: token)
        }
    }

    public func answerCallback(id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["callback_query_id": id])
        _ = try await call("answerCallbackQuery", body: body, timeout: 30)
    }

    // MARK: Pure helpers

    static func request(token: String, method: String, body: Data, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    static func sendBody(chatID: Int64, html: String, replyTo: Int64?, buttons: [String]) throws -> Data {
        var body: [String: Any] = ["chat_id": chatID, "text": html, "parse_mode": "HTML"]
        if let replyTo {
            body["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] as [String: Any]
        }
        if !buttons.isEmpty {
            let rows = buttons.enumerated().map { [["text": $0.element, "callback_data": "b:\($0.offset)"]] }
            body["reply_markup"] = ["inline_keyboard": rows]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Parses a Bot API response and returns the updates; `ok: false` becomes `TelegramError.api`.
    static func decodeUpdates(_ data: Data, token: String = "") throws -> [TelegramUpdate] {
        struct Envelope: Decodable {
            let ok: Bool
            let result: [TelegramUpdate]?
            let error_code: Int?
            let description: String?
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw TelegramError.wrapping(error, token: token)
        }
        guard envelope.ok else {
            throw TelegramError.api(
                code: envelope.error_code ?? 0,
                description: TelegramError.scrub(envelope.description ?? "unknown", token: token)
            )
        }
        return envelope.result ?? []
    }

    static func apiError(status: Int, data: Data, token: String) -> TelegramError {
        struct Envelope: Decodable { let error_code: Int?; let description: String? }
        if let e = try? JSONDecoder().decode(Envelope.self, from: data), let description = e.description {
            return .api(code: e.error_code ?? status, description: TelegramError.scrub(description, token: token))
        }
        return .api(code: status, description: "HTTP \(status)")
    }

    // MARK: Transport

    private func call(_ method: String, body: Data, timeout: TimeInterval) async throws -> Data {
        let request = Self.request(token: token, method: method, body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TelegramError.wrapping(error, token: token)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.apiError(status: status, data: data, token: token)
        }
        // A 2xx body may still say ok:false.
        struct Ok: Decodable { let ok: Bool }
        if let ok = try? JSONDecoder().decode(Ok.self, from: data), !ok.ok {
            _ = try Self.decodeUpdates(data, token: token)
        }
        return data
    }
}
