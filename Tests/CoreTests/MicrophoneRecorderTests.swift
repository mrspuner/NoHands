import AVFoundation
import Foundation
import Testing
@testable import Core

@Test func recordThrowsWhenNoInputDeviceIsAvailable() async throws {
    // This machine currently has no default input device (see AudioInputDeviceTests), which
    // makes the failure path deterministic here rather than something to skip or fake.
    guard AudioInputDevice.current() == nil else {
        return
    }

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-record-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: RecordingError.noInputDevice) {
        try await MicrophoneRecorder().record(seconds: 1, to: url)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// The tap that counts frames runs on a real-time audio thread and can't be exercised without a
// live microphone. `RecordingChecks.validateCaptured` is the pure decision at the end of that
// count — kept separate precisely so this defect (a denied microphone permission produces a
// header-only WAV that record() reported as success) is testable without one.
@Test func zeroFramesIsReportedAsNoAudioCaptured() {
    #expect(throws: RecordingError.noAudioCaptured) {
        try RecordingChecks.validateCaptured(frameCount: 0)
    }
}

@Test func nonzeroFrameCountPassesValidation() throws {
    try RecordingChecks.validateCaptured(frameCount: 1)
}

// `removeIfOwned` is the other half of the fix: on any failure, a file this call created must
// go, but a file that already existed at that path before recording started must not.

@Test func fileCreatedByThisCallIsRemovedOnFailure() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-cleanup-test-\(UUID().uuidString).wav")
    try Data([0x00]).write(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))

    RecordingChecks.removeIfOwned(url, existedBefore: false)

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func preexistingFileIsLeftAloneOnFailure() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-cleanup-test-\(UUID().uuidString).wav")
    let original = Data([0x01, 0x02, 0x03])
    try original.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    RecordingChecks.removeIfOwned(url, existedBefore: true)

    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == original)
}

// Regression for the crash found on a real recording: `AVAudioFile(forWriting:settings:)`
// (no `commonFormat:`/`interleaved:`) opens the file for writing "using the standard format
// (deinterleaved floating point)" per Apple's header doc, regardless of `settings`. The tap
// converts into Int16 buffers and writes them straight to the file — a format that never
// matched `processingFormat`. `write(from:)` traps deep in AudioToolbox on the mismatch
// (`SIGTRAP` inside `-[AVAudioFile writeFromBuffer:error:]`), not a catchable Swift error, so
// nothing before this fix could report or recover from it. `openForWriting` pins
// `processingFormat` to the same format the tap already builds buffers in.

@Test func openedFileAcceptsBuffersInTheTargetFormat() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-format-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let targetFormat = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    ))

    let file = try RecordingChecks.openForWriting(url, targetFormat: targetFormat)

    #expect(file.processingFormat.commonFormat == .pcmFormatInt16)
    #expect(file.processingFormat.sampleRate == 16000)
    #expect(file.processingFormat.channelCount == 1)
}

@Test func writingABufferInTheTargetFormatSucceeds() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-format-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let targetFormat = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    ))
    let file = try RecordingChecks.openForWriting(url, targetFormat: targetFormat)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 10))
    buffer.frameLength = 10

    try file.write(from: buffer)
}
