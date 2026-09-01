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

// The CLI reports failures with `error.localizedDescription`, not `errorDescription`. That
// path goes through the Error-to-NSError bridge, so this pins that the bridge really picks up
// LocalizedError and the sentences above are the ones the owner sees.
@Test func localizedDescriptionCarriesOurText() {
    let error: Error = TranscriptionError.apiKeyMissing
    #expect(error.localizedDescription == TranscriptionError.apiKeyMissing.errorDescription)
    #expect(error.localizedDescription.contains("nohands-elevenlabs"))
}

@Test func recordingErrorLocalizedDescriptionCarriesOurText() {
    let error: Error = RecordingError.noInputDevice
    #expect(error.localizedDescription == RecordingError.noInputDevice.errorDescription)
}

@Test func keychainErrorLocalizedDescriptionCarriesOurText() {
    let error: Error = KeychainError.invalidData(service: "nohands-elevenlabs")
    #expect(error.localizedDescription.contains("nohands-elevenlabs"))
}
