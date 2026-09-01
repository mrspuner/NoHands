import Foundation
import Testing
@testable import CLI

// Parsing lives in `TranscribeArguments` precisely so it can be tested without touching
// `exit(1)` or loading a model. These tests cover the three whisper-tuning flags added for the
// spike (`--model`, `--vad`, `--relaxed-thresholds`) plus the engine-exclusivity rules that
// mirror the existing `--keyterms` check.

@Test func defaultsHaveNoTuningFlags() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav"])
    #expect(parsed.engine == "whisper")
    #expect(parsed.model == nil)
    #expect(parsed.useVAD == false)
    #expect(parsed.relaxedThresholds == false)
}

@Test func modelFlagIsParsed() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav", "--model", "openai_whisper-large-v3_947MB"])
    #expect(parsed.model == "openai_whisper-large-v3_947MB")
}

@Test func vadFlagIsParsed() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav", "--vad"])
    #expect(parsed.useVAD == true)
}

@Test func relaxedThresholdsFlagIsParsed() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav", "--relaxed-thresholds"])
    #expect(parsed.relaxedThresholds == true)
}

@Test func vadAndRelaxedThresholdsCombine() throws {
    let parsed = try TranscribeArguments.parse(["transcribe", "audio.wav", "--vad", "--relaxed-thresholds"])
    #expect(parsed.useVAD == true)
    #expect(parsed.relaxedThresholds == true)
}

@Test func modelWithoutValueIsRejected() {
    #expect(throws: TranscribeArguments.ParseError.self) {
        try TranscribeArguments.parse(["transcribe", "audio.wav", "--model"])
    }
}

@Test func tuningFlagsAreRejectedWithScribeEngine() {
    for flags in [["--model", "x"], ["--vad"], ["--relaxed-thresholds"]] {
        #expect(throws: TranscribeArguments.ParseError.self) {
            try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "scribe"] + flags)
        }
    }
}

@Test func tuningFlagRejectionNamesAllThreeFlags() {
    do {
        _ = try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "scribe", "--vad"])
        Issue.record("--vad with --engine scribe should have been rejected")
    } catch TranscribeArguments.ParseError.message(let message) {
        #expect(message.contains("--model"))
        #expect(message.contains("--vad"))
        #expect(message.contains("--relaxed-thresholds"))
        #expect(message.contains("whisper"))
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func keytermsIsStillRejectedWithWhisperEngine() {
    #expect(throws: TranscribeArguments.ParseError.self) {
        try TranscribeArguments.parse(["transcribe", "audio.wav", "--keyterms", "термин"])
    }
}

@Test func tuningFlagsCoexistWithWhisperEngineExplicitly() throws {
    let parsed = try TranscribeArguments.parse([
        "transcribe", "audio.wav", "--engine", "whisper", "--model", "m", "--vad", "--relaxed-thresholds",
    ])
    #expect(parsed.engine == "whisper")
    #expect(parsed.model == "m")
    #expect(parsed.useVAD == true)
    #expect(parsed.relaxedThresholds == true)
}

// Parakeet added for the FluidAudio spike: it takes `--language` (like whisper, but validated
// against FluidAudio's own closed list) but none of the other four flags — no keyterm
// prompting like whisper, and no WhisperKit decoding knobs like scribe.

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

@Test func tuningFlagsAreRejectedWithParakeetEngine() {
    for flags in [["--model", "x"], ["--vad"], ["--relaxed-thresholds"]] {
        #expect(throws: TranscribeArguments.ParseError.self) {
            try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "parakeet"] + flags)
        }
    }
}

@Test func parakeetTuningFlagRejectionNamesTheEngine() {
    do {
        _ = try TranscribeArguments.parse(["transcribe", "audio.wav", "--engine", "parakeet", "--vad"])
        Issue.record("--vad with --engine parakeet should have been rejected")
    } catch TranscribeArguments.ParseError.message(let message) {
        #expect(message.contains("parakeet"))
        #expect(message.contains("whisper"))
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}
