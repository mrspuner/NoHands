import Foundation
import Testing
@testable import CLI

// Parsing lives in `TranscribeArguments` precisely so it can be tested without touching
// `exit(1)` or loading a model.

@Test func defaultsToParakeetEngine() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav"])
    #expect(parsed.engine == "parakeet")
}

@Test func keytermsIsStillRejectedWithParakeetEngine() {
    #expect(throws: TranscribeArguments.ParseError.self) {
        try TranscribeArguments.parse(["transcribe", "audio.wav", "--keyterms", "термин"])
    }
}

// Parakeet added for the FluidAudio spike: it takes `--language` (validated against
// FluidAudio's own closed list) but not `--keyterms` — that is a Scribe API feature.

@Test func parakeetEngineAcceptsLanguage() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "parakeet", "--language", "ru"])
    #expect(parsed.engine == "parakeet")
    #expect(parsed.language == "ru")
}

@Test func keytermsIsRejectedWithParakeetEngine() {
    #expect(throws: TranscribeArguments.ParseError.self) {
        try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "parakeet", "--keyterms", "термин"])
    }
}
