import Foundation

/// Checks every `Transcriber` implementation has to make, kept in one place.
///
/// Both are about the same rule: never hand the caller a silent fallback. A path that cannot
/// be read and a model that returned nothing are the two ways a run can end with an empty
/// string, and both must surface as errors instead. Keeping them here rather than inside each
/// implementation makes them testable without a network call or a 626 MB model, and stops the
/// two implementations from drifting apart on what counts as a failure.
enum TranscriberChecks {
    /// Fails before any expensive work when the audio file cannot be opened.
    static func validateReadable(_ url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscriptionError.fileNotReadable(url)
        }
    }

    /// Trims the engine's output and rejects it if nothing is left.
    ///
    /// Both engines can return an empty string on silence or noise. Passing that on as an
    /// ordinary result would later paste emptiness into a text field with no explanation.
    static func nonEmpty(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return trimmed
    }
}
