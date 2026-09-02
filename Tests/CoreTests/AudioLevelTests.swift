import AVFoundation
import Foundation
import Testing
@testable import Core

@Test func silenceIsZero() {
    #expect(AudioLevel.rms([0, 0, 0, 0]) == 0)
}

@Test func emptyBufferIsZero() {
    #expect(AudioLevel.rms([]) == 0)
}

@Test func constantAmplitudeIsThatAmplitude() {
    // Half of full scale, alternating sign: RMS equals the amplitude itself.
    let half = Int16(16384)
    #expect(abs(AudioLevel.rms([half, -half, half, -half]) - 0.5) < 0.001)
}

// The mapping is logarithmic on purpose: a linear RMS spends almost its whole range on the
// loudest sounds, so ordinary speech would show as a barely moving line.
@Test func fullScaleMapsToOne() {
    #expect(abs(AudioLevel.normalized(rms: 1.0) - 1.0) < 0.001)
}

@Test func silenceMapsToZero() {
    #expect(AudioLevel.normalized(rms: 0) == 0)
}

@Test func belowTheFloorMapsToZero() {
    // -60 dBFS is the floor; anything quieter is not drawn at all.
    #expect(AudioLevel.normalized(rms: 0.0005) == 0)
}

@Test func louderInputGivesLargerLevel() {
    #expect(AudioLevel.normalized(rms: 0.5) > AudioLevel.normalized(rms: 0.05))
}

// `normalized(buffer:)` is the path MicrophoneRecorder actually calls; these exercise it
// directly instead of only its shared helper, so the two can't silently drift apart.

@Test func bufferAtAKnownAmplitudeMatchesThatAmplitude() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    let channel = try #require(buffer.int16ChannelData)
    // Same half-scale, alternating-sign pattern as constantAmplitudeIsThatAmplitude: RMS is 0.5.
    let half = Int16(16384)
    channel[0][0] = half
    channel[0][1] = -half
    channel[0][2] = half
    channel[0][3] = -half

    let expected = AudioLevel.normalized(rms: 0.5)
    #expect(abs(AudioLevel.normalized(buffer: buffer) - expected) < 0.001)
}

@Test func zeroLengthBufferIsZero() throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 0

    #expect(AudioLevel.normalized(buffer: buffer) == 0)
}
