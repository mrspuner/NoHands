import Foundation

public enum CleanupError: Error, Equatable, LocalizedError {
    case apiKeyMissing
    case requestFailed(status: Int, message: String)
    /// The service answered with nothing usable. Reported instead of an empty string so it can
    /// never be pasted as one.
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "DeepSeek API key not found in Keychain (service: nohands-deepseek, account: api-key)"
        case .requestFailed(let status, let message):
            return "Text cleanup request failed with HTTP \(status): \(message)"
        case .emptyResult:
            return "Text cleanup returned no text"
        }
    }
}
