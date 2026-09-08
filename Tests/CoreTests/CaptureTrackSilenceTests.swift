import AVFoundation
import Testing
@testable import Core

// Без устройства ввода ScreenCaptureKit отдаёт не пустоту, а полноскоростной цифровой ноль —
// проба 2 из спеки. Значит «звук не пришёл» нельзя определять по числу кадров: их приходит
// столько же, сколько при живом микрофоне. Немота определяется по значению.
private func buffer(rate: Double, frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
    return buffer
}

@Test func silenceAccumulatesAcrossBuffers() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 16000, frames: 8000, value: 0))
    #expect(abs(track.silentSeconds - 0.5) < 0.001)
    track.note(silenceOf: buffer(rate: 16000, frames: 8000, value: 0))
    #expect(abs(track.silentSeconds - 1.0) < 0.001)
}

@Test func oneNonZeroSampleResetsSilence() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 16000, frames: 16000, value: 0))
    #expect(track.silentSeconds > 0)
    track.note(silenceOf: buffer(rate: 16000, frames: 160, value: 0.0001))
    #expect(track.silentSeconds == 0)
}

// Уровень комнаты — не тишина. Настоящий микрофон в пустой комнате даёт −46…−57 dBFS, и
// порогом по громкости мы бы отрезали живую речь вместе с фоном.
@Test func aQuietRoomIsNotSilence() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 16000, frames: 16000, value: 0.002))
    #expect(track.silentSeconds == 0)
}

private func outputFormat() -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    )!
}
