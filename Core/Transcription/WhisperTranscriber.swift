import Foundation
import WhisperKit

/// Local speech recognition on the Neural Engine.
///
/// The model is loaded by `load(model:language:)` rather than lazily on first use: loading
/// takes seconds, and hiding it inside the first `transcribe` call would make the first file
/// of a run look slow for reasons unrelated to its length.
public actor WhisperTranscriber: Transcriber {
    /// large-v3-turbo, compressed build recommended by Argmax for multilingual accuracy.
    public static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

    private let pipe: WhisperKit
    private let language: String?
    private let modelName: String

    private init(pipe: WhisperKit, language: String?, modelName: String) {
        self.pipe = pipe
        self.language = language
        self.modelName = modelName
    }

    /// Downloads the model on first call (about 600 MB) and loads it into memory.
    /// - Parameter language: ISO-639-1 code such as "ru", or nil to let the model decide.
    public static func load(
        model: String = WhisperTranscriber.defaultModel,
        language: String? = nil
    ) async throws -> WhisperTranscriber {
        do {
            let config = WhisperKitConfig(model: model)
            let pipe = try await WhisperKit(config)
            return WhisperTranscriber(pipe: pipe, language: language, modelName: model)
        } catch {
            throw TranscriptionError.modelUnavailable("\(model): \(error.localizedDescription)")
        }
    }

    static func validateReadable(_ url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscriptionError.fileNotReadable(url)
        }
    }

    public func transcribe(audio url: URL) async throws -> String {
        try Self.validateReadable(url)

        let options = DecodingOptions(language: language)
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return text
    }
}
