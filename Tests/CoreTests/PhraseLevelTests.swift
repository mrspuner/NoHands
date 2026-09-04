import AVFoundation
import Foundation
import Testing
@testable import Core

/// Writes a 16 kHz mono Int16 WAV where the first half is quiet and the second half is loud.
private func makeTwoHalvesFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phrase-level-\(UUID().uuidString).wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    // `AVAudioFile(forWriting:settings:)` alone opens for writing in the standard format
    // (deinterleaved Float32) regardless of `settings`, per Apple's doc comment on that
    // initializer. Writing an Int16 buffer into a Float32-expecting file traps deep inside
    // AudioToolbox (`SIGTRAP`, uncatchable) rather than throwing — the same crash documented on
    // `RecordingChecks.openForWriting` in `MicrophoneRecorder.swift`. Passing `commonFormat:`/
    // `interleaved:` explicitly pins `processingFormat` to match the Int16 buffer this fixture
    // writes.
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
    let frames = AVAudioFrameCount(16000)  // one second
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.int16ChannelData![0]
    for index in 0..<Int(frames) {
        // First half: -60 dBFS. Second half: around -6 dBFS. A square wave, so RMS equals amplitude.
        let amplitude: Int16 = index < 8000 ? 33 : 16384
        channel[index] = index % 2 == 0 ? amplitude : -amplitude
    }
    try file.write(from: buffer)
    return url
}

@Test func theLoudHalfMeasuresLoud() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.5, to: 1.0)
    #expect(level > -8 && level < -4)
}

@Test func theQuietHalfMeasuresQuiet() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.0, to: 0.5)
    #expect(level < -50)
}

// The loudest window, not the average: a span that is quiet almost everywhere but has one loud
// piece counts as loud.
@Test func oneLoudWindowMakesTheWholeSpanLoud() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.0, to: 1.0)
    #expect(level > -8)
}

@Test func anEmptySpanIsSilence() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try PhraseLevel.peakDBFS(of: url, from: 0.5, to: 0.5) == -Float.infinity)
}

@Test func durationOfTheFixtureIsOneSecond() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(abs(try AudioDuration.seconds(of: url) - 1.0) < 0.01)
}

@Test func gateKeepsLoudUtterancesAndDropsQuietOnes() throws {
    let loud = Utterance(speaker: .me, start: 0, end: 1, text: "своя речь")
    let quiet = Utterance(speaker: .me, start: 2, end: 3, text: "комната")
    // No `try`: `passing` only rethrows, and this closure does not throw. The queue's call
    // site does need one, because measuring a real file can fail.
    let kept = PhraseLevel.passing([loud, quiet], thresholdDBFS: -30) { utterance in
        utterance.start == 0 ? -6 : -45
    }
    #expect(kept.map(\.text) == ["своя речь"])
}

// A phrase is dropped whole, not word by word: "... yeah ... got it ..." can neither be read nor
// used to tune the threshold.
@Test func gateKeepsAnUtteranceWhole() throws {
    let utterance = Utterance(speaker: .me, start: 0, end: 5, text: "длинная своя реплика целиком")
    let kept = PhraseLevel.passing([utterance], thresholdDBFS: -30) { _ in -10 }
    #expect(kept == [utterance])
}
