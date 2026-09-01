import Foundation
import Testing
@testable import Core

// FluidAudio's `Language` is a closed `CaseIterable` enum of ISO-639-1 codes (see
// `TokenLanguageFilter.swift` in the checked-out package). These tests pin the check that
// rejects anything outside it, and they run without the model because the check happens
// before the model is loaded.
//
// Names are prefixed `parakeet` to avoid colliding with the identically-shaped tests in
// `WhisperTranscriberTests.swift` — both are top-level `@Test` functions in the same module.

@Test func parakeetTwoLetterCodeIsAccepted() throws {
    try ParakeetTranscriber.validateLanguage("ru")
    try ParakeetTranscriber.validateLanguage("en")
}

@Test func parakeetAbsentLanguageIsAccepted() throws {
    try ParakeetTranscriber.validateLanguage(nil)
}

@Test func parakeetUnknownTwoLetterCodeIsRejected() {
    // FluidAudio's Language enum is a closed list of European codes (Latin, Cyrillic and Greek
    // script only); Chinese is not one of them, unlike Scribe's open-ended service-side
    // detection.
    #expect(throws: TranscriptionError.self) {
        try ParakeetTranscriber.validateLanguage("zh")
    }
}

@Test func parakeetRejectedCodeSaysWhatWasExpected() {
    do {
        try ParakeetTranscriber.validateLanguage("zh")
        Issue.record("\"zh\" should have been rejected")
    } catch let error as TranscriptionError {
        let description = error.errorDescription ?? ""
        #expect(description.contains("zh"))
        #expect(description.contains("ISO-639-1"))
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func parakeetNonsenseCodeIsRejected() {
    #expect(throws: TranscriptionError.self) {
        try ParakeetTranscriber.validateLanguage("русский")
    }
}

@Test func parakeetThreeLetterCodeIsRejected() {
    // Scribe wants "rus"; FluidAudio's Language only has two-letter codes.
    #expect(throws: TranscriptionError.self) {
        try ParakeetTranscriber.validateLanguage("rus")
    }
}
