import Foundation

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case fileNotReadable(URL)
    case audioTooShort(TimeInterval)
    case apiKeyMissing
    case requestFailed(status: Int, message: String)
    case modelUnavailable(String)
    /// The engine returned nothing. Reported instead of an empty string on purpose:
    /// a silent empty result would later be pasted into a text field with no explanation.
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .fileNotReadable(let url):
            return "Audio file is not readable: \(url.path)"
        case .audioTooShort(let duration):
            return "Audio is too short to transcribe: \(String(format: "%.2f", duration)) s"
        case .apiKeyMissing:
            return "ElevenLabs API key not found in Keychain (service: nohands-elevenlabs, account: api-key)"
        case .requestFailed(let status, let message):
            return "Speech-to-text request failed with HTTP \(status): \(message)"
        case .modelUnavailable(let name):
            return "Local model is unavailable: \(name)"
        case .emptyResult:
            return "Transcription returned no text"
        }
    }
}
