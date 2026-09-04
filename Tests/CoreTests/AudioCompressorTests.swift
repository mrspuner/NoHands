import AVFoundation
import Foundation
import Testing
@testable import Core

private func makeToneFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("compress-\(UUID().uuidString).wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    // `AVAudioFile(forWriting:settings:)` alone opens the file in the standard format
    // (deinterleaved Float32) no matter what `settings` says, and writing an Int16 buffer into it
    // traps inside AudioToolbox instead of throwing. The same crash was found on a real recording
    // and is documented on `RecordingChecks.openForWriting` — pass the format explicitly.
    let file = try AVAudioFile(
        forWriting: url, settings: format.settings,
        commonFormat: format.commonFormat, interleaved: format.isInterleaved
    )
    let frames = AVAudioFrameCount(16000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.int16ChannelData![0]
    for index in 0..<Int(frames) {
        let phase = Double(index) / 16000 * 440 * 2 * .pi
        channel[index] = Int16(sin(phase) * 8000)
    }
    try file.write(from: buffer)
    return url
}

@Test func compressionProducesAShorterFileOfTheSameLength() async throws {
    let source = try makeToneFile(seconds: 3)
    let destination = source.deletingPathExtension().appendingPathExtension("m4a")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
    }

    try await AudioCompressor.compress(source, to: destination, bitrate: 32000)

    #expect(FileManager.default.fileExists(atPath: destination.path))

    let sourceSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int
    let resultSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! Int
    #expect(resultSize < sourceSize / 2, "AAC at 32 kbit/s must be several times smaller than 16-bit WAV")

    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 3) < 0.2)
}

@Test func aFileWithoutAudioIsAnamedFailure() async throws {
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
    try Data("это не аудио".utf8).write(to: empty)
    let destination = empty.deletingPathExtension().appendingPathExtension("m4a")
    defer {
        try? FileManager.default.removeItem(at: empty)
        try? FileManager.default.removeItem(at: destination)
    }

    await #expect(throws: (any Error).self) {
        try await AudioCompressor.compress(empty, to: destination, bitrate: 32000)
    }
}
