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

    /// What a rejected language code is told to look like. Matches `Constants.languages`
    /// in WhisperKit, whose values are ISO-639-1 (plus a handful of three-letter exceptions
    /// Whisper itself uses, such as "yue").
    static let expectedLanguageForm = "a two-letter ISO-639-1 code such as \"ru\" or \"en\""

    private let pipe: WhisperKit
    private let language: String?
    private let modelName: String

    private init(pipe: WhisperKit, language: String?, modelName: String) {
        self.pipe = pipe
        self.language = language
        self.modelName = modelName
    }

    /// Downloads the model on first call (about 600 MB) and loads it into memory.
    /// - Parameter language: ISO-639-1 code such as "ru". Passing nil turns on WhisperKit's
    ///   own language detection; leaving it to the library's default would instead prefill an
    ///   English token and transcribe Russian speech as English, without saying so.
    /// - Throws: `TranscriptionError.languageNotSupported` if the code is not one Whisper
    ///   knows — checked before the download, so a mistyped flag costs no traffic.
    public static func load(
        model: String = WhisperTranscriber.defaultModel,
        language: String? = nil
    ) async throws -> WhisperTranscriber {
        try validateLanguage(language)
        do {
            let config = WhisperKitConfig(model: model)
            let pipe = try await WhisperKit(config)
            return WhisperTranscriber(pipe: pipe, language: language, modelName: model)
        } catch {
            throw TranscriptionError.modelUnavailable("\(model): \(error.localizedDescription)")
        }
    }

    /// WhisperKit turns the language into the `<|xx|>` prefill token and silently falls back
    /// to the English one when the code is not in its table (`TextDecoder.prefillDecoderInputs`),
    /// so an unknown code has to be rejected here — nothing downstream will complain.
    static func validateLanguage(_ language: String?) throws {
        guard let language else { return }
        guard Constants.languageCodes.contains(language) else {
            throw TranscriptionError.languageNotSupported(
                code: language,
                expected: expectedLanguageForm
            )
        }
    }

    public func transcribe(audio url: URL) async throws -> String {
        try TranscriberChecks.validateReadable(url)

        // `detectLanguage` defaults to `!usePrefillPrompt`, i.e. false, so without this a nil
        // language means "English", not "decide for yourself".
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)

        return try TranscriberChecks.nonEmpty(results.map(\.text).joined(separator: " "))
    }
}
