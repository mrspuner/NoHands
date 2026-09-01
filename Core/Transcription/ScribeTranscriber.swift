import Foundation

struct ScribeResponse: Decodable {
    let text: String
    let languageCode: String?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
    }

    static func decode(_ data: Data) throws -> ScribeResponse {
        try JSONDecoder().decode(ScribeResponse.self, from: data)
    }
}

/// Cloud speech recognition through ElevenLabs Scribe v2.
public actor ScribeTranscriber: Transcriber {
    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private static let modelID = "scribe_v2"

    private let apiKey: String
    private let language: String?
    private let keyterms: [String]

    /// - Parameters:
    ///   - language: ISO-639-3 code such as "rus", or nil to let the service detect it.
    ///   - keyterms: vocabulary to bias recognition towards; up to 1000 terms of 50 characters.
    public init(apiKey: String, language: String? = nil, keyterms: [String] = []) {
        self.apiKey = apiKey
        self.language = language
        self.keyterms = keyterms
    }

    /// A keychain that refuses the query throws out of `Keychain.password` with its status;
    /// only a genuinely absent item becomes `apiKeyMissing`.
    public static func fromKeychain(language: String? = nil, keyterms: [String] = []) throws -> ScribeTranscriber {
        guard let key = try Keychain.password(
            service: Keychain.elevenLabsService,
            account: Keychain.elevenLabsAccount
        ) else {
            throw TranscriptionError.apiKeyMissing
        }
        return ScribeTranscriber(apiKey: key, language: language, keyterms: keyterms)
    }

    public func transcribe(audio url: URL) async throws -> String {
        try TranscriberChecks.validateReadable(url)
        let fileData = try Data(contentsOf: url)

        var body = MultipartBody()
        body.addFile(
            name: "file",
            filename: url.lastPathComponent,
            contentType: Self.contentType(for: url),
            data: fileData
        )
        body.addField(name: "model_id", value: Self.modelID)
        if let language {
            body.addField(name: "language_code", value: language)
        }
        for term in keyterms {
            body.addField(name: "keyterms", value: term)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalized()
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.requestFailed(status: 0, message: "no HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw TranscriptionError.requestFailed(status: http.statusCode, message: message)
        }

        return try TranscriberChecks.nonEmpty(ScribeResponse.decode(data).text)
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
