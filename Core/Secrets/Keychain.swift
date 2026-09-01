import Foundation
import Security

/// Reads secrets from the login keychain. Read-only on purpose: keys are placed once by hand
/// with `security add-generic-password`, so no code path can ever write or print one.
public enum Keychain {
    public static let elevenLabsService = "nohands-elevenlabs"
    public static let elevenLabsAccount = "api-key"

    public static func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
