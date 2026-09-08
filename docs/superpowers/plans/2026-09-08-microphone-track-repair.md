# Починка микрофонной дорожки созвона — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дорожка микрофона перестаёт молча гибнуть на интерливленном буфере, немота называется на первой секунде, а появившееся посреди встречи устройство подхватывается само.

**Architecture:** Три независимых слоя. В `Core/Audio` чинится сведение каналов и заводится счётчик подряд идущей цифровой тишины. `MeetingCapture` получает два новых вопроса — «сколько секунд дорожка немая» и «перепривяжись на этот uid», — так что живой `SCStream` в тестах по-прежнему не нужен. `MeetingCoordinator` в уже существующем ежесекундном опросе поднимает предупреждение на панель и делает перепривязку.

**Tech Stack:** Swift 6.2, macOS 15, ScreenCaptureKit, AVFoundation, CoreAudio, swift-testing.

**Spec:** `docs/superpowers/specs/2026-09-08-microphone-track-repair-design.md`

## Global Constraints

- Общение, документация и коммиты — по-русски. Идентификаторы, комментарии в коде и `errorDescription` — по-английски. Текст, который видит владелец на панели, — по-русски; он живёт в `Features/Meetings`, рядом с `MeetingNotice`, а не в `Error`.
- Новых зависимостей не добавлять.
- Ничего из содержимого дорожек не логировать. Счётчики и уровни — числа, они не пишутся ни в какой файл, кроме `meeting.json`.
- Тесты: `swift test`. Каждая задача заканчивается зелёным прогоном всего набора, не только своих тестов.
- Порог немоты — `10` секунд подряд ровного нуля. Потолок перепривязок — `3` за запись, не чаще раза в `10` секунд. Значения именованные, не литералы по коду.
- Цифровая тишина — это ровно `0.0`, а не «тихо». Никаких dBFS-порогов в этой работе: настоящий микрофон в тишине комнаты даёт −46…−57 dBFS, и порогом по громкости мы бы отрезали живую речь.
- Перед каждым коммитом — `swift build 2>&1 | grep -c warning:` не должен вырасти относительно начала задачи.

---

### Task 1: Сведение интерливленного буфера

**Files:**
- Modify: `Core/Audio/MeetingAudioRecorder.swift` — `enum AudioDownmix`
- Test: `Tests/CoreTests/AudioDownmixTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces: `AudioDownmix.mono(from: AVAudioPCMBuffer) -> AVAudioPCMBuffer?` — прежняя сигнатура, новое поведение: интерливленный float32 усредняется, а не отвергается.

- [ ] **Step 1: Переписать падающий тест**

В `Tests/CoreTests/AudioDownmixTests.swift` заменить тест `anInterleavedSourceIsRefusedRatherThanGuessed` целиком на:

```swift
// Микрофонный выход SCStream интерливленный всегда — проба 4 из спеки. Раскладка читается
// ровно так же, просто шаг между сэмплами одного кадра равен числу каналов, а не единице.
// Отказ на этом месте стоил живой встречи: дорожка умирала на первом буфере.
@Test func anInterleavedStereoSourceIsAveraged() throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
    buffer.frameLength = 4
    let samples = try #require(buffer.floatChannelData)
    for frame in 0..<4 {
        samples[0][frame * 2] = 0
        samples[0][frame * 2 + 1] = 0.5
    }

    let mixed = try #require(AudioDownmix.mono(from: buffer))

    #expect(mixed.format.channelCount == 1)
    #expect(mixed.frameLength == 4)
    let output = try #require(mixed.floatChannelData)
    for frame in 0..<4 {
        #expect(abs(output[0][frame] - 0.25) < 0.0001)
    }
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter anInterleavedStereoSourceIsAveraged`
Expected: FAIL — `AudioDownmix.mono` возвращает `nil`, `#require` роняет тест на «Expectation failed: expected non-nil».

- [ ] **Step 3: Починить `AudioDownmix.mono`**

В `Core/Audio/MeetingAudioRecorder.swift` заменить тело `static func mono(from:)` на:

```swift
    static func mono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1 else { return buffer }
        // ScreenCaptureKit delivers 32-bit float on both tracks and lays them out differently:
        // the system mix arrives deinterleaved, one plane per channel, and the microphone
        // arrives interleaved, every channel in one plane. Both are readable — what differs is
        // the stride from one frame to the next, not whether the samples can be found — so both
        // are averaged here. Refusing the interleaved one cost a whole meeting's own track: see
        // the decision of 2026-09-08.
        guard let planes = buffer.floatChannelData else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mixed = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(buffer.frameLength, 1)
        ), let output = mixed.floatChannelData else {
            return nil
        }
        mixed.frameLength = buffer.frameLength
        let scale = 1 / Float(channels)
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? planes[0][frame * channels + channel] : planes[channel][frame]
            }
            output[0][frame] = sum * scale
        }
        return mixed
    }
```

Обновить doc-комментарий у `mono` — строка про «`nil`, когда сэмплы разложены так, что это не прочитать» остаётся верной, но теперь касается только не-float форматов.

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter AudioDownmix`
Expected: PASS, включая `anIntegerSourceIsRefusedRatherThanGuessed` — Int16 по-прежнему отвергается, потому что `floatChannelData` у него `nil`.

- [ ] **Step 5: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений.

- [ ] **Step 6: Коммит**

```bash
git add Core/Audio/MeetingAudioRecorder.swift Tests/CoreTests/AudioDownmixTests.swift
git commit -m "Сведение каналов принимает интерливленный float32

Микрофонный выход SCStream интерливленный всегда, и гвард на это убивал
дорожку на первом же буфере. Отказ остаётся для не-float форматов."
```

---

### Task 2: `AudioInputDevice` отдаёт uid

**Files:**
- Modify: `Core/Audio/AudioInputDevice.swift`
- Test: `Tests/CoreTests/AudioInputDeviceTests.swift`
- Modify: `Tests/MeetingsTests/MeetingCoordinatorTests.swift:556,568,580`

**Interfaces:**
- Consumes: ничего
- Produces: `AudioInputDevice.uid: String` и `init(name:uid:sampleRate:channelCount:)`. Задача 6 передаёт `uid` в перепривязку.

- [ ] **Step 1: Написать падающий тест**

Дописать в `Tests/CoreTests/AudioInputDeviceTests.swift`:

```swift
// The uid, not the name, is what ScreenCaptureKit binds the microphone to — and two AirPods of
// the same model carry the same name.
@Test func aDeviceCarriesItsCoreAudioUID() {
    let device = AudioInputDevice(
        name: "AirPods", uid: "F0-D3-1F-6F-CA-96:input", sampleRate: 24000, channelCount: 1
    )
    #expect(device.uid == "F0-D3-1F-6F-CA-96:input")
}
```

- [ ] **Step 2: Прогнать и убедиться, что не собирается**

Run: `swift test --filter AudioInputDevice`
Expected: FAIL — компилятор не знает параметра `uid:`.

- [ ] **Step 3: Добавить свойство и чтение**

В `Core/Audio/AudioInputDevice.swift`:

добавить `public let uid: String` рядом с `name`;

расширить инициализатор до `public init(name: String, uid: String, sampleRate: Double, channelCount: UInt32)`, присвоив `self.uid = uid`;

в `current()` прочитать uid и вернуть его:

```swift
    public static func current() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID(),
              let name = deviceName(deviceID),
              let uid = deviceUID(deviceID),
              let format = streamFormat(deviceID)
        else {
            return nil
        }
        return AudioInputDevice(
            name: name,
            uid: uid,
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame
        )
    }

    /// What ScreenCaptureKit binds a microphone to — `kAudioDevicePropertyDeviceUID`, the same
    /// string `SCStreamConfiguration.microphoneCaptureDeviceID` takes.
    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { return nil }
        return uid as String
    }
```

- [ ] **Step 4: Починить остальные места вызова**

В `Tests/CoreTests/AudioInputDeviceTests.swift` строки 23, 28, 35 и в `Tests/MeetingsTests/MeetingCoordinatorTests.swift` строки 556, 568, 580 добавить `uid:` вторым аргументом. Значения произвольные, но осмысленные: `uid: "test-airpods"`, `uid: "test-usb"`, `uid: "test-threshold"`.

- [ ] **Step 5: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений.

- [ ] **Step 6: Коммит**

```bash
git add Core/Audio/AudioInputDevice.swift Tests/CoreTests/AudioInputDeviceTests.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Устройство ввода отдаёт свой uid

Перепривязка микрофона в SCStream идёт по uid, а не по имени."
```

---

### Task 3: `CaptureTrack` считает подряд идущую цифровую тишину

**Files:**
- Modify: `Core/Audio/MeetingAudioRecorder.swift` — `final class CaptureTrack`, `final class TrackWriter`, `struct Outcome`
- Test: `Tests/CoreTests/CaptureTrackSilenceTests.swift` (создать)

**Interfaces:**
- Consumes: `AudioDownmix.mono` из задачи 1
- Produces:
  - `CaptureTrack.silentSeconds: TimeInterval` — сколько секунд подряд дорожка отдаёт ровный ноль, `0` пока идёт звук
  - `TrackWriter.microphoneSilentSeconds() -> TimeInterval`
  - `MeetingAudioRecorder.Outcome.microphoneSilentSeconds: TimeInterval` — новое поле, последнее в списке параметров `init`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CoreTests/CaptureTrackSilenceTests.swift`:

```swift
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
```

- [ ] **Step 2: Прогнать и убедиться, что не собирается**

Run: `swift test --filter CaptureTrackSilence`
Expected: FAIL — нет метода `note(silenceOf:)` и свойства `silentSeconds`.

- [ ] **Step 3: Добавить счётчик в `CaptureTrack`**

В `Core/Audio/MeetingAudioRecorder.swift`, в `final class CaptureTrack`, рядом с `private(set) var frames`:

```swift
    /// Frames of unbroken digital silence — samples that are exactly zero — at the end of what
    /// this track has been handed.
    ///
    /// Exactly zero, not "quiet": with no input device ScreenCaptureKit hands over a full-rate
    /// stream of zeroes, while a real microphone in an empty room still delivers −46…−57 dBFS.
    /// A loudness threshold here would cut off the owner's own quiet speech; this one only ever
    /// fires on a track nobody is recording into.
    private var silentFrames: AVAudioFrameCount = 0
    private var silentRate: Double = MeetingAudioRecorder.sampleRate

    var silentSeconds: TimeInterval {
        silentRate > 0 ? TimeInterval(silentFrames) / silentRate : 0
    }

    /// Internal rather than private so the tests can drive the counter without a stream: the
    /// buffer this measures is the down-mixed one, and building it by hand is the whole test.
    func note(silenceOf buffer: AVAudioPCMBuffer) {
        silentRate = buffer.format.sampleRate
        // A format this cannot read is not judged: reporting it as silence would raise a warning
        // about a track that may well be recording.
        guard let planes = buffer.floatChannelData else {
            silentFrames = 0
            return
        }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                let sample = interleaved
                    ? planes[0][frame * channels + channel]
                    : planes[channel][frame]
                if sample != 0 {
                    silentFrames = 0
                    return
                }
            }
        }
        silentFrames += buffer.frameLength
    }
```

- [ ] **Step 4: Вызвать счётчик из `append`**

В `CaptureTrack.append`, сразу после строки `guard let mono = AudioDownmix.mono(from: source) else { … }` и до `guard let converted = resampled(mono)`, вставить:

```swift
        note(silenceOf: mono)
```

- [ ] **Step 5: Прогнать тесты задачи**

Run: `swift test --filter CaptureTrackSilence`
Expected: PASS, три теста.

- [ ] **Step 6: Провести немоту в `Outcome`**

В `struct Outcome` добавить поле последним:

```swift
        /// How long the microphone track had been delivering nothing but digital zeroes when the
        /// recording was handed over. Zero while it was delivering audio.
        public let microphoneSilentSeconds: TimeInterval
```

и одноимённый параметр последним в `public init`.

В `TrackWriter` добавить:

```swift
    func microphoneSilentSeconds() -> TimeInterval {
        queue.sync { microphone.silentSeconds }
    }
```

и передать `microphoneSilentSeconds: microphone.silentSeconds` в `Outcome` внутри `finish()`.

- [ ] **Step 7: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений. Если какой-то тест строит `Outcome` руками — дописать в него новый параметр.

- [ ] **Step 8: Коммит**

```bash
git add Core/Audio/MeetingAudioRecorder.swift Tests/CoreTests/CaptureTrackSilenceTests.swift
git commit -m "Дорожка считает подряд идущую цифровую тишину

Без устройства ввода SCK отдаёт полноскоростной ноль, поэтому немоту
нельзя ловить по числу кадров — только по значению сэмплов."
```

---

### Task 4: Захват умеет ответить про немоту и перепривязаться

**Files:**
- Modify: `Core/Audio/MeetingAudioRecorder.swift` — `public actor MeetingAudioRecorder`
- Modify: `Features/Meetings/MeetingCapture.swift`
- Modify: `Tests/MeetingsTests/MeetingCoordinatorTests.swift` — `private final class FakeCapture`

**Interfaces:**
- Consumes: `TrackWriter.microphoneSilentSeconds()` из задачи 3
- Produces:
  - `MeetingCapture.microphoneSilentSeconds() async -> TimeInterval`
  - `MeetingCapture.rebindMicrophone(to deviceUID: String) async throws`
  - `FakeCapture.silentSeconds: TimeInterval` и `FakeCapture.rebinds: [String]` — задачи 5 и 6 читают их в тестах

- [ ] **Step 1: Расширить протокол**

В `Features/Meetings/MeetingCapture.swift` добавить в `public protocol MeetingCapture` два метода и объяснить, почему они здесь:

```swift
    /// How long the microphone track has been delivering nothing but digital zeroes.
    ///
    /// Asked once a second while a meeting records. Zero means audio is arriving — including
    /// audio nobody would call loud, which is the point: a real microphone in an empty room is
    /// never exactly zero, and only a track bound to nothing ever is.
    func microphoneSilentSeconds() async -> TimeInterval

    /// Points the microphone output at a device by its CoreAudio UID, on the running stream.
    ///
    /// ScreenCaptureKit binds the microphone once, when the stream starts, and does not follow a
    /// device that appears later — measured, see the decision of 2026-09-08. Without this the
    /// warning on the panel would be sympathy rather than a repair.
    func rebindMicrophone(to deviceUID: String) async throws
```

- [ ] **Step 2: Написать падающий тест на настоящий рекордер**

Дописать в `Tests/CoreTests/CaptureTrackSilenceTests.swift`:

```swift
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
```

- [ ] **Step 3: Прогнать и убедиться, что не собирается**

Run: `swift test --filter CaptureTrackSilence`
Expected: FAIL — у `MeetingAudioRecorder` нет этих методов.

- [ ] **Step 4: Реализовать в `MeetingAudioRecorder`**

Добавить хранение конфигурации: в теле актора, рядом с `private var writer: TrackWriter?`:

```swift
    /// The configuration the stream was started with, kept so a rebind can hand `updateConfiguration`
    /// a whole configuration with one field changed rather than a fresh one that would also
    /// silently reset the sample rate, the exclusions and the frame interval.
    private var configuration: SCStreamConfiguration?
```

В `start()`, сразу после `configuration.minimumFrameInterval = …`, ничего не менять; в самом конце `start()`, рядом с `self.stream = stream`, добавить `self.configuration = configuration`.

В `stop()`, рядом с `self.writer = nil`, добавить `self.configuration = nil`.

Добавить два метода актора:

```swift
    public func microphoneSilentSeconds() -> TimeInterval {
        writer?.microphoneSilentSeconds() ?? 0
    }

    /// - Throws: when there is no capture to rebind. That is a programmer error rather than a
    ///   circumstance, and a silent success would tell the coordinator the microphone was picked
    ///   up when nothing happened at all.
    public func rebindMicrophone(to deviceUID: String) async throws {
        guard let stream, let configuration else {
            throw MeetingCaptureError.streamFailed("rebind called with no capture running")
        }
        configuration.microphoneCaptureDeviceID = deviceUID
        try await stream.updateConfiguration(configuration)
        // The next ten seconds are measured from here: the counter is about the binding that
        // exists now, and leaving the old total behind would ask for a second rebind at once.
        writer?.resetMicrophoneSilence()
    }
```

В `TrackWriter` добавить:

```swift
    func resetMicrophoneSilence() {
        queue.sync { microphone.resetSilence() }
    }
```

В `CaptureTrack` добавить:

```swift
    func resetSilence() {
        silentFrames = 0
    }
```

- [ ] **Step 5: Прогнать тесты задачи**

Run: `swift test --filter CaptureTrackSilence`
Expected: PASS, пять тестов.

- [ ] **Step 6: Научить `FakeCapture` тому же**

В `Tests/MeetingsTests/MeetingCoordinatorTests.swift`, в `private final class FakeCapture`, добавить:

```swift
    /// What the next `microphoneSilentSeconds()` answers. The tests set it directly: this fake
    /// has no audio to be silent about.
    var silentSeconds: TimeInterval = 0
    /// Every uid the coordinator asked to rebind to, in order.
    private(set) var rebinds: [String] = []
    /// Set to make a rebind fail the way a stream that died would.
    var rebindError: Error?

    func microphoneSilentSeconds() async -> TimeInterval { silentSeconds }

    func rebindMicrophone(to deviceUID: String) async throws {
        if let rebindError { throw rebindError }
        rebinds.append(deviceUID)
        // The real recorder restarts the count from the new binding; a fake that did not would
        // let one test's rebind look like three.
        silentSeconds = 0
    }
```

- [ ] **Step 7: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений.

- [ ] **Step 8: Коммит**

```bash
git add Core/Audio/MeetingAudioRecorder.swift Features/Meetings/MeetingCapture.swift Tests/CoreTests/CaptureTrackSilenceTests.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Захват отвечает про немоту и умеет перепривязать микрофон

SCStream привязывает микрофон один раз на старте и за появившимся
устройством не идёт, поэтому перепривязка делается явно."
```

---

### Task 5: Панель называет немой микрофон

**Files:**
- Modify: `Features/Meetings/MeetingCoordinator.swift`
- Modify: `App/PanelModel.swift`
- Modify: `App/PanelWindow.swift`
- Modify: `App/PanelView.swift`
- Modify: `App/AppDelegate.swift:188`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MeetingCapture.microphoneSilentSeconds()` из задачи 4
- Produces: `MeetingCoordinator.init(onMicrophoneSilent: @escaping (Bool) -> Void, …)` — новый параметр рядом с `onNarrowbandInput`; задача 6 переиспользует ту же проверку немоты

- [ ] **Step 1: Написать падающий тест**

Дописать в `Tests/MeetingsTests/MeetingCoordinatorTests.swift`, рядом с тестами про узкую полосу (около строки 556):

```swift
// Приложение знало о немой дорожке на первой секунде и молчало полтора часа — ровно то, что
// стоило владельцу его собственного голоса на встрече 7 сентября.
@Test @MainActor func aSilentMicrophoneIsNamedWhileTheMeetingIsStillRecording() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [])

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true])
}

@Test @MainActor func aMicrophoneThatStartsSpeakingClearsTheWarning() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 0
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true, false])
}

// Девять секунд — это не немота, а пауза между буферами плюс запас.
@Test @MainActor func aShortGapIsNotCalledSilence() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 9
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [])
}
```

В `Harness` добавить — по образцу уже существующего `narrowband`, одна запись на каждое
изменение, а не текущее значение:

```swift
    /// Одна запись на каждый раз, когда координатор сказал про немой микрофон. Массив, а не
    /// флаг, по той же причине, что и `narrowband`: проверяется не только что он сказал, но и
    /// сколько раз — надпись не должна мигать раз в секунду весь час.
    private(set) var microphoneSilent: [Bool] = []
```

и в конструкторе координатора, следом за `onNarrowbandInput`:

```swift
            onMicrophoneSilent: { [weak self] in self?.microphoneSilent.append($0) },
```

Отдельного помощника для старта встречи не заводить: `processes = [telemost]` плюс `poll` плюс
`settle` — это ровно то, чем начинаются соседние тесты про узкую полосу, и повторять их форму
дешевле, чем вводить свою.

- [ ] **Step 2: Прогнать и убедиться, что не собирается**

Run: `swift test --filter aSilentMicrophoneIsNamed`
Expected: FAIL — у `Harness` нет `microphoneSilent`, у координатора нет параметра `onMicrophoneSilent`.

- [ ] **Step 3: Завести проверку в координаторе**

В `Features/Meetings/MeetingCoordinator.swift`:

рядом с `private let onNarrowbandInput: (Double?) -> Void` добавить

```swift
    /// Whether the microphone track is delivering nothing but digital zeroes right now.
    ///
    /// Separate from `onNarrowbandInput` rather than folded into it: a narrow band is a warning
    /// about quality and a silent track is a warning about loss, and the two are true at
    /// different times — AirPods produce the first without the second.
    private let onMicrophoneSilent: (Bool) -> Void
```
с параметром в `init` сразу после `onNarrowbandInput` и присвоением;

рядом с константами класса:

```swift
    /// How long the microphone track must be exactly zero before it is called silent. Long
    /// enough to outlast any gap between buffers, short enough that the owner can still fix it.
    static let microphoneSilenceThreshold: TimeInterval = 10
```

добавить состояние и проверку:

```swift
    /// The task asking the capture how quiet the microphone is. One at a time: the poll fires
    /// once a second and the question crosses an actor boundary, so a second one would queue
    /// behind the first and answer about a moment that has passed.
    private var microphoneCheck: Task<Void, Never>?
    private var microphoneSilent = false

    private func checkMicrophone() {
        guard let capture, liveCaptureID != nil, microphoneCheck == nil else { return }
        microphoneCheck = Task { @MainActor [weak self] in
            let silent = await capture.microphoneSilentSeconds() >= Self.microphoneSilenceThreshold
            guard let self else { return }
            if silent != microphoneSilent {
                microphoneSilent = silent
                onMicrophoneSilent(silent)
            }
            microphoneCheck = nil
        }
    }

```

в уже существующий `settle()` дописать `await microphoneCheck?.value` последней строкой — это
тот же шов, которым тесты ждут `captureTask`, `closing` и `housekeeping`, и заводить второй
незачем;

в `poll(now:)` добавить `checkMicrophone()` перед `apply(.tick(now))` в основной ветке;

в `stopCapture(at:reason:)` сбросить состояние: `microphoneCheck?.cancel()`, `microphoneCheck = nil`, `microphoneSilent = false`, `onMicrophoneSilent(false)`.

- [ ] **Step 4: Прогнать тесты задачи**

Run: `swift test --filter Microphone`
Expected: PASS.

- [ ] **Step 5: Провести до панели**

`App/PanelModel.swift` — рядом с `meetingNarrowbandHz`:

```swift
    /// The microphone track of the meeting being recorded is delivering nothing but zeroes.
    /// Kept apart from `meetingNarrowbandHz` for the same reason the coordinator keeps the two
    /// callbacks apart: they are different warnings and they are true at different times.
    @Published var meetingMicrophoneSilent = false
```

`App/PanelWindow.swift` — рядом с `setMeetingInputWarning(hz:)`:

```swift
    func setMeetingMicrophoneSilent(_ silent: Bool) {
        model.meetingMicrophoneSilent = silent
    }
```
и в `hideMeeting(after:)`, рядом с `self?.model.meetingNarrowbandHz = nil`, добавить `self?.model.meetingMicrophoneSilent = false`.

`App/PanelView.swift` — рядом с `private var narrowband`:

```swift
    /// Louder than the narrow-band warning, and deliberately: a narrow band costs quality, a
    /// silent track costs the recording. It stays up for the length of the recording — the owner
    /// is the only one who can plug a microphone in while that still saves something.
    @ViewBuilder private var microphoneSilent: some View {
        if model.meetingMicrophoneSilent {
            Text("микрофон молчит")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
```
и вставить `microphoneSilent` сразу после `narrowband` в `strip(since:)` и в `prompt(…)` под тем же `warnAboutTheBand`.

`App/AppDelegate.swift:188` — рядом с `onNarrowbandInput:` добавить

```swift
            onMicrophoneSilent: { [panel] silent in panel.setMeetingMicrophoneSilent(silent) },
```

- [ ] **Step 6: Прогнать весь набор и собрать приложение**

Run: `swift test 2>&1 | tail -3` и `./Scripts/make-app.sh`
Expected: ноль падений, сборка проходит.

- [ ] **Step 7: Коммит**

```bash
git add Features/Meetings/MeetingCoordinator.swift App/PanelModel.swift App/PanelWindow.swift App/PanelView.swift App/AppDelegate.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Панель называет немой микрофон на первой секунде

Приложение знало о пустой дорожке сразу и молчало полтора часа."
```

---

### Task 6: Координатор перепривязывает микрофон

**Files:**
- Modify: `Features/Meetings/MeetingCoordinator.swift`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MeetingCapture.rebindMicrophone(to:)` из задачи 4, `AudioInputDevice.uid` из задачи 2, `checkMicrophone()` из задачи 5
- Produces: ничего для последующих задач

- [ ] **Step 1: Написать падающий тест**

```swift
private let airpods = AudioInputDevice(
    name: "AirPods", uid: "F0-D3:input", sampleRate: 24000, channelCount: 1
)

// ScreenCaptureKit привязывает микрофон один раз, на старте потока: устройство, подключённое
// посреди встречи, он сам не подхватывает — измерено, проба 3 из спеки.
@Test @MainActor func aDeviceThatAppearsMidMeetingIsBoundExplicitly() async throws {
    let harness = try Harness()
    harness.inputDevice = nil
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.inputDevice = airpods
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()

    #expect(harness.captures[0].rebinds == ["F0-D3:input"])
}

// Немая дорожка без устройства — перепривязывать не на что.
@Test @MainActor func silenceWithNoDeviceDoesNotRebind() async throws {
    let harness = try Harness()
    harness.inputDevice = nil
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()

    #expect(harness.captures[0].rebinds.isEmpty)
}

// Устройство может молчать по своей причине — выключенный в железе микрофон, эксклюзивно
// занятое приложение. Тогда попытки не помогают, а updateConfiguration дёргает поток, которым
// пишется единственная уцелевшая дорожка собеседников.
@Test @MainActor func rebindingGivesUpAfterThreeAttempts() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    for attempt in 1...8 {
        harness.captures[0].silentSeconds = 10
        harness.coordinator.poll(now: noon.addingTimeInterval(TimeInterval(attempt) * 11))
        await harness.coordinator.settle()
    }

    #expect(harness.captures[0].rebinds.count == 3)
}

// Опрос идёт раз в секунду, но перепривязка — нет: новой привязке нужно время, чтобы отдать
// первый буфер, иначе тишина последней секунды прочтётся как отказ и вызовет вторую попытку.
@Test @MainActor func rebindingWaitsBetweenAttempts() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    for second in 1...5 {
        harness.captures[0].silentSeconds = 10
        harness.coordinator.poll(now: noon.addingTimeInterval(TimeInterval(second)))
        await harness.coordinator.settle()
    }

    #expect(harness.captures[0].rebinds.count == 1)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter Rebind`
Expected: FAIL — `rebinds` пуст, координатор ничего не перепривязывает.

- [ ] **Step 3: Реализовать перепривязку**

В `MeetingCoordinator` добавить константы и состояние:

```swift
    /// Not more often than this, and not more than `rebindLimit` times per recording.
    static let rebindCooldown: TimeInterval = 10
    static let rebindLimit = 3

    private var rebindAttempts = 0
    private var lastRebindAt: Date?
```

Переписать `checkMicrophone()` так, чтобы он принимал время и после подтверждения немоты пробовал перепривязку:

```swift
    private func checkMicrophone(now: Date) {
        guard let capture, liveCaptureID != nil, microphoneCheck == nil else { return }
        let device = readInputDevice()
        microphoneCheck = Task { @MainActor [weak self] in
            let silent = await capture.microphoneSilentSeconds() >= Self.microphoneSilenceThreshold
            guard let self else { return }
            if silent != microphoneSilent {
                microphoneSilent = silent
                onMicrophoneSilent(silent)
            }
            if silent, let device, mayRebind(now: now) {
                rebindAttempts += 1
                lastRebindAt = now
                // A rebind that throws is not reported: the stream dying has its own channel,
                // and the track is already known to be silent — the panel is saying so.
                try? await capture.rebindMicrophone(to: device.uid)
            }
            microphoneCheck = nil
        }
    }

    private func mayRebind(now: Date) -> Bool {
        guard rebindAttempts < Self.rebindLimit else { return false }
        guard let lastRebindAt else { return true }
        return now.timeIntervalSince(lastRebindAt) >= Self.rebindCooldown
    }
```

Поправить вызов в `poll(now:)` на `checkMicrophone(now: now)`.

В `stopCapture(at:reason:)` дописать сброс: `rebindAttempts = 0`, `lastRebindAt = nil`.

- [ ] **Step 4: Прогнать тесты задачи**

Run: `swift test --filter Rebind`
Expected: PASS, четыре теста.

- [ ] **Step 5: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений.

- [ ] **Step 6: Коммит**

```bash
git add Features/Meetings/MeetingCoordinator.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Координатор перепривязывает микрофон на появившееся устройство

Потолок в три попытки и пауза в десять секунд: устройство может молчать
по своей причине, а updateConfiguration дёргает поток, которым пишется
единственная уцелевшая дорожка."
```

---

### Task 7: Немота попадает в архив и в исход на панели

**Files:**
- Modify: `Features/Meetings/MeetingMetadata.swift`
- Modify: `Features/Meetings/MeetingCoordinator.swift` — `stopCapture`, `keepDraft`
- Test: `Tests/MeetingsTests/MeetingMetadataTests.swift`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Outcome.microphoneSilentSeconds` из задачи 3
- Produces: ничего для последующих задач

- [ ] **Step 1: Написать падающий тест на метаданные**

Дописать в `Tests/MeetingsTests/MeetingMetadataTests.swift`:

```swift
// Через полгода в файле встречи не будет ни одной реплики «Я», и единственное, чем это можно
// объяснить, — запись рядом с дорожками.
@Test func silenceOfTheMicrophoneTrackSurvivesInTheFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var metadata = sampleMetadata()
    metadata.microphoneSilentSeconds = 5598.8
    try metadata.write(to: url)

    let read = try MeetingMetadata.read(from: url)

    #expect(read.microphoneSilentSeconds == 5598.8)
}
```

(`sampleMetadata()` — уже существующая в файле фабрика; если её нет, собрать `MeetingMetadata` со всеми параметрами, как в соседних тестах.)

- [ ] **Step 2: Прогнать и убедиться, что не собирается**

Run: `swift test --filter silenceOfTheMicrophoneTrack`
Expected: FAIL — нет свойства `microphoneSilentSeconds`.

- [ ] **Step 3: Добавить поле**

В `Features/Meetings/MeetingMetadata.swift`, рядом с `microphoneStartedAt`:

```swift
    /// How long the microphone track had been delivering nothing but digital zeroes when the
    /// recording ended, or `nil` for a recording that ended before this was measured.
    ///
    /// Not the same question as `inputDevice`: with no input device ScreenCaptureKit still hands
    /// over a full-rate stream of zeroes, so a file can carry a perfectly good device and an
    /// empty track. This is the number that explains a transcript with no "Я" in it.
    public var microphoneSilentSeconds: TimeInterval?
```
с параметром последним в `public init`.

Поправить все места построения `MeetingMetadata` — `MeetingCoordinator.startCapture` передаёт `microphoneSilentSeconds: nil`.

- [ ] **Step 4: Записывать в `stopCapture`**

В `stopCapture(at:reason:)`, в замыкании `closing`, рядом с `record?.microphoneStartedAt = outcome.microphoneStartedAt`, добавить:

```swift
                record?.microphoneSilentSeconds = outcome.microphoneSilentSeconds
```

- [ ] **Step 5: Написать падающий тест на исход**

```swift
// Английская строка про формат буфера была последним, что владелец узнал о потере своей
// дорожки. Панель говорит по-русски и говорит, что именно потеряно.
@Test @MainActor func aRecordingWhoseMicrophoneStayedSilentSaysSoWhenItIsKept() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentAtStop = 600

    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(1))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.shown.contains { state in
        if case .failure(let text) = state { return text.contains("Микрофон молчал 10 мин") }
        return false
    })
}
```

В `FakeCapture` добавить `var silentAtStop: TimeInterval = 0` и передать его как
`microphoneSilentSeconds: silentAtStop` в `Outcome`, который возвращает `stop()`.

- [ ] **Step 6: Провести немоту до `keepDraft`**

Сейчас `closing` — это `Task<String?, Never>`: закрытие капчура отдаёт наружу только причину
отказа. Немота — вторая вещь, которую надо сказать владельцу на том же экране, поэтому задача
начинает возвращать обе.

В `MeetingCoordinator` завести тип и поменять объявление:

```swift
    /// What closing a capture leaves for whoever decides the folder's fate. Two fields rather
    /// than one string: a failure is an `Error` and stays English, while a silent track is a
    /// sentence for a person — the same split `MeetingNotice` already makes.
    private struct Closed {
        var failure: String?
        var microphoneSilentSeconds: TimeInterval
    }

    private var closing: Task<Closed, Never>?
```

В `stopCapture(at:reason:)` внутри `closing = Task { … }` заменить `return failure` на:

```swift
            return Closed(
                failure: failure,
                microphoneSilentSeconds: silentSeconds
            )
```
где `silentSeconds` берётся из `outcome.microphoneSilentSeconds` в ветке успеха и равен `0`
в ветке `catch` — при упавшем `stop()` никакого числа нет, и выдумывать его нельзя.

В `keepDraft()` заменить строку `if let stopFailure = await closing?.value ?? nil { failures.append(stopFailure) }` на:

```swift
            if let closed = await closing?.value {
                if let failure = closed.failure { failures.append(failure) }
                // Interface text, so Russian — the rule `MeetingNotice` follows. Said only when
                // the silence outlasted the threshold: a recording that lost its last ten
                // seconds of microphone lost nothing worth a red line.
                if closed.microphoneSilentSeconds >= Self.microphoneSilenceThreshold {
                    failures.append(
                        "Микрофон молчал \(ElapsedTime.minutes(closed.microphoneSilentSeconds)) мин"
                            + " — ваша дорожка пустая"
                    )
                }
            }
```

В `discardDraft()` и `settle()` строки `_ = await closing?.value` остаются как есть — обе
только дожидаются задачи и её значение не читают.

- [ ] **Step 7: Прогнать весь набор**

Run: `swift test 2>&1 | tail -3`
Expected: ноль падений.

- [ ] **Step 8: Коммит**

```bash
git add Features/Meetings/MeetingMetadata.swift Features/Meetings/MeetingCoordinator.swift Tests/MeetingsTests/
git commit -m "Немота дорожки попадает в meeting.json и в исход на панели

Транскрипт без единой реплики «Я» больше нечем объяснить, и объяснение
должно лежать рядом с дорожками."
```

---

## Проверка на живой машине

После задачи 7 — то, чего не проверит ни один тест, потому что живой `SCStream` в тестовом процессе не поднять.

- [ ] Собрать и перезапустить приложение: `./Scripts/make-app.sh`, убить старый процесс, запустить новый.
- [ ] Отключить AirPods, чтобы устройства ввода не было вовсе.
- [ ] Начать запись созвона вручную из меню.
- [ ] Убедиться, что через десять секунд на полоске появилась красная надпись «микрофон молчит».
- [ ] Подключить AirPods и говорить вслух.
- [ ] Убедиться, что надпись пропала в течение двадцати секунд.
- [ ] Остановить запись, дождаться расшифровки, убедиться, что в файле есть реплики «Я» — и что они начинаются с момента подключения, а не с начала встречи.
- [ ] Проверить `meeting.json`: `microphoneSilentSeconds` близко к длине немого куска, а не к длине встречи.
