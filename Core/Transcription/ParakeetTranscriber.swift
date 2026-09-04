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
public actor ParakeetTranscriber: Transcriber, TimedTranscriber {
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
        try await decode(url) { try TranscriberChecks.nonEmpty($0.text) }
    }

    /// Words with their times, for meetings. Deliberately does **not** apply
    /// `TranscriberChecks.nonEmpty`: a track that recorded nothing but silence is a legitimate
    /// outcome of a meeting — the owner may have sat the whole hour muted — and turning that
    /// into an error here would make every such meeting unprocessable. Both tracks coming back
    /// empty is a real failure, and it is caught one level up, where both are in hand.
    public func transcribeTimed(audio url: URL) async throws -> [TimedWord] {
        try await decode(url) { TokenWordAssembler.words(from: $0.tokenTimings ?? []) }
    }

    /// The decode both public methods run, differing only in what they take from the result.
    ///
    /// Extracted rather than copied: the error mapping below is the part that will grow — a new
    /// `ASRError` case, a new distinction worth making — and two copies of it would drift apart
    /// silently, because nothing fails when only one of them learns something.
    private func decode<T>(
        _ url: URL,
        extract: (ASRResult) throws -> T
    ) async throws -> T {
        try TranscriberChecks.validateReadable(url)

        // `AsrManager.transcribe(_:decoderState:language:)` reads and resamples the file itself
        // through FluidAudio's own `AudioConverter` — the library's docs warn against hand-
        // decoding audio, so this deliberately does not touch the file's bytes beyond the
        // readability check above.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        do {
            let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
            return try extract(result)
        } catch let error as ASRError {
            if case .invalidAudioData = error {
                throw TranscriptionError.audioTooShort(try AudioDuration.seconds(of: url))
            }
            // Every other ASRError (not initialized, model load, processing, compilation,
            // unsupported platform, encoder instantiation) is a broken local model, not a bad
            // request — `modelUnavailable` is the case for that.
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }
}
