import Foundation

/// The body sent to DeepSeek and the answer read back, kept apart from the network call so
/// both are testable without one.
///
/// Shape confirmed against the live API on 2026-09-02: Anthropic-compatible messages endpoint
/// at `https://api.deepseek.com/anthropic/v1/messages`. See step 1 of task 3 in the plan.
enum CleanupPayload {
    private struct Request: Encodable {
        struct Thinking: Encodable {
            let type = "disabled"
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        /// Not optional and never omitted. Reasoning left on costs thirty five times the
        /// output tokens and never reaches an answer.
        let thinking = Thinking()
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case thinking
            case system
            case messages
        }
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    static func body(model: String, maxTokens: Int, prompt: String, text: String) throws -> Data {
        try JSONEncoder().encode(
            Request(
                model: model,
                maxTokens: maxTokens,
                system: prompt,
                messages: [Request.Message(role: "user", content: text)]
            )
        )
    }

    static func text(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let joined = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw CleanupError.emptyResult }
        return joined
    }
}
