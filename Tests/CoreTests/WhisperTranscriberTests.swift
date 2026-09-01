import Foundation
import Testing
@testable import Core

@Test func missingFileIsReportedBeforeModelIsTouched() {
    // Loading a 626 MB model to learn a path is wrong would be absurd,
    // so the check happens first and this test needs no model at all.
    let missing = URL(fileURLWithPath: "/tmp/nohands-does-not-exist.wav")
    #expect(!FileManager.default.fileExists(atPath: missing.path))

    #expect(throws: TranscriptionError.fileNotReadable(missing)) {
        try WhisperTranscriber.validateReadable(missing)
    }
}

@Test func readableFilePassesValidation() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-test-\(UUID().uuidString).wav")
    try Data([0x00]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    try WhisperTranscriber.validateReadable(url)
}
