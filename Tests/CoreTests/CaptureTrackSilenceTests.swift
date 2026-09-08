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

// Частота источника здесь — 48000, реальная частота системного микса, а не целевых 16 кГц.
// Это не случайное число: `note(silenceOf:)` обязан делить на частоту буфера, который ему дали,
// а не на константу цели. Возьми она 16000 — совпадающую с `MeetingAudioRecorder.sampleRate` —
// реализация, молча делящая на константу вместо частоты буфера, прошла бы тест не хуже верной.
@Test func silenceAccumulatesAcrossBuffers() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 48000, frames: 24000, value: 0))
    #expect(abs(track.silentSeconds - 0.5) < 0.001)
    track.note(silenceOf: buffer(rate: 48000, frames: 24000, value: 0))
    #expect(abs(track.silentSeconds - 1.0) < 0.001)
}

@Test func oneNonZeroSampleResetsSilence() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 16000, frames: 16000, value: 0))
    #expect(track.silentSeconds > 0)
    track.note(silenceOf: buffer(rate: 16000, frames: 160, value: 0.0001))
    #expect(track.silentSeconds == 0)
}

// Частота источника меняется посреди записи: Bluetooth-устройство, уходящее в узкую полосу,
// делает ровно это, а владелец пишет встречи на AirPods. Кадры, накопленные на прежней частоте,
// нельзя делить на новую — это перемасштабирует уже измеренное время, и десять секунд тишины
// прочтутся как три или как тридцать. Счёт начинается заново.
@Test func aRateChangeRestartsTheSilenceCountRatherThanRescalingIt() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    track.note(silenceOf: buffer(rate: 48000, frames: 48000, value: 0))
    #expect(abs(track.silentSeconds - 1.0) < 0.001)

    track.note(silenceOf: buffer(rate: 16000, frames: 1600, value: 0))

    // 0,1 секунды на новой частоте, а не 3,1 — что дало бы деление 49 600 накопленных кадров
    // на 16 000.
    #expect(abs(track.silentSeconds - 0.1) < 0.001)
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

// Перепривязка без запущенного потока — ошибка программиста, а не обстоятельство: перепривязывать
// нечего, и молчаливый успех тут соврал бы координатору, что микрофон подхвачен.
@Test func rebindingWithNoStreamRunningThrows() async {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = MeetingAudioRecorder(
        folder: folder, excludedBundleIDs: [], onFailureWhileRecording: { _ in }
    )
    await #expect(throws: MeetingCaptureError.self) {
        try await recorder.rebindMicrophone(to: "any-uid")
    }
}

@Test func silenceOfACaptureThatNeverStartedIsZero() async {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let recorder = MeetingAudioRecorder(
        folder: folder, excludedBundleIDs: [], onFailureWhileRecording: { _ in }
    )
    #expect(await recorder.microphoneSilentSeconds() == 0)
}
