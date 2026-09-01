import Foundation
import Testing
@testable import Core

// WhisperKit maps the language onto a `<|xx|>` prefill token and quietly substitutes the
// English one when the code is not in its table. These tests pin the check that stops that,
// and they run without the model because the check happens before it is loaded.

@Test func twoLetterCodeIsAccepted() throws {
    try WhisperTranscriber.validateLanguage("ru")
    try WhisperTranscriber.validateLanguage("en")
}

@Test func absentLanguageIsAccepted() throws {
    try WhisperTranscriber.validateLanguage(nil)
}

@Test func threeLetterCodeIsRejected() {
    // "rus" is the code Scribe wants. Whisper has no such token and would fall back to English.
    #expect(throws: TranscriptionError.self) {
        try WhisperTranscriber.validateLanguage("rus")
    }
}

@Test func rejectedCodeSaysWhatWasExpected() {
    do {
        try WhisperTranscriber.validateLanguage("rus")
        Issue.record("\"rus\" should have been rejected")
    } catch let error as TranscriptionError {
        let description = error.errorDescription ?? ""
        #expect(description.contains("rus"))
        #expect(description.contains("ISO-639-1"))
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func nonsenseCodeIsRejected() {
    #expect(throws: TranscriptionError.self) {
        try WhisperTranscriber.validateLanguage("русский")
    }
}
