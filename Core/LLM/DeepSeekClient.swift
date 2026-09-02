import Foundation

/// Cleans up dictated text: fillers, repetitions, punctuation.
///
/// The only thing in this application that leaves the machine, and only ever the owner's own
/// speech — meeting transcripts are summarized locally for exactly this reason.
public actor DeepSeekClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
    /// Roughly what fits on one line of the failure panel without crowding it out; the exact
    /// number is not load-bearing.
    private static let messageDisplayLimit = 200

    /// Where the API key comes from. `.fixed` is what every test and the CLI's eager path use;
    /// `.keychain` defers the actual lookup to `clean(_:)` — see the initializer below for why.
    private enum KeySource {
        case fixed(String)
        case keychain
    }

    private let keySource: KeySource
    private let model: String
    private let prompt: String
    private let timeout: TimeInterval

    public init(apiKey: String, model: String, prompt: String, timeout: TimeInterval) {
        self.keySource = .fixed(apiKey)
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
    }

    /// Resolves the key lazily, inside `clean(_:)`, instead of at construction time.
    ///
    /// Recognition is entirely local and needs no key at all, so a launch-time lookup here
    /// would fail the whole app over a dependency dictation does not actually have. It is not
    /// hypothetical: the key is placed by hand from Terminal with `security
    /// add-generic-password`, and `NoHands.app` is a different code identity — its first read
    /// of that item raises a Keychain authorization dialog. Dismiss it once and the lookup
    /// throws, which used to mean the coordinator never got built and the hotkey went dead
    /// until the owner noticed. Deferred to `clean(_:)`, the same failure instead becomes a
    /// `CleanupError` the coordinator already turns into `.cleanupFailed` — raw text inserted,
    /// reason named on the panel, error sound played.
    public init(model: String, prompt: String, timeout: TimeInterval) {
        self.keySource = .keychain
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
    }

    /// Eager counterpart of the lazy initializer above, kept for the one call site that must
    /// still fail before the key is needed: `nohands dictate` records before it cleans, so
    /// discovering a missing key only at cleanup time would cost the owner a spoken sentence
    /// they cannot get back. A keychain that refuses the query throws with its status; only a
    /// genuinely absent item becomes `apiKeyMissing`.
    public static func fromKeychain(model: String, prompt: String, timeout: TimeInterval) throws -> DeepSeekClient {
        guard let key = try Keychain.password(
            service: Keychain.deepSeekService,
            account: Keychain.deepSeekAccount
        ) else {
            throw CleanupError.apiKeyMissing
        }
        return DeepSeekClient(apiKey: key, model: model, prompt: prompt, timeout: timeout)
    }

    public func clean(_ text: String) async throws -> String {
        let apiKey = try resolvedKey()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try CleanupPayload.body(
            model: model,
            maxTokens: CleanupPayload.tokenBudget(forCharacters: text.count),
            prompt: prompt,
            text: text
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CleanupError.requestFailed(status: 0, message: "no HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw CleanupError.requestFailed(
                status: http.statusCode,
                message: Self.truncatedForDisplay(message, limit: Self.messageDisplayLimit)
            )
        }
        return try CleanupPayload.text(from: data)
    }

    private func resolvedKey() throws -> String {
        switch keySource {
        case .fixed(let key):
            return key
        case .keychain:
            guard let key = try Keychain.password(
                service: Keychain.deepSeekService,
                account: Keychain.deepSeekAccount
            ) else {
                throw CleanupError.apiKeyMissing
            }
            return key
        }
    }

    /// The panel is a fixed-size window and the only place a `requestFailed` message is ever
    /// shown; DeepSeek's error bodies can run to several KB of JSON that would otherwise crowd
    /// it out entirely. Not actor-isolated: it touches no actor state, and keeping it that way
    /// lets it be tested without an instance.
    static func truncatedForDisplay(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
