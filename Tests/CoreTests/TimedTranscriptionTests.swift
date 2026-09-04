import AVFoundation
import Foundation
import Testing
@testable import Core

private var fixtureURL: URL? {
    guard let path = ProcessInfo.processInfo.environment["NOHANDS_TIMED_FIXTURE"] else { return nil }
    return URL(fileURLWithPath: path)
}

// The only check in the project that needs both the model and a real long file. Skipped when
// the recording is missing: it is about something invisible in clean unit tests — that a long
// file's timestamps run continuously, rather than resetting at every thirty-second chunk.
@Test(.enabled(if: fixtureURL != nil))
func timedTranscriptionOfALongFileHasGlobalTimestamps() async throws {
    let url = try #require(fixtureURL)
    let transcriber = try await ParakeetTranscriber.load(language: "ru")
    let words = try await transcriber.transcribeTimed(audio: url)

    #expect(!words.isEmpty, "no words in the recording")

    // FluidAudio's chunks are thirty seconds long. A word starting later proves that timestamps
    // do not reset at the chunk boundary.
    let latest = words.map(\.start).max() ?? 0
    #expect(latest > 30, "every word fell inside the first 30 s — timestamps look chunk-local")

    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    #expect(latest <= duration + 1, "a word starts past the end of the file")

    for (previous, next) in zip(words, words.dropFirst()) {
        #expect(previous.start <= next.start, "words arrived out of order")
    }
}
