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
        /// Computed, not stored: a stored property with a default still leaves an initializer
        /// parameter that some future call site could pass a different value into. This is the
        /// single parameter the project's entire cost model rests on — reasoning left on costs
        /// thirty five times the output tokens and never reaches an answer — so there is no
        /// initializer slot for it at all.
        var thinking: Thinking { Thinking() }
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case thinking
            case system
            case messages
        }

        // Written by hand: synthesis only encodes stored properties, and `thinking` is
        // deliberately computed (see above) so it cannot be passed a different value.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(maxTokens, forKey: .maxTokens)
            try container.encode(thinking, forKey: .thinking)
            try container.encode(system, forKey: .system)
            try container.encode(messages, forKey: .messages)
        }
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    /// Cleanup returns roughly what it was given, so the budget scales with the input rather
    /// than being fixed — a long dictation must not be cut off mid-sentence. The floor keeps a
    /// short dictation from being handed a budget too small to hold the punctuation and
    /// capitalization fixes around it. The ceiling is DeepSeek's documented maximum output for
    /// `deepseek-v4-flash` — the model `deepseek-chat` resolves to, confirmed by the live probe
    /// in task 3 — 384,000 tokens, per https://api-docs.deepseek.com/quick_start/pricing,
    /// checked 2026-09-02. A probe sending `max_tokens: 1000000` was accepted with HTTP 200
    /// rather than rejected, so the ceiling here is a documented sanity bound, not a value the
    /// service itself would otherwise enforce.
    static func tokenBudget(forCharacters count: Int) -> Int {
        let floor = 256
        let ceiling = 384_000
        let multiplier = 3
        return min(ceiling, max(floor, count * multiplier))
    }

    /// The transcript goes inside a marker instead of straight into the user turn.
    ///
    /// Without it, a dictation that happens to read as a task — "объясни, как работает X",
    /// "напиши письмо коллеге" — arrives as a direct request in the user turn, and the model
    /// carries it out: the owner says one sentence and a paragraph about photosynthesis lands in
    /// their editor. The system prompt already forbids answering and still loses, because the
    /// user turn is the more specific instruction and nothing marks its content as data.
    ///
    /// Measured on the live service: three of eight ordinary imperative dictations came back as
    /// answers without the marker, none with it. The other five in the same probe — the
    /// non-actionable ones — were cleaned correctly both with and without the marker: the wrap
    /// costs nothing on ordinary dictation.
    ///
    /// A transcript containing the closing marker itself was also probed and stayed contained:
    /// it came back cleaned normally rather than escaping the envelope. There is no known need
    /// to escape marker occurrences in the text before sending it — do not add that without a
    /// probe showing it is actually needed.
    ///
    /// The marker is Russian to match the prompt and the speech it wraps — an English
    /// `<transcript>` also stopped the substitutions but obeyed a deliberate "ignore previous
    /// instructions" once in five runs, where this one obeyed none. Five runs per marker is a
    /// small sample, stated plainly: it pointed one way and never the other, which is not the
    /// same as settled.
    ///
    /// It lives here rather than in the prompt deliberately: the prompt is a key in the owner's
    /// `config.json`, so a fix written into the prompt would never reach an installation that
    /// already has one. This reaches every call.
    static let openingMarker = TranscriptEnvelope.openingMarker
    static let closingMarker = TranscriptEnvelope.closingMarker

    static func wrapped(_ text: String) -> String {
        TranscriptEnvelope.wrapped(text)
    }

    static func body(model: String, maxTokens: Int, prompt: String, text: String) throws -> Data {
        try JSONEncoder().encode(
            Request(
                model: model,
                maxTokens: maxTokens,
                system: prompt,
                messages: [Request.Message(role: "user", content: wrapped(text))]
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
