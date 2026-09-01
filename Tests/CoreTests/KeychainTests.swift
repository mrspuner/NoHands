import Foundation
import Security
import Testing
@testable import Core

// The status handling is split out of the query so these run without touching a real keychain.

@Test func foundItemIsReturnedTrimmed() throws {
    let value = try Keychain.value(
        status: errSecSuccess,
        data: Data(" sk-secret\n".utf8),
        service: "nohands-test"
    )
    #expect(value == "sk-secret")
}

@Test func absentItemIsNilRatherThanAnError() throws {
    let value = try Keychain.value(status: errSecItemNotFound, data: nil, service: "nohands-test")
    #expect(value == nil)
}

// The regression this exists for: a keychain authorization prompt returned
// errSecInteractionNotAllowed and the tool said the key was missing.
@Test func refusedQueryIsAnErrorCarryingItsStatus() {
    #expect(throws: KeychainError.queryFailed(service: "nohands-test", status: errSecInteractionNotAllowed)) {
        _ = try Keychain.value(
            status: errSecInteractionNotAllowed,
            data: nil,
            service: "nohands-test"
        )
    }
}

@Test func refusedQueryDescriptionNamesCodeAndService() {
    let error = KeychainError.queryFailed(service: "nohands-elevenlabs", status: errSecAuthFailed)
    let description = error.errorDescription ?? ""
    #expect(description.contains("\(errSecAuthFailed)"))
    #expect(description.contains("nohands-elevenlabs"))
    // Not "not found": the whole point is that these two are told apart.
    #expect(!description.lowercased().contains("not found"))
}

@Test func nonTextItemIsAnErrorRatherThanAMissingKey() {
    #expect(throws: KeychainError.invalidData(service: "nohands-test")) {
        _ = try Keychain.value(
            status: errSecSuccess,
            data: Data([0xFF, 0xFE, 0xFF]),
            service: "nohands-test"
        )
    }
}
