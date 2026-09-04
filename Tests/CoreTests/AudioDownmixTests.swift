import AVFoundation
import Testing
@testable import Core

private func stereo(left: Float, right: Float, frames: AVAudioFrameCount = 64) -> AVAudioPCMBuffer {
    // The format ScreenCaptureKit delivers system audio in: 48 kHz, 32-bit float, one plane
    // per channel.
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for frame in 0..<Int(frames) {
        buffer.floatChannelData![0][frame] = left
        buffer.floatChannelData![1][frame] = right
    }
    return buffer
}

// The reason this code exists at all. `AVAudioConverter`, handed a stereo source and a mono
// target, keeps the first channel and drops the rest — with and without an explicit stereo
// channel layout, measured on this machine. A participant heard only in the right channel would
// vanish from the meeting, and the file would look perfectly normal.
@Test func contentOnlyInTheRightChannelSurvivesTheDownmix() throws {
    let mixed = try #require(AudioDownmix.mono(from: stereo(left: 0, right: 0.5)))
    #expect(mixed.format.channelCount == 1)
    #expect(mixed.frameLength == 64)
    #expect(abs(mixed.floatChannelData![0][0] - 0.25) < 0.0001)
}

@Test func bothChannelsAreAveragedRatherThanSummed() throws {
    // Averaging, not adding: two loud channels must not clip the mono track.
    let mixed = try #require(AudioDownmix.mono(from: stereo(left: 0.8, right: 0.8)))
    #expect(abs(mixed.floatChannelData![0][0] - 0.8) < 0.0001)
}

@Test func theSampleRateIsLeftAlone() throws {
    // Down-mixing is all this does. Dropping 48 kHz to 16 kHz by hand would alias exactly the
    // band where consonants and voices differ, so the resampling stays with AVAudioConverter.
    let mixed = try #require(AudioDownmix.mono(from: stereo(left: 1, right: -1)))
    #expect(mixed.format.sampleRate == 48000)
    #expect(mixed.floatChannelData![0][0] == 0)
}

@Test func aMonoBufferIsHandedBackUntouched() throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
    buffer.frameLength = 8
    buffer.floatChannelData![0][0] = 0.42
    let mixed = try #require(AudioDownmix.mono(from: buffer))
    #expect(mixed === buffer)
}

// A layout this cannot read must be reported, not guessed at: the caller turns nil into a named
// capture failure. Silently keeping the first channel is the bug this whole file prevents.
@Test func anInterleavedSourceIsRefusedRatherThanGuessed() {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
    buffer.frameLength = 8
    #expect(AudioDownmix.mono(from: buffer) == nil)
}

@Test func anIntegerSourceIsRefusedRatherThanGuessed() {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
    buffer.frameLength = 8
    #expect(AudioDownmix.mono(from: buffer) == nil)
}
