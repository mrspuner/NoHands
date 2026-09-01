import Foundation
import Security

public enum KeychainError: Error, Equatable, LocalizedError {
    /// The keychain refused the query for a reason other than "no such item" — a locked
    /// keychain, a denied authorization prompt, and so on.
    case queryFailed(service: String, status: OSStatus)
    /// The item exists but does not hold UTF-8 text.
    case invalidData(service: String)

    public var errorDescription: String? {
        switch self {
        case .queryFailed(let service, let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain query for service \"\(service)\" failed with OSStatus \(status): \(reason)"
        case .invalidData(let service):
            return "Keychain item for service \"\(service)\" does not hold UTF-8 text"
        }
    }
}

/// Reads secrets from the login keychain. Read-only on purpose: keys are placed once by hand
/// with `security add-generic-password`, so no code path can ever write or print one.
public enum Keychain {
    public static let elevenLabsService = "nohands-elevenlabs"
    public static let elevenLabsAccount = "api-key"

    /// - Returns: the secret, or nil when the keychain holds no such item.
    /// - Throws: `KeychainError` for every other outcome. Collapsing those into nil would
    ///   report a refused authorization prompt as "the key is missing" and send the owner
    ///   looking for a key that is right there.
    public static func password(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return try value(status: status, data: item as? Data, service: service)
    }

    /// Split out from the query so every branch is reachable in a test without a keychain.
    static func value(status: OSStatus, data: Data?, service: String) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData(service: service)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.queryFailed(service: service, status: status)
        }
    }
}
