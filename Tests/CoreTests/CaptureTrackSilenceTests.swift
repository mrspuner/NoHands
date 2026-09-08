import AVFoundation
import ScreenCaptureKit
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

// «Дорожка пустая» и «дорожка замолчала под конец» — разные утверждения, и счётчик тишины
// различить их не может: он по построению меряет непрерывный ноль в конце. Дорожка помнит сам
// факт, что когда-то звучала, и помнит его до конца записи — иначе часовая запись с молчанием в
// хвосте объявлялась бы пустой.
@Test func aTrackRemembersThatItOnceHeardSomething() {
    let track = CaptureTrack(name: "microphone", url: URL(fileURLWithPath: "/dev/null"), format: outputFormat())
    #expect(!track.sawAudio)

    track.note(silenceOf: buffer(rate: 16000, frames: 160, value: 0))
    #expect(!track.sawAudio)

    track.note(silenceOf: buffer(rate: 16000, frames: 160, value: 0.002))
    #expect(track.sawAudio)

    track.note(silenceOf: buffer(rate: 16000, frames: 16000, value: 0))
    #expect(track.sawAudio)
    #expect(track.silentSeconds > 0)

    // Перепривязка обнуляет счётчик тишины — она про новую привязку. Про то, что дорожка уже
    // звучала, она ничего не отменяет: это факт обо всей записи.
    track.resetSilence()
    #expect(track.sawAudio)
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

// `SCStreamConfiguration` — обычный `NSObject` без документированного `NSCopying`, и нигде не
// сказано, держит ли поток сам объект или его снимок. Отдать `updateConfiguration` тот самый
// экземпляр, что уже у потока, значит поменять поле до вызова и, возможно, не поменять ничего:
// отказ молчаливый и выглядит ровно как та поломка, которую эта ветка чинит. Проба, доказавшая,
// что перепривязка работает, строила конфигурацию заново — эта форма и закрепляется.
@Test func everyConfigurationIsABrandNewObjectCarryingTheWholeSetup() {
    let atStart = MeetingAudioRecorder.makeConfiguration(microphoneDeviceUID: nil)
    let forRebind = MeetingAudioRecorder.makeConfiguration(microphoneDeviceUID: "F0-D3:input")

    #expect(atStart !== forRebind)
    #expect(atStart.microphoneCaptureDeviceID == nil)
    #expect(forRebind.microphoneCaptureDeviceID == "F0-D3:input")
    // Перепривязка обязана нести всю настройку, а не одно поле: конфигурация, потерявшая частоту,
    // исключение своих звуков или интервал кадров, тихо переписала бы их значениями по умолчанию.
    for configuration in [atStart, forRebind] {
        #expect(configuration.capturesAudio)
        #expect(configuration.captureMicrophone)
        #expect(configuration.excludesCurrentProcessAudio)
        #expect(configuration.sampleRate == 48000)
        #expect(configuration.channelCount == 2)
        #expect(configuration.width == 2)
        #expect(configuration.height == 2)
        #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 1))
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
