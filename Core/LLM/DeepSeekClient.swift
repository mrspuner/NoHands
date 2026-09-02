import Foundation

/// Cleans up dictated text: fillers, repetitions, punctuation.
///
/// The only thing in this application that leaves the machine, and only ever the owner's own
/// speech — meeting transcripts are summarized locally for exactly this reason.
public actor DeepSeekClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!

    private let apiKey: String
    private let model: String
    private let prompt: String
    private let timeout: TimeInterval

    public init(apiKey: String, model: String, prompt: String, timeout: TimeInterval) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
    }

    /// A keychain that refuses the query throws with its status; only a genuinely absent item
    /// becomes `apiKeyMissing`.
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
            throw CleanupError.requestFailed(status: http.statusCode, message: message)
        }
        return try CleanupPayload.text(from: data)
    }
}
