import AVFoundation
import FluidAudio
import Foundation

/// Local speech recognition through FluidAudio's Parakeet TDT v3 (CoreML on the Neural Engine).
///
/// `FluidAudio.Language` is not a language selector: the v3 model is multilingual regardless of
/// the flag. It only steers `TdtDecoderV3`'s top-K search to prefer same-script token candidates
/// on close calls (Latin vs Cyrillic homophones), so passing it narrows ambiguity rather than
/// switching what the model understands. Source:
/// `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/TokenLanguageFilter.swift` and the
/// `language:` doc comments on `AsrManager.transcribe`.
public actor ParakeetTranscriber: Transcriber {
    /// v3 is the multilingual build (25 European languages, including Russian). `.v2` is
    /// English-only and has no use in this project.
    public static let defaultVersion: AsrModelVersion = .v3

    /// What a rejected language code is told to look like. FluidAudio's `Language` enum is a
    /// closed list of ISO-639-1 codes (see `TokenLanguageFilter.swift`), not open-ended like
    /// Scribe's service-side detection.
    static let expectedLanguageForm = "a two-letter ISO-639-1 code supported by FluidAudio, such as \"ru\" or \"en\""

    private let manager: AsrManager
    private let decoderLayers: Int
    private let language: Language?

    private init(manager: AsrManager, decoderLayers: Int, language: Language?) {
        self.manager = manager
        self.decoderLayers = decoderLayers
        self.language = language
    }

    /// Downloads the model on first call (hundreds of MB) and loads it into memory.
    /// - Parameter language: ISO-639-1 code such as "ru", or nil to leave FluidAudio's
    ///   script-filtering hint off. See the type documentation for what this does and does not
    ///   control.
    /// - Throws: `TranscriptionError.languageNotSupported` if the code is not one of
    ///   FluidAudio's `Language` cases — checked before the download, so a mistyped flag costs
    ///   no traffic.
    public static func load(language: String? = nil) async throws -> ParakeetTranscriber {
        try validateLanguage(language)
        let resolvedLanguage = language.flatMap(Language.init(rawValue:))
        do {
            let models = try await AsrModels.downloadAndLoad(version: defaultVersion)
            let manager = AsrManager(models: models)
            let decoderLayers = await manager.decoderLayerCount
            return ParakeetTranscriber(manager: manager, decoderLayers: decoderLayers, language: resolvedLanguage)
        } catch {
            throw TranscriptionError.modelUnavailable("parakeet-tdt-0.6b-v3: \(error.localizedDescription)")
        }
    }

    static func validateLanguage(_ language: String?) throws {
        guard let language else { return }
        guard Language(rawValue: language) != nil else {
            throw TranscriptionError.languageNotSupported(
                code: language,
                expected: expectedLanguageForm
            )
        }
    }

    public func transcribe(audio url: URL) async throws -> String {
        try TranscriberChecks.validateReadable(url)

        // `AsrManager.transcribe(_:decoderState:language:)` reads and resamples the file itself
        // through FluidAudio's own `AudioConverter` — the library's docs warn against hand-
        // decoding audio, so this deliberately does not touch the file's bytes beyond the
        // readability check above.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        do {
            let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
            return try TranscriberChecks.nonEmpty(result.text)
        } catch let error as ASRError {
            if case .invalidAudioData = error {
                throw TranscriptionError.audioTooShort(try Self.duration(of: url))
            }
            // Every other ASRError (not initialized, model load, processing, compilation,
            // unsupported platform, encoder instantiation) is a broken local model, not a bad
            // request — `modelUnavailable` is the case for that; nothing about the case ties it
            // to load time specifically.
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
