import Foundation
import Testing
@testable import Core

@Test func apiKeyErrorNamesTheKeychainEntry() {
    let error = TranscriptionError.apiKeyMissing
    let description = error.errorDescription ?? ""
    #expect(description.contains("nohands-elevenlabs"))
    #expect(description.contains("api-key"))
}

@Test func emptyResultIsAnErrorWithText() {
    let description = TranscriptionError.emptyResult.errorDescription ?? ""
    #expect(!description.isEmpty)
}

@Test func requestFailureCarriesStatusAndMessage() {
    let error = TranscriptionError.requestFailed(status: 401, message: "invalid api key")
    let description = error.errorDescription ?? ""
    #expect(description.contains("401"))
    #expect(description.contains("invalid api key"))
}
