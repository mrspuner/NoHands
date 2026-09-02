# Фаза 1 — диктовка. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Довести диктовку до рабочего состояния: зажал fn, наговорил, отпустил — чистый текст появился в активном поле любого приложения.

**Architecture:** Чистое ядро и тонкие системные обёртки. Конечный автомат `DictationMachine` принимает события и возвращает список эффектов, не делая ни одного системного вызова, — он тестируется целиком без клавиатуры и микрофона. Эффекты исполняет `DictationCoordinator`, панель рисует таргет `App`. Зависимости строго в одну сторону: `App → Dictation → Core`, `CLI → Dictation → Core`.

**Tech Stack:** Swift 6, Swift Package Manager без Xcode-проекта, swift-testing (`import Testing`), AVAudioEngine, CoreGraphics event tap, AppKit (`NSStatusItem`, `NSPanel`, `NSPasteboard`), SwiftUI для содержимого панели, FluidAudio 0.14.8 (уже подключён), URLSession.

**Spec:** `docs/superpowers/specs/2026-09-02-phase1-dictation-design.md`

## Global Constraints

- Swift 6, платформа `.macOS(.v14)`. Строгая проверка конкурентности включена по умолчанию — новые типы, пересекающие границы, должны быть `Sendable`.
- **Новых зависимостей не добавлять.** HTTP — на `URLSession`, разбор аргументов — вручную. `FluidAudio` закреплён `.exact("0.14.8")` и не трогается.
- Идентификаторы, комментарии в коде и **сообщения об ошибках — по-английски**. Вывод CLI и текст в интерфейсе — по-русски. Коммиты — по-русски.
- **Не логировать содержимое транскриптов и распознанного текста.** Ни `print`, ни в файл, ни в панель дольше, чем требуется для показа. Это исключает «напечатаем текст, чтобы проверить» как способ приёмки: где нужна проверка результата, текст кладётся в буфер обмена или вставляется.
- **Не заменять внятную ошибку молчаливым фолбэком.** Единственное исключение, согласованное спекой, — отказ чистки: вставляется сырой текст, но отказ при этом назван и озвучен.
- В каждом запросе к DeepSeek обязателен `thinking: {"type": "disabled"}`. Без него счёт растёт в тридцать пять раз.
- `CFBundleIdentifier` — `com.nohands.app`, не меняется никогда: к нему привязаны выданные разрешения.
- Ключи API — только Keychain, читаются через `Core/Secrets/Keychain.swift`. Ни в коде, ни в конфиге, ни в гите.
- Тест раньше кода. Каждая задача заканчивается коммитом.
- Внутри фазы не забегаем вперёд: ничего для фазы 2, никаких обобщений под одну реализацию.

---

## Расхождения с текстом спеки

Две вещи в плане сделаны иначе, чем буквально написано в спеке, — обе упрощают, ни одна не меняет поведение:

1. **`failed` не является состоянием автомата.** Любой отказ возвращает автомат в `idle` и выдаёт эффекты «звук отказа», «показать причину», «спрятать панель через 3 секунды». Отдельное состояние потребовало бы явного выхода из него, а забытый выход означал бы, что после первой же ошибки диктовка перестаёт работать до перезапуска.
2. **Панель и стартовый звук появляются не в момент нажатия fn, а когда удержание превысило порог.** Иначе случайное касание клавиши даёт вспышку панели и писк. Правило живёт в автомате и покрыто тестами.

---

## Структура файлов

```
Package.swift                             + таргеты Dictation, App; + тесты DictationTests

Core/
  Audio/
    MicrophoneRecorder.swift        ИЗМ   старт/стоп/сброс; record(seconds:) сверху
    RecordingSession.swift          НОВ   одна живая запись, счётчики под замком
    AudioLevel.swift                НОВ   RMS → 0…1, чистые функции
  LLM/
    CleanupPayload.swift            НОВ   сборка тела запроса и разбор ответа, чистое
    CleanupError.swift              НОВ   отказы чистки
    DeepSeekClient.swift            НОВ   актор, один сетевой вызов
  Secrets/
    Keychain.swift                  ИЗМ   + константы службы nohands-deepseek

Features/Dictation/
  DictationConfig.swift             НОВ   чтение и значения по умолчанию
  TargetApp.swift                   НОВ   приложение-получатель, без AppKit
  DictationFailure.swift            НОВ   отказы диктовки одним типом
  DictationMachine.swift            НОВ   состояния, события, эффекты, reduce
  PanelState.swift                  НОВ   что показывать, без текста интерфейса
  KeyEventReader.swift              НОВ   CGEvent → доменное событие, чистое
  FnKeyMonitor.swift                НОВ   CGEventTap, обёртка
  PasteboardSnapshot.swift          НОВ   снимок и возврат буфера обмена
  TextInserter.swift                НОВ   активация получателя, Cmd+V, возврат буфера
  SoundPlayer.swift                 НОВ   системные звуки
  LastDictation.swift               НОВ   последняя диктовка в памяти
  DictationCoordinator.swift        НОВ   исполняет эффекты, владеет автоматом

App/
  main.swift                        НОВ   NSApplication, .accessory
  AppDelegate.swift                 НОВ   сборка зависимостей, запуск координатора
  StatusMenu.swift                  НОВ   NSStatusItem и его меню
  DictationPanel.swift              НОВ   NSPanel, неактивирующая
  PanelView.swift                   НОВ   SwiftUI-содержимое панели
  PanelModel.swift                  НОВ   наблюдаемое состояние панели
  Info.plist                        НОВ

CLI/
  NoHands.swift                     ИЗМ   + команда dictate
  DictateCommand.swift              НОВ   запись по Enter, конвейер, вывод

Scripts/
  make-app.sh                       НОВ   сборка и подпись бандла

Tests/
  CoreTests/AudioLevelTests.swift            НОВ
  CoreTests/RecordingSessionTests.swift      НОВ
  CoreTests/CleanupPayloadTests.swift        НОВ
  DictationTests/DictationConfigTests.swift  НОВ
  DictationTests/DictationMachineTests.swift НОВ
  DictationTests/KeyEventReaderTests.swift   НОВ
  DictationTests/PasteboardSnapshotTests.swift НОВ
  DictationTests/LastDictationTests.swift    НОВ
```

---

### Задача 1: Запись со стартом и стопом, уровень звука наружу

Соответствует задаче 1 спеки. Сейчас `MicrophoneRecorder.record(seconds:to:)` пишет фиксированную длительность — диктовке нужен старт и стоп по событию, а панели нужен уровень звука. Существующее поведение сохраняется: `record(seconds:)` остаётся и реализуется поверх новой пары.

**Files:**
- Create: `Core/Audio/AudioLevel.swift`
- Create: `Core/Audio/RecordingSession.swift`
- Modify: `Core/Audio/MicrophoneRecorder.swift`
- Test: `Tests/CoreTests/AudioLevelTests.swift`, `Tests/CoreTests/RecordingSessionTests.swift`

**Interfaces:**
- Consumes: `RecordingChecks.openForWriting`, `.validateCaptured`, `.removeIfOwned`, `AudioInputDevice.current()` — всё уже есть.
- Produces:
  - `public enum AudioLevel { static func rms(_ samples: [Int16]) -> Float; static func normalized(rms: Float) -> Float; static func normalized(buffer: AVAudioPCMBuffer) -> Float }`
  - `public actor MicrophoneRecorder { func start(to url: URL, onLevel: LevelHandler?) throws; func stop() throws -> URL; func discard(); func record(seconds:to:) async throws }`, где `public typealias LevelHandler = @Sendable (Float) -> Void`
  - `RecordingError` дополняется случаями `.alreadyRecording` и `.notRecording`

- [ ] **Шаг 1: Тесты на уровень звука**

`Tests/CoreTests/AudioLevelTests.swift`:

```swift
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
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter AudioLevel`
Expected: FAIL — `cannot find 'AudioLevel' in scope`

- [ ] **Шаг 3: Реализовать уровень**

`Core/Audio/AudioLevel.swift`:

```swift
import AVFoundation
import Foundation

/// Loudness of one buffer, normalized for drawing.
///
/// The panel shows a live level while you speak. Root mean square answers "how loud", but in
/// linear form it is useless for drawing: ordinary speech sits in the bottom few percent of the
/// range and the bar barely moves. Mapping it to decibels and clamping to a -60…0 dBFS window
/// spreads speech across the whole bar.
public enum AudioLevel {
    /// Quieter than this is not drawn at all.
    static let floorDB: Float = -60

    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768.0
            sum += value * value
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }

    /// Reads the buffer's samples in place — this runs on the real-time audio thread, where
    /// allocating an array per buffer would be the wrong thing to do.
    public static func normalized(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let samples = channel[0]
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index]) / 32768.0
            sum += value * value
        }
        return normalized(rms: Float((sum / Double(count)).squareRoot()))
    }
}
```

- [ ] **Шаг 4: Тесты на уровень проходят**

Run: `swift test --filter AudioLevel`
Expected: PASS, семь тестов

- [ ] **Шаг 5: Тесты на сессию записи**

`Tests/CoreTests/RecordingSessionTests.swift`. Сессия — это то, что живая запись хранит между стартом и стопом. Проверяется её чистая часть: счётчики под замком, идемпотентный разбор и прореживание уровней.

```swift
import Foundation
import Testing
@testable import Core

@Test func firstWriteErrorIsKept() {
    let session = RecordingCounters()
    session.recordWriteFailure(NSError(domain: "first", code: 1))
    session.recordWriteFailure(NSError(domain: "second", code: 2))
    // Later writes fail the same way and would only bury the more informative first one.
    #expect((session.outcome().writeError as NSError?)?.domain == "first")
}

@Test func framesAccumulate() {
    let session = RecordingCounters()
    session.addFrames(100)
    session.addFrames(60)
    #expect(session.outcome().frames == 160)
}

@Test func noWritesMeansZeroFrames() {
    #expect(RecordingCounters().outcome().frames == 0)
}

// The panel redraws 20 times a second. The audio tap fires far more often than that, and
// every emitted level hops threads, so the tap thins them out itself.
@Test func firstLevelIsAlwaysEmitted() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 0, interval: 0.05))
}

@Test func levelsCloserThanTheIntervalAreDropped() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 10.0, interval: 0.05))
    #expect(!counters.shouldEmitLevel(at: 10.02, interval: 0.05))
}

@Test func levelIsEmittedAgainAfterTheInterval() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 10.0, interval: 0.05))
    #expect(counters.shouldEmitLevel(at: 10.06, interval: 0.05))
}
```

- [ ] **Шаг 6: Убедиться, что тесты падают**

Run: `swift test --filter RecordingSession`
Expected: FAIL — `cannot find 'RecordingCounters' in scope`

- [ ] **Шаг 7: Реализовать сессию**

`Core/Audio/RecordingSession.swift`:

```swift
import AVFoundation
import Foundation

/// Mutable state of one live recording, shared with the audio tap.
///
/// The tap closure runs on a real-time audio thread: it cannot await, so actor isolation is
/// not available to it. A lock is. Split out from `RecordingSession` so the decisions it makes
/// are testable without a microphone.
final class RecordingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var writeError: Error?
    private var framesWritten: AVAudioFrameCount = 0
    private var lastLevelAt: Double?

    func recordWriteFailure(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        // Keep the first failure; later writes fail the same way and would only overwrite the
        // more informative one.
        if writeError == nil {
            writeError = error
        }
    }

    func addFrames(_ count: AVAudioFrameCount) {
        lock.lock()
        defer { lock.unlock() }
        framesWritten += count
    }

    func outcome() -> (writeError: Error?, frames: AVAudioFrameCount) {
        lock.lock()
        defer { lock.unlock() }
        return (writeError, framesWritten)
    }

    /// True at most once per `interval`. Called from the audio thread on every buffer.
    func shouldEmitLevel(at now: Double, interval: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastLevelAt, now - lastLevelAt < interval {
            return false
        }
        lastLevelAt = now
        return true
    }
}

/// One live recording: everything `stop()` and `discard()` need to finish or undo it.
final class RecordingSession: @unchecked Sendable {
    let engine: AVAudioEngine
    let input: AVAudioInputNode
    let file: AVAudioFile
    let url: URL
    let fileExistedBefore: Bool
    let counters = RecordingCounters()

    private let teardownLock = NSLock()
    private var isTornDown = false

    init(engine: AVAudioEngine, input: AVAudioInputNode, file: AVAudioFile, url: URL, fileExistedBefore: Bool) {
        self.engine = engine
        self.input = input
        self.file = file
        self.url = url
        self.fileExistedBefore = fileExistedBefore
    }

    /// Idempotent, and every read of `counters` must come after it: while the tap can still
    /// fire, a buffer delivered in the gap would write a value nobody reads.
    func tearDown() {
        teardownLock.lock()
        let already = isTornDown
        isTornDown = true
        teardownLock.unlock()
        guard !already else { return }
        engine.stop()
        input.removeTap(onBus: 0)
    }
}
```

- [ ] **Шаг 8: Тесты на сессию проходят**

Run: `swift test --filter RecordingSession`
Expected: PASS, шесть тестов

- [ ] **Шаг 9: Переписать `MicrophoneRecorder` на старт и стоп**

`Core/Audio/MicrophoneRecorder.swift` — добавить два случая в `RecordingError` и заменить тело актора. `RecordingChecks` и текст существующих ошибок не трогать: их комментарии описывают дефекты, которые уже были пойманы, и они остаются в силе.

```swift
// В RecordingError добавить:
    case alreadyRecording
    case notRecording

// В errorDescription добавить:
        case .alreadyRecording:
            return "A recording is already in progress"
        case .notRecording:
            return "No recording is in progress"
```

Тело актора целиком:

```swift
/// Records the default input into a 16 kHz mono WAV file — the format both engines accept
/// without resampling.
public actor MicrophoneRecorder {
    /// Called on the audio thread, thinned out to 20 times a second. The receiver is
    /// responsible for hopping to whatever thread it needs.
    public typealias LevelHandler = @Sendable (Float) -> Void

    private var session: RecordingSession?

    public init() {}

    public func start(to url: URL, onLevel: LevelHandler? = nil) throws {
        guard session == nil else { throw RecordingError.alreadyRecording }
        guard AudioInputDevice.current() != nil else { throw RecordingError.noInputDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw RecordingError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecordingError.unsupportedFormat
        }

        // From here on `url` may exist on disk. Checked before the file is created, so a file
        // that was already there is never removed by a failure of this call.
        let fileExistedBefore = FileManager.default.fileExists(atPath: url.path)

        do {
            let file = try RecordingChecks.openForWriting(url, targetFormat: targetFormat)
            let live = RecordingSession(
                engine: engine, input: input, file: file, url: url, fileExistedBefore: fileExistedBefore
            )
            let sharedConverter = converter
            let counters = live.counters

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    return
                }

                var consumed = false
                var conversionError: NSError?
                sharedConverter.convert(to: converted, error: &conversionError) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }

                guard conversionError == nil, converted.frameLength > 0 else { return }
                do {
                    try file.write(from: converted)
                    counters.addFrames(converted.frameLength)
                } catch {
                    counters.recordWriteFailure(error)
                }

                if let onLevel, counters.shouldEmitLevel(at: ProcessInfo.processInfo.systemUptime, interval: 0.05) {
                    onLevel(AudioLevel.normalized(buffer: converted))
                }
            }

            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw RecordingError.engineFailed(error.localizedDescription)
            }

            session = live
        } catch {
            RecordingChecks.removeIfOwned(url, existedBefore: fileExistedBefore)
            throw error
        }
    }

    /// - Returns: the file that was written.
    /// - Throws: `noAudioCaptured` when the tap never delivered a buffer — which is what a
    ///   denied microphone permission looks like, since the engine starts and the tap installs
    ///   without complaint. The file is removed in that case.
    public func stop() throws -> URL {
        guard let live = session else { throw RecordingError.notRecording }
        session = nil
        live.tearDown()

        let outcome = live.counters.outcome()
        do {
            if let writeError = outcome.writeError {
                throw RecordingError.writeFailed(writeError.localizedDescription)
            }
            try RecordingChecks.validateCaptured(frameCount: outcome.frames)
        } catch {
            RecordingChecks.removeIfOwned(live.url, existedBefore: live.fileExistedBefore)
            throw error
        }
        return live.url
    }

    /// Stops without producing anything: the file this call created is removed. Used when the
    /// owner cancels, and when a hold turns out to be too short to have been meant.
    public func discard() {
        guard let live = session else { return }
        session = nil
        live.tearDown()
        RecordingChecks.removeIfOwned(live.url, existedBefore: live.fileExistedBefore)
    }

    /// Fixed-duration recording, kept for the phase 0 `nohands record` command.
    public func record(seconds: TimeInterval, to url: URL) async throws {
        try start(to: url)
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            discard()
            throw error
        }
        _ = try stop()
    }
}
```

- [ ] **Шаг 10: Весь набор тестов проходит**

Run: `swift test`
Expected: PASS. Существующие тесты `MicrophoneRecorderTests` должны пройти без правок — если какой-то из них упал, значит поведение изменилось там, где не должно было.

- [ ] **Шаг 11: Проверка живой записью**

Run: `swift run nohands record 3 /tmp/nohands-check.wav && afinfo /tmp/nohands-check.wav`
Expected: файл длительностью около трёх секунд, 16000 Гц, один канал. Это подтверждает, что `record(seconds:)` поверх новой пары не сломался.

- [ ] **Шаг 12: Коммит**

```bash
git add Core/Audio Tests/CoreTests/AudioLevelTests.swift Tests/CoreTests/RecordingSessionTests.swift
git commit -m "Запись со стартом и стопом, уровень звука наружу"
```

---

### Задача 2: Таргет `Dictation` и конфиг

Соответствует задаче 1 спеки в части настроек. Заводится новый таргет — он понадобится всем последующим задачам, — и в нём первое, что нужно и CLI, и приложению: чтение конфига со значениями по умолчанию.

**Files:**
- Modify: `Package.swift`
- Create: `Features/Dictation/DictationConfig.swift`
- Test: `Tests/DictationTests/DictationConfigTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces: `public struct DictationConfig: Equatable, Sendable, Codable` с полями `language: String?`, `minimumHoldSeconds: Double`, `maxRecordingSeconds: Double`, `model: String`, `timeoutSeconds: Double`, `prompt: String`, `sounds: DictationConfig.Sounds`; статические `default`, `decode(_:) throws`, `fileURL`, `loadOrCreate(at:) throws`. `public struct Sounds: Equatable, Sendable, Codable` с полями `enabled: Bool`, `start: String`, `done: String`, `error: String`.

- [ ] **Шаг 1: Завести таргет**

`Package.swift` — добавить в `targets` и в `products`:

```swift
        .library(name: "Dictation", targets: ["Dictation"]),
```

```swift
        .target(
            name: "Dictation",
            dependencies: ["Core"],
            path: "Features/Dictation"
        ),
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation"],
            path: "Tests/DictationTests"
        ),
```

- [ ] **Шаг 2: Написать падающие тесты**

`Tests/DictationTests/DictationConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import Dictation

// A config file that is missing keys must not be a failure: the owner edits this file by hand,
// and deleting a line to "reset it" is the natural thing to try.
@Test func missingKeysFallBackToDefaults() throws {
    let config = try DictationConfig.decode(Data("{}".utf8))
    #expect(config == DictationConfig.default)
}

@Test func onlyTheGivenKeyChanges() throws {
    let config = try DictationConfig.decode(Data(#"{"minimumHoldSeconds": 0.8}"#.utf8))
    #expect(config.minimumHoldSeconds == 0.8)
    #expect(config.maxRecordingSeconds == DictationConfig.default.maxRecordingSeconds)
    #expect(config.prompt == DictationConfig.default.prompt)
}

@Test func nestedSoundsAlsoFallBack() throws {
    let config = try DictationConfig.decode(Data(#"{"sounds": {"enabled": false}}"#.utf8))
    #expect(config.sounds.enabled == false)
    #expect(config.sounds.start == DictationConfig.default.sounds.start)
}

@Test func languageCanBeNull() throws {
    let config = try DictationConfig.decode(Data(#"{"language": null}"#.utf8))
    #expect(config.language == nil)
}

// Broken JSON is an error, not a silent reset: quietly falling back to defaults would leave
// the owner editing a file the app has stopped reading.
@Test func brokenJSONThrows() {
    #expect(throws: (any Error).self) {
        try DictationConfig.decode(Data("{ not json".utf8))
    }
}

@Test func missingFileIsCreatedWithDefaults() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-config-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let config = try DictationConfig.loadOrCreate(at: url)
    #expect(config == DictationConfig.default)
    #expect(FileManager.default.fileExists(atPath: url.path))

    // And what was written is readable back as the same thing.
    #expect(try DictationConfig.loadOrCreate(at: url) == DictationConfig.default)
}

@Test func existingFileIsRead() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"timeoutSeconds": 3}"#.utf8).write(to: url)

    #expect(try DictationConfig.loadOrCreate(at: url).timeoutSeconds == 3)
}
```

- [ ] **Шаг 3: Убедиться, что тесты падают**

Run: `swift test --filter DictationConfig`
Expected: FAIL — `no such module 'Dictation'` либо `cannot find 'DictationConfig' in scope`

- [ ] **Шаг 4: Реализовать конфиг**

`Features/Dictation/DictationConfig.swift`:

```swift
import Foundation

/// Settings the owner edits by hand in `~/Library/Application Support/NoHands/config.json`.
///
/// Every key is optional on read and falls back to the default: this file is edited with a
/// text editor, and a missing line must not stop the app. Broken JSON, on the other hand, is
/// reported — silently ignoring it would leave the owner editing a file nothing reads.
public struct DictationConfig: Equatable, Sendable, Codable {
    public struct Sounds: Equatable, Sendable, Codable {
        public var enabled: Bool
        /// Names of system sounds, as `NSSound(named:)` takes them.
        public var start: String
        public var done: String
        public var error: String

        public init(enabled: Bool, start: String, done: String, error: String) {
            self.enabled = enabled
            self.start = start
            self.done = done
            self.error = error
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = DictationConfig.default.sounds
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
            start = try container.decodeIfPresent(String.self, forKey: .start) ?? fallback.start
            done = try container.decodeIfPresent(String.self, forKey: .done) ?? fallback.done
            error = try container.decodeIfPresent(String.self, forKey: .error) ?? fallback.error
        }
    }

    /// ISO-639-1 hint for Parakeet. Not a language switch — the model is multilingual either
    /// way; it only steers decoding towards one script on close calls.
    public var language: String?
    /// Holding fn for less than this is an accidental brush against the key: the recording is
    /// dropped without a sound and without the panel ever appearing.
    public var minimumHoldSeconds: Double
    /// Hard stop, so a forgotten latched recording cannot run all day.
    public var maxRecordingSeconds: Double
    public var model: String
    public var timeoutSeconds: Double
    public var prompt: String
    public var sounds: Sounds

    public static let `default` = DictationConfig(
        language: "ru",
        minimumHoldSeconds: 0.3,
        maxRecordingSeconds: 300,
        model: "deepseek-chat",
        timeoutSeconds: 10,
        prompt: """
        Ты редактор устной речи. Тебе дают расшифровку диктовки как есть.
        Убери слова-заполнители, повторы и самоисправления. Расставь знаки препинания и \
        заглавные буквы. Сохрани язык, смысл, порядок мыслей и терминологию говорящего. \
        Ничего не добавляй, не пересказывай, не отвечай на сказанное и не комментируй. \
        Верни только исправленный текст, без пояснений и без кавычек.
        """,
        sounds: Sounds(enabled: true, start: "Tink", done: "Pop", error: "Basso")
    )

    public init(
        language: String?,
        minimumHoldSeconds: Double,
        maxRecordingSeconds: Double,
        model: String,
        timeoutSeconds: Double,
        prompt: String,
        sounds: Sounds
    ) {
        self.language = language
        self.minimumHoldSeconds = minimumHoldSeconds
        self.maxRecordingSeconds = maxRecordingSeconds
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.prompt = prompt
        self.sounds = sounds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DictationConfig.default
        language = try container.decodeIfPresent(String.self, forKey: .language)
        minimumHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .minimumHoldSeconds)
            ?? fallback.minimumHoldSeconds
        maxRecordingSeconds = try container.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds)
            ?? fallback.maxRecordingSeconds
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? fallback.timeoutSeconds
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? fallback.prompt
        sounds = try container.decodeIfPresent(Sounds.self, forKey: .sounds) ?? fallback.sounds
    }

    public static func decode(_ data: Data) throws -> DictationConfig {
        try JSONDecoder().decode(DictationConfig.self, from: data)
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }

    /// Reads the file, or writes the defaults and returns those. Writing on first run means the
    /// owner has a complete file to edit instead of having to remember the key names.
    public static func loadOrCreate(at url: URL = fileURL) throws -> DictationConfig {
        if let data = FileManager.default.contents(atPath: url.path) {
            return try decode(data)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(DictationConfig.default).write(to: url)
        return .default
    }
}
```

- [ ] **Шаг 5: Тесты проходят**

Run: `swift test --filter DictationConfig`
Expected: PASS, семь тестов

- [ ] **Шаг 6: Коммит**

```bash
git add Package.swift Features/Dictation Tests/DictationTests
git commit -m "Таргет Dictation и чтение конфига"
```

---

### Задача 3: Клиент DeepSeek

Соответствует задаче 2 спеки. Чистка текста в облаке — единственное место, где что-либо покидает машину. Разбор и сборка проверяются тестами без сети; форма запроса подтверждается одним живым вызовом.

**Files:**
- Create: `Core/LLM/CleanupPayload.swift`, `Core/LLM/CleanupError.swift`, `Core/LLM/DeepSeekClient.swift`
- Modify: `Core/Secrets/Keychain.swift`
- Test: `Tests/CoreTests/CleanupPayloadTests.swift`

**Interfaces:**
- Consumes: `Keychain.password(service:account:)`.
- Produces:
  - `public enum CleanupError: Error, Equatable, LocalizedError` со случаями `.apiKeyMissing`, `.requestFailed(status: Int, message: String)`, `.emptyResult`
  - `enum CleanupPayload { static func body(model: String, maxTokens: Int, prompt: String, text: String) throws -> Data; static func text(from data: Data) throws -> String }`
  - `public actor DeepSeekClient { init(apiKey:model:prompt:timeout:); static func fromKeychain(model:prompt:timeout:) throws -> DeepSeekClient; func clean(_ text: String) async throws -> String }`
  - `Keychain.deepSeekService = "nohands-deepseek"`, `Keychain.deepSeekAccount = "api-key"`

- [ ] **Шаг 1: Подтвердить форму запроса живым вызовом**

Прежде чем писать код — один вызов, чтобы адрес, заголовки и имя модели были фактом, а не памятью. Ключ уже лежит в Keychain.

```bash
KEY=$(security find-generic-password -s nohands-deepseek -a api-key -w)
curl -sS https://api.deepseek.com/anthropic/v1/messages \
  -H "x-api-key: $KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"deepseek-chat","max_tokens":64,"thinking":{"type":"disabled"},
       "system":"Верни ровно слово OK.","messages":[{"role":"user","content":"проверка"}]}'
```

Expected: JSON с полем `content`, внутри блок `{"type":"text","text":"OK"}`.

Если ответ — ошибка про модель, взять имя из ответа или из личного кабинета DeepSeek и подставить его в `DictationConfig.default.model`.

Если ошибка про адрес, значит совместимости с Anthropic на этом ключе нет и остаётся форма OpenAI: `POST https://api.deepseek.com/v1/chat/completions`, заголовок `Authorization: Bearer $KEY`, тело `{"model":…, "max_tokens":…, "thinking":{"type":"disabled"}, "messages":[{"role":"system","content":<промпт>},{"role":"user","content":<текст>}]}`, ответ читается из `choices[0].message.content`. Параметр `thinking` обязателен в обеих формах — это не деталь совместимости, а условие сметы. Тогда `Request` и `Response` в `CleanupPayload` пишутся под эти имена, а тесты меняются по ним же: проверяется ровно то же самое.

**Записать в шапке `CleanupPayload.swift`, какая форма подтвердилась и когда.**

- [ ] **Шаг 2: Написать падающие тесты**

`Tests/CoreTests/CleanupPayloadTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

// Without this parameter the model spends its whole output budget reasoning and never reaches
// an answer — thirty five times the output tokens, forty cents a month becoming fourteen
// dollars. It is the single most expensive thing that can silently go missing from this file.
@Test func requestAlwaysDisablesThinking() throws {
    let body = try CleanupPayload.body(model: "m", maxTokens: 100, prompt: "p", text: "t")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let thinking = try #require(json["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "disabled")
}

@Test func requestCarriesModelPromptAndText() throws {
    let body = try CleanupPayload.body(model: "deepseek-chat", maxTokens: 512, prompt: "чисти", text: "эээ привет")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "deepseek-chat")
    #expect(json["system"] as? String == "чисти")
    #expect(json["max_tokens"] as? Int == 512)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == "эээ привет")
}

@Test func responseYieldsTheTextBlock() throws {
    let data = Data(#"{"content":[{"type":"text","text":"Привет."}]}"#.utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

// Blocks other than text can appear alongside the answer; taking the first block blindly would
// return an empty string on those days.
@Test func responseSkipsNonTextBlocks() throws {
    let data = Data(#"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"Привет."}]}"#.utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

@Test func responseTrimsSurroundingWhitespace() throws {
    let data = Data("{\"content\":[{\"type\":\"text\",\"text\":\"  Привет.\\n\"}]}".utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

// An empty answer must not become an empty paste. Same rule as TranscriberChecks.nonEmpty.
@Test func emptyContentIsAnError() {
    #expect(throws: CleanupError.emptyResult) {
        try CleanupPayload.text(from: Data(#"{"content":[]}"#.utf8))
    }
}

@Test func blankTextIsAnError() {
    #expect(throws: CleanupError.emptyResult) {
        try CleanupPayload.text(from: Data(#"{"content":[{"type":"text","text":"   "}]}"#.utf8))
    }
}
```

- [ ] **Шаг 3: Убедиться, что тесты падают**

Run: `swift test --filter CleanupPayload`
Expected: FAIL — `cannot find 'CleanupPayload' in scope`

- [ ] **Шаг 4: Реализовать разбор и сборку**

`Core/LLM/CleanupError.swift`:

```swift
import Foundation

public enum CleanupError: Error, Equatable, LocalizedError {
    case apiKeyMissing
    case requestFailed(status: Int, message: String)
    /// The service answered with nothing usable. Reported instead of an empty string so it can
    /// never be pasted as one.
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "DeepSeek API key not found in Keychain (service: nohands-deepseek, account: api-key)"
        case .requestFailed(let status, let message):
            return "Text cleanup request failed with HTTP \(status): \(message)"
        case .emptyResult:
            return "Text cleanup returned no text"
        }
    }
}
```

`Core/LLM/CleanupPayload.swift`:

```swift
import Foundation

/// The body sent to DeepSeek and the answer read back, kept apart from the network call so
/// both are testable without one.
///
/// Shape confirmed against the live API on 2026-09-02: Anthropic-compatible messages endpoint
/// at `https://api.deepseek.com/anthropic/v1/messages`. See step 1 of task 3 in the plan.
enum CleanupPayload {
    private struct Request: Encodable {
        struct Thinking: Encodable {
            let type = "disabled"
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        /// Not optional and never omitted. Reasoning left on costs thirty five times the
        /// output tokens and never reaches an answer.
        let thinking = Thinking()
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case thinking
            case system
            case messages
        }
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    static func body(model: String, maxTokens: Int, prompt: String, text: String) throws -> Data {
        try JSONEncoder().encode(
            Request(
                model: model,
                maxTokens: maxTokens,
                system: prompt,
                messages: [Request.Message(role: "user", content: text)]
            )
        )
    }

    static func text(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let joined = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw CleanupError.emptyResult }
        return joined
    }
}
```

- [ ] **Шаг 5: Тесты проходят**

Run: `swift test --filter CleanupPayload`
Expected: PASS, семь тестов

- [ ] **Шаг 6: Добавить константы ключа и написать клиент**

В `Core/Secrets/Keychain.swift`, рядом с существующими константами:

```swift
    public static let deepSeekService = "nohands-deepseek"
    public static let deepSeekAccount = "api-key"
```

`Core/LLM/DeepSeekClient.swift`:

```swift
import Foundation

/// Cleans up dictated text: fillers, repetitions, punctuation.
///
/// The only thing in this application that leaves the machine, and only ever the owner's own
/// speech — meeting transcripts are summarized locally for exactly this reason.
public actor DeepSeekClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
    /// Cleanup returns roughly what it was given, so the budget is derived from the input
    /// rather than fixed: a long dictation must not be cut off mid-sentence.
    private static let tokenBudgetMultiplier = 3

    private let apiKey: String
    private let model: String
    private let prompt: String
    private let timeout: TimeInterval

    public init(apiKey: String, model: String, prompt: String, timeout: TimeInterval) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
    }

    /// A keychain that refuses the query throws with its status; only a genuinely absent item
    /// becomes `apiKeyMissing`.
    public static func fromKeychain(model: String, prompt: String, timeout: TimeInterval) throws -> DeepSeekClient {
        guard let key = try Keychain.password(
            service: Keychain.deepSeekService,
            account: Keychain.deepSeekAccount
        ) else {
            throw CleanupError.apiKeyMissing
        }
        return DeepSeekClient(apiKey: key, model: model, prompt: prompt, timeout: timeout)
    }

    public func clean(_ text: String) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try CleanupPayload.body(
            model: model,
            maxTokens: max(256, text.count * Self.tokenBudgetMultiplier),
            prompt: prompt,
            text: text
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CleanupError.requestFailed(status: 0, message: "no HTTP response")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw CleanupError.requestFailed(status: http.statusCode, message: message)
        }
        return try CleanupPayload.text(from: data)
    }
}
```

- [ ] **Шаг 7: Сборка и весь набор тестов**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Шаг 8: Коммит**

```bash
git add Core/LLM Core/Secrets/Keychain.swift Tests/CoreTests/CleanupPayloadTests.swift
git commit -m "Клиент DeepSeek для чистки диктовки"
```

---

### Задача 4: Команда `nohands dictate`

Соответствует задаче 2 спеки. Конвейер целиком — запись, распознавание, чистка — без бандла, без разрешений, без интерфейса. Первое место, где видно настоящую задержку.

**Files:**
- Create: `CLI/DictateCommand.swift`
- Modify: `CLI/NoHands.swift`, `Package.swift`
- Test: `Tests/CLITests/DictateArgumentsTests.swift`

**Interfaces:**
- Consumes: `DictationConfig.loadOrCreate()`, `MicrophoneRecorder.start/stop`, `ParakeetTranscriber.load(language:)`, `DeepSeekClient.fromKeychain(model:prompt:timeout:)`, `AudioInputDevice.current()`, `narrowbandWarning(sampleRate:)`.
- Produces: `struct DictateArguments { var raw: Bool; static func parse(_:) throws -> DictateArguments }`.

- [ ] **Шаг 1: Подключить `Dictation` к CLI**

`Package.swift`, таргет `CLI`:

```swift
            dependencies: ["Core", "Dictation"],
```

- [ ] **Шаг 2: Написать падающие тесты на разбор аргументов**

`Tests/CLITests/DictateArgumentsTests.swift`:

```swift
import Foundation
import Testing
@testable import CLI

@Test func dictateDefaultsToCleaningTheText() throws {
    #expect(try DictateArguments.parse(["dictate"]).raw == false)
}

@Test func rawFlagSkipsCleanup() throws {
    #expect(try DictateArguments.parse(["dictate", "--raw"]).raw == true)
}

@Test func unknownArgumentIsRejected() {
    #expect(throws: DictateArguments.ParseError.message("Неизвестный аргумент: --fast")) {
        try DictateArguments.parse(["dictate", "--fast"])
    }
}
```

- [ ] **Шаг 3: Убедиться, что тесты падают**

Run: `swift test --filter DictateArguments`
Expected: FAIL — `cannot find 'DictateArguments' in scope`

- [ ] **Шаг 4: Реализовать команду**

`CLI/DictateCommand.swift`:

```swift
import Core
import Dictation
import Foundation

/// Parsed `nohands dictate` arguments. Same shape as `TranscribeArguments`: parsing throws
/// instead of calling `fail`, so it is testable without `exit(1)`.
struct DictateArguments {
    var raw = false

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static let usage = "Использование: nohands dictate [--raw]"

    static func parse(_ arguments: [String]) throws -> DictateArguments {
        var result = DictateArguments()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--raw":
                result.raw = true
                index += 1
            default:
                throw ParseError.message("Неизвестный аргумент: \(arguments[index])")
            }
        }
        return result
    }
}
```

В `CLI/NoHands.swift` — новая ветка в `switch command`, строка в `usage` и сама команда:

```swift
// В usage добавить:
nohands dictate [--raw]
    Диктовка целиком: запись микрофона до Enter, распознавание Parakeet,
    чистка через DeepSeek, вывод текста. --raw печатает текст без чистки.
```

```swift
            case "dictate":
                try await runDictate(arguments)
```

```swift
    static func runDictate(_ arguments: [String]) async throws {
        let parsed: DictateArguments
        do {
            parsed = try DictateArguments.parse(arguments)
        } catch DictateArguments.ParseError.message(let message) {
            fail(message)
        }

        let config = try DictationConfig.loadOrCreate()
        guard let device = AudioInputDevice.current() else {
            fail("Устройство ввода не найдено. У Mac mini нет встроенного микрофона — подключите внешний")
        }
        print("устройство: \(device.name)")
        if let warning = narrowbandWarning(sampleRate: device.sampleRate) {
            print(warning)
        }

        // The model is loaded before recording starts, the way the application will hold it
        // resident — otherwise the load time would land inside the measured latency and make
        // dictation look slower than it is.
        let loadStarted = Date()
        let transcriber = try await ParakeetTranscriber.load(language: config.language)
        note("модель готова за \(String(format: "%.1f", Date().timeIntervalSince(loadStarted))) с")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nohands-dictate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = MicrophoneRecorder()
        try await recorder.start(to: url)
        print("пишу… Enter — стоп")
        _ = readLine()
        let file = try await recorder.stop()

        let recognitionStarted = Date()
        let rawText = try await transcriber.transcribe(audio: file)
        let recognized = Date()
        note("распознавание \(String(format: "%.2f", recognized.timeIntervalSince(recognitionStarted))) с")

        guard !parsed.raw else {
            print(rawText)
            return
        }

        let client = try DeepSeekClient.fromKeychain(
            model: config.model, prompt: config.prompt, timeout: config.timeoutSeconds
        )
        let cleaned = try await client.clean(rawText)
        note("чистка \(String(format: "%.2f", Date().timeIntervalSince(recognized))) с")
        print(cleaned)
    }
```

- [ ] **Шаг 5: Тесты проходят**

Run: `swift test --filter DictateArguments`
Expected: PASS, три теста

- [ ] **Шаг 6: Живой прогон**

Run: `swift run nohands dictate`
Наговорить фразу с паразитами и техническим термином, нажать Enter.
Expected: в stderr — время модели, распознавания и чистки; в stdout — чистый текст без «эээ», с пунктуацией. Записать сумму времён: это и есть настоящая задержка диктовки, ради проверки которой фаза и разделена.

- [ ] **Шаг 7: Прогон без чистки для сравнения**

Run: `swift run nohands dictate --raw`
Expected: сырой текст с паразитами. Разница с предыдущим прогоном показывает, что именно делает чистка, — на этом же материале решается, годится ли промпт из конфига.

- [ ] **Шаг 8: Коммит**

```bash
git add CLI Package.swift Tests/CLITests/DictateArgumentsTests.swift
git commit -m "Команда nohands dictate: конвейер диктовки в терминале"
```

---

### Задача 5: Конечный автомат диктовки

Соответствует задаче 4 спеки. Самая важная задача плана: здесь живёт всё поведение, и здесь же оно целиком покрывается тестами — без клавиатуры, микрофона и сети.

**Files:**
- Create: `Features/Dictation/TargetApp.swift`, `Features/Dictation/PanelState.swift`, `Features/Dictation/DictationMachine.swift`
- Test: `Tests/DictationTests/DictationMachineTests.swift`

**Interfaces:**
- Consumes: `DictationConfig`.
- Produces:
  - `public struct TargetApp: Equatable, Sendable { let bundleIdentifier: String?; let name: String }`
  - `public enum PanelState: Equatable, Sendable { case recording(target:latched:), transcribing(target:), cleaning(target:), inserting(target:cleanupSkipped:), failure(String) }`
  - `public struct DictationMachine` с вложенными `Limits`, `Mode`, `State`, `Event`, `Sound`, `Effect`, свойством `state` и методом `mutating func handle(_ event: Event) -> [Effect]`

- [ ] **Шаг 1: Написать падающие тесты**

`Tests/DictationTests/DictationMachineTests.swift`:

```swift
import Foundation
import Testing
@testable import Dictation

private let target = TargetApp(bundleIdentifier: "com.apple.mail", name: "Mail")
private let start = Date(timeIntervalSince1970: 1_000_000)

private func machine() -> DictationMachine {
    DictationMachine(limits: DictationMachine.Limits(
        minimumHold: 0.3, maximumRecording: 300, failureDwell: 3, successDwell: 0.6
    ))
}

/// Drives a machine up to a recording that has already been announced — the state most tests
/// start from.
private func recording(latched: Bool = false) -> DictationMachine {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    _ = subject.handle(.tick(start.addingTimeInterval(0.35)))
    if latched {
        _ = subject.handle(.spaceDown)
    }
    return subject
}

@Test func pressingFnStartsRecordingAndSwallowsBothKeys() {
    var subject = machine()
    let effects = subject.handle(.fnDown(at: start, target: target))
    #expect(effects == [.startRecording, .swallow(space: true, escape: true)])
}

// The panel and the start sound deliberately do not appear on the press: a brush against fn
// would give a flash and a beep for nothing.
@Test func nothingIsShownBeforeTheHoldThreshold() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    #expect(subject.handle(.tick(start.addingTimeInterval(0.2))) == [])
}

@Test func panelAndSoundAppearOnceTheHoldIsLongEnough() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    let effects = subject.handle(.tick(start.addingTimeInterval(0.31)))
    #expect(effects == [.play(.start), .show(.recording(target: target, latched: false))])
}

@Test func theAnnouncementHappensOnlyOnce() {
    var subject = recording()
    #expect(subject.handle(.tick(start.addingTimeInterval(1))) == [])
}

@Test func aBrushAgainstFnIsDiscardedSilently() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(0.1)))
    #expect(effects == [.discardRecording, .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

// The threshold is measured from the timestamps, not from whether a tick happened to arrive:
// a dropped tick must not throw away a real dictation.
@Test func aLongHoldIsKeptEvenIfNoTickArrived() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing(target: target)),
    ])
}

@Test func releasingFnAfterARealHoldStopsTheRecording() {
    var subject = recording()
    let effects = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing(target: target)),
    ])
}

@Test func spaceLatchesTheRecordingAndStopsSwallowingSpace() {
    var subject = recording()
    let effects = subject.handle(.spaceDown)
    #expect(effects == [
        .swallow(space: false, escape: true),
        .show(.recording(target: target, latched: true)),
    ])
}

@Test func releasingFnAfterLatchingDoesNothing() {
    var subject = recording(latched: true)
    #expect(subject.handle(.fnUp(at: start.addingTimeInterval(2))) == [])
}

@Test func pressingFnAgainStopsALatchedRecording() {
    var subject = recording(latched: true)
    let effects = subject.handle(.fnDown(at: start.addingTimeInterval(5), target: target))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing(target: target)),
    ])
}

// Protection against a latched recording nobody remembered to stop.
@Test func recordingIsCutOffAtTheMaximum() {
    var subject = recording(latched: true)
    let effects = subject.handle(.tick(start.addingTimeInterval(301)))
    #expect(effects == [
        .stopRecording,
        .swallow(space: false, escape: true),
        .show(.transcribing(target: target)),
    ])
}

@Test func escapeDuringRecordingThrowsTheAudioAway() {
    var subject = recording()
    let effects = subject.handle(.escapeDown)
    #expect(effects == [.discardRecording, .hidePanel(after: 0), .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

@Test func escapeWhileWorkingCancelsTheWork() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.escapeDown)
    #expect(effects == [.cancelWork, .hidePanel(after: 0), .swallow(space: false, escape: false)])
    #expect(subject.state == .idle)
}

@Test func theStoppedFileGoesToRecognition() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    let url = URL(fileURLWithPath: "/tmp/a.wav")
    #expect(subject.handle(.recordingStopped(url)) == [.transcribe(url)])
}

@Test func recognizedTextGoesToCleanup() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcribed("эээ привет"))
    #expect(effects == [.show(.cleaning(target: target)), .clean("эээ привет")])
}

private func cleaning() -> DictationMachine {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    _ = subject.handle(.transcribed("эээ привет"))
    return subject
}

@Test func cleanedTextIsInserted() {
    var subject = cleaning()
    let effects = subject.handle(.cleaned("Привет."))
    #expect(effects == [
        .show(.inserting(target: target, cleanupSkipped: nil)),
        .insert(text: "Привет.", into: target, cleaned: true),
    ])
}

// The one place where work continues after a failure. It is not a silent fallback: the reason
// is named on the panel and the error sound plays.
@Test func failedCleanupInsertsTheRawTextAndSaysSo() {
    var subject = cleaning()
    let effects = subject.handle(.cleanupFailed("offline"))
    #expect(effects == [
        .play(.error),
        .show(.inserting(target: target, cleanupSkipped: "offline")),
        .insert(text: "эээ привет", into: target, cleaned: false),
    ])
}

@Test func aCleanInsertionEndsWithTheDoneSound() {
    var subject = cleaning()
    _ = subject.handle(.cleaned("Привет."))
    let effects = subject.handle(.inserted)
    #expect(effects == [.swallow(space: false, escape: false), .play(.done), .hidePanel(after: 0.6)])
    #expect(subject.state == .idle)
}

// The error sound already played when cleanup failed; a success chime right after it would say
// the opposite of what happened.
@Test func insertionAfterSkippedCleanupIsSilent() {
    var subject = cleaning()
    _ = subject.handle(.cleanupFailed("offline"))
    let effects = subject.handle(.inserted)
    #expect(effects == [.swallow(space: false, escape: false), .hidePanel(after: 0.6)])
}

@Test func recognitionFailureIsNamedOnThePanel() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcriptionFailed("Transcription returned no text"))
    #expect(effects == [
        .play(.error),
        .show(.failure("Transcription returned no text")),
        .hidePanel(after: 3),
        .swallow(space: false, escape: false),
    ])
}

// A failure must never be a resting state: the next press of fn has to work.
@Test func theNextDictationWorksAfterAFailure() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingFailed("No audio was captured"))
    #expect(subject.state == .idle)
    #expect(subject.handle(.fnDown(at: start.addingTimeInterval(10), target: target))
        == [.startRecording, .swallow(space: true, escape: true)])
}

// A microphone that is not there fails when the engine starts, not when it stops: without
// this the owner would hold fn, hear nothing, release it and never learn why.
@Test func aRecordingThatNeverStartedIsReported() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start, target: target))
    let effects = subject.handle(.recordingFailed("No audio input device is available"))
    #expect(effects == [
        .discardRecording,
        .play(.error),
        .show(.failure("No audio input device is available")),
        .hidePanel(after: 3),
        .swallow(space: false, escape: false),
    ])
    #expect(subject.state == .idle)
}

@Test func strayEventsInIdleAreIgnored() {
    var subject = machine()
    #expect(subject.handle(.spaceDown) == [])
    #expect(subject.handle(.escapeDown) == [])
    #expect(subject.handle(.fnUp(at: start)) == [])
    #expect(subject.handle(.tick(start)) == [])
    #expect(subject.state == .idle)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter DictationMachine`
Expected: FAIL — `cannot find 'DictationMachine' in scope`

- [ ] **Шаг 3: Реализовать вспомогательные типы**

`Features/Dictation/TargetApp.swift`:

```swift
import Foundation

/// The application a dictation is aimed at, captured when recording starts rather than when
/// the text is pasted.
///
/// Deliberately holds no `NSRunningApplication` and no icon: this type crosses into the state
/// machine, which must stay testable without AppKit. The panel looks the live application up
/// by `bundleIdentifier` when it needs the icon.
public struct TargetApp: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String

    public init(bundleIdentifier: String?, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}
```

`Features/Dictation/PanelState.swift`:

```swift
import Foundation

/// What the panel is showing. Structure only — no wording: the interface speaks Russian and
/// that belongs to the `App` target, while everything here has to stay testable on its own.
public enum PanelState: Equatable, Sendable {
    case recording(target: TargetApp, latched: Bool)
    case transcribing(target: TargetApp)
    case cleaning(target: TargetApp)
    /// `cleanupSkipped` carries the reason cleanup did not happen, or nil when it did.
    case inserting(target: TargetApp, cleanupSkipped: String?)
    case failure(String)
}
```

- [ ] **Шаг 4: Реализовать автомат**

`Features/Dictation/DictationMachine.swift`:

```swift
import Foundation

/// Everything dictation does, as a pure function of state and event.
///
/// Not one system call lives here: no keyboard, no microphone, no network, no window. Events
/// come in, a list of effects goes out, and the coordinator performs them. That is what makes
/// the whole behaviour — thresholds, latching, cancellation, every failure path — testable
/// without a machine to run it on.
///
/// Failure is not a state. Any failure returns the machine to `idle` and emits the effects
/// that report it, because a resting failure state would need an explicit way out, and a
/// missing way out means dictation stops working until the app is restarted.
public struct DictationMachine {
    public struct Limits: Equatable, Sendable {
        public var minimumHold: TimeInterval
        public var maximumRecording: TimeInterval
        public var failureDwell: TimeInterval
        public var successDwell: TimeInterval

        public init(
            minimumHold: TimeInterval,
            maximumRecording: TimeInterval,
            failureDwell: TimeInterval = 3,
            successDwell: TimeInterval = 0.6
        ) {
            self.minimumHold = minimumHold
            self.maximumRecording = maximumRecording
            self.failureDwell = failureDwell
            self.successDwell = successDwell
        }

        public init(config: DictationConfig) {
            self.init(
                minimumHold: config.minimumHoldSeconds,
                maximumRecording: config.maxRecordingSeconds
            )
        }
    }

    public enum Mode: Equatable, Sendable {
        case held
        case latched
    }

    public enum State: Equatable, Sendable {
        case idle
        /// `announced` is false until the hold has outlasted `minimumHold` — before that the
        /// panel has not appeared and no sound has played.
        case recording(mode: Mode, since: Date, target: TargetApp, announced: Bool)
        /// The engine has been told to stop; the file has not come back yet.
        case stopping(target: TargetApp)
        case transcribing(target: TargetApp)
        case cleaning(raw: String, target: TargetApp)
        case inserting(target: TargetApp, cleanupSkipped: String?)
    }

    public enum Event: Equatable, Sendable {
        case fnDown(at: Date, target: TargetApp)
        case fnUp(at: Date)
        case spaceDown
        case escapeDown
        /// Delivered while recording, often enough to notice both thresholds.
        case tick(Date)
        case recordingStopped(URL)
        case recordingFailed(String)
        case transcribed(String)
        case transcriptionFailed(String)
        case cleaned(String)
        case cleanupFailed(String)
        case inserted
        case insertionFailed(String)
    }

    public enum Sound: Equatable, Sendable {
        case start
        case done
        case error
    }

    public enum Effect: Equatable, Sendable {
        case startRecording
        case stopRecording
        case discardRecording
        /// Cancel whatever recognition or cleanup is in flight.
        case cancelWork
        case transcribe(URL)
        case clean(String)
        case insert(text: String, into: TargetApp, cleaned: Bool)
        case show(PanelState)
        case hidePanel(after: TimeInterval)
        case play(Sound)
        /// Which keys the tap must stop passing through to the rest of the system.
        case swallow(space: Bool, escape: Bool)
    }

    public let limits: Limits
    public private(set) var state: State = .idle

    public init(limits: Limits) {
        self.limits = limits
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .fnDown(let at, let target)):
            state = .recording(mode: .held, since: at, target: target, announced: false)
            return [.startRecording, .swallow(space: true, escape: true)]

        case (.recording(let mode, let since, let target, let announced), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maximumRecording {
                return stopRecording(target: target)
            }
            guard !announced, now.timeIntervalSince(since) >= limits.minimumHold else { return [] }
            state = .recording(mode: mode, since: since, target: target, announced: true)
            return [.play(.start), .show(.recording(target: target, latched: mode == .latched))]

        case (.recording(.held, let since, let target, _), .fnUp(let at)):
            // Measured from the timestamps rather than from `announced`: a tick that never
            // arrived must not throw away a dictation the owner actually made.
            guard at.timeIntervalSince(since) >= limits.minimumHold else {
                state = .idle
                return [.discardRecording, .swallow(space: false, escape: false)]
            }
            return stopRecording(target: target)

        case (.recording(.latched, _, _, _), .fnUp):
            return []

        case (.recording(.latched, _, let target, _), .fnDown):
            return stopRecording(target: target)

        case (.recording(.held, let since, let target, let announced), .spaceDown):
            state = .recording(mode: .latched, since: since, target: target, announced: announced)
            var effects: [Effect] = [.swallow(space: false, escape: true)]
            if announced {
                effects.append(.show(.recording(target: target, latched: true)))
            }
            return effects

        case (.recording, .escapeDown):
            state = .idle
            return [.discardRecording, .hidePanel(after: 0), .swallow(space: false, escape: false)]

        // The engine refuses at start, not at stop — a missing input device, a denied
        // permission. `discardRecording` also stops the clock the coordinator started.
        case (.recording, .recordingFailed(let message)):
            return [.discardRecording] + failed(message)

        case (.stopping(let target), .recordingStopped(let url)):
            state = .transcribing(target: target)
            return [.transcribe(url)]

        case (.stopping, .recordingFailed(let message)):
            return failed(message)

        case (.stopping, .escapeDown), (.transcribing, .escapeDown), (.cleaning, .escapeDown):
            state = .idle
            return [.cancelWork, .hidePanel(after: 0), .swallow(space: false, escape: false)]

        case (.transcribing(let target), .transcribed(let text)):
            state = .cleaning(raw: text, target: target)
            return [.show(.cleaning(target: target)), .clean(text)]

        case (.transcribing, .transcriptionFailed(let message)):
            return failed(message)

        case (.cleaning(_, let target), .cleaned(let text)):
            state = .inserting(target: target, cleanupSkipped: nil)
            return [
                .show(.inserting(target: target, cleanupSkipped: nil)),
                .insert(text: text, into: target, cleaned: true),
            ]

        case (.cleaning(let raw, let target), .cleanupFailed(let message)):
            state = .inserting(target: target, cleanupSkipped: message)
            return [
                .play(.error),
                .show(.inserting(target: target, cleanupSkipped: message)),
                .insert(text: raw, into: target, cleaned: false),
            ]

        case (.inserting(_, let skipped), .inserted):
            state = .idle
            var effects: [Effect] = [.swallow(space: false, escape: false)]
            // The error sound has already played when cleanup was skipped; a success chime on
            // top of it would say the opposite of what happened.
            if skipped == nil {
                effects.append(.play(.done))
            }
            effects.append(.hidePanel(after: limits.successDwell))
            return effects

        case (.inserting, .insertionFailed(let message)):
            return failed(message)

        default:
            return []
        }
    }

    private mutating func stopRecording(target: TargetApp) -> [Effect] {
        state = .stopping(target: target)
        return [.stopRecording, .swallow(space: false, escape: true), .show(.transcribing(target: target))]
    }

    private mutating func failed(_ message: String) -> [Effect] {
        state = .idle
        return [
            .play(.error),
            .show(.failure(message)),
            .hidePanel(after: limits.failureDwell),
            .swallow(space: false, escape: false),
        ]
    }
}
```

- [ ] **Шаг 5: Тесты проходят**

Run: `swift test --filter DictationMachine`
Expected: PASS, двадцать три теста

- [ ] **Шаг 6: Коммит**

```bash
git add Features/Dictation Tests/DictationTests/DictationMachineTests.swift
git commit -m "Конечный автомат диктовки"
```

---

### Задача 6: Разбор событий клавиатуры

Соответствует задаче 5 спеки в части, которую можно проверить без разрешения. Здесь живёт единственный надёжный способ отличить настоящую fn от стрелки.

**Files:**
- Create: `Features/Dictation/KeyEventReader.swift`
- Test: `Tests/DictationTests/KeyEventReaderTests.swift`

**Interfaces:**
- Produces: `public enum KeyEventKind: Equatable, Sendable { case fnDown, fnUp, spaceDown, escapeDown }` и `public enum KeyEventReader { static let fnKeyCode: Int64; static let spaceKeyCode: Int64; static let escapeKeyCode: Int64; static func kind(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> KeyEventKind? }`

- [ ] **Шаг 1: Написать падающие тесты**

`Tests/DictationTests/KeyEventReaderTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import Dictation

// flagsChanged carries no up or down: fn is down when the event that reports key code 63 also
// carries the function flag, and up when it does not.
@Test func fnPressIsRecognized() {
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn) == .fnDown)
}

@Test func fnReleaseIsRecognized() {
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 63, flags: []) == .fnUp)
}

// The whole reason this function exists. macOS sets the function flag for arrow keys, the F
// row, Home, End, Page Up and Page Down — matching on the flag alone would start a recording
// every time the owner pressed an arrow key.
@Test func anArrowKeyIsNotFn() {
    // Left arrow is key code 123 and arrives with the very same flag set.
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 123, flags: .maskSecondaryFn) == nil)
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 123, flags: .maskSecondaryFn) == nil)
}

@Test func spaceIsRecognizedOnlyOnKeyDown() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 49, flags: []) == .spaceDown)
    #expect(KeyEventReader.kind(type: .keyUp, keyCode: 49, flags: []) == nil)
}

@Test func escapeIsRecognizedOnlyOnKeyDown() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 53, flags: []) == .escapeDown)
    #expect(KeyEventReader.kind(type: .keyUp, keyCode: 53, flags: []) == nil)
}

@Test func everyOtherKeyIsIgnored() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 0, flags: []) == nil)
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 36, flags: []) == nil)
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 56, flags: .maskShift) == nil)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter KeyEventReader`
Expected: FAIL — `cannot find 'KeyEventReader' in scope`

- [ ] **Шаг 3: Реализовать разбор**

`Features/Dictation/KeyEventReader.swift`:

```swift
import CoreGraphics
import Foundation

public enum KeyEventKind: Equatable, Sendable {
    case fnDown
    case fnUp
    case spaceDown
    case escapeDown
}

/// Turns a raw keyboard event into one of the four things dictation cares about.
///
/// Separated from the tap so the one rule that is easy to get wrong is testable without a
/// keyboard, a run loop or the accessibility permission.
public enum KeyEventReader {
    /// `kVK_Function`. fn is not an ordinary modifier: `RegisterEventHotKey` cannot bind it,
    /// and the `.maskSecondaryFn` flag it sets is also set by arrow keys, the F row, Home, End
    /// and both Page keys. The key code in a `flagsChanged` event is the only thing that
    /// identifies the physical fn key.
    public static let fnKeyCode: Int64 = 63
    /// `kVK_Space`
    public static let spaceKeyCode: Int64 = 49
    /// `kVK_Escape`
    public static let escapeKeyCode: Int64 = 53

    public static func kind(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> KeyEventKind? {
        switch type {
        case .flagsChanged where keyCode == fnKeyCode:
            return flags.contains(.maskSecondaryFn) ? .fnDown : .fnUp
        case .keyDown where keyCode == spaceKeyCode:
            return .spaceDown
        case .keyDown where keyCode == escapeKeyCode:
            return .escapeDown
        default:
            return nil
        }
    }
}
```

- [ ] **Шаг 4: Тесты проходят**

Run: `swift test --filter KeyEventReader`
Expected: PASS, шесть тестов

- [ ] **Шаг 5: Коммит**

```bash
git add Features/Dictation/KeyEventReader.swift Tests/DictationTests/KeyEventReaderTests.swift
git commit -m "Разбор событий клавиатуры: fn отличается от стрелок по коду клавиши"
```

---

### Задача 7: Бандл, подпись, статус-бар

Соответствует задаче 3 спеки. Первый раз появляется `.app`. Диктовки в нём ещё нет — задача считается сделанной, когда приложение живёт в менюбаре и выходит по пункту меню.

**Files:**
- Create: `App/main.swift`, `App/AppDelegate.swift`, `App/StatusMenu.swift`, `App/Info.plist`, `Scripts/make-app.sh`
- Modify: `Package.swift`, `.gitignore`

**Interfaces:**
- Consumes: `DictationConfig.loadOrCreate()`, `DictationConfig.fileURL`, `Keychain.password(service:account:)`.
- Produces: `@MainActor final class StatusMenu` с `init(onQuit:onReloadConfig:)`, `func setStatus(_ text: String)`; `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.

- [ ] **Шаг 1: Завести таргет приложения**

`Package.swift` — в `products`:

```swift
        .executable(name: "NoHandsApp", targets: ["App"]),
```

в `targets`:

```swift
        .executableTarget(
            name: "App",
            dependencies: ["Core", "Dictation"],
            path: "App",
            // Info.plist belongs to the bundle the script assembles, not to the binary; without
            // this SwiftPM treats it as an unhandled resource and warns on every build.
            exclude: ["Info.plist"]
        ),
```

- [ ] **Шаг 2: Написать `Info.plist`**

`App/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NoHands</string>
    <key>CFBundleDisplayName</key>
    <string>NoHands</string>
    <key>CFBundleExecutable</key>
    <string>NoHands</string>
    <key>CFBundleIdentifier</key>
    <string>com.nohands.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>NoHands записывает микрофон, пока вы держите клавишу fn, и превращает речь в текст.</string>
</dict>
</plist>
```

- [ ] **Шаг 3: Написать точку входа и меню**

`App/main.swift`:

```swift
import AppKit

// `.accessory` keeps the app out of the Dock and out of the app switcher: it lives in the
// menu bar. LSUIElement in Info.plist says the same thing to the launcher; this covers the
// case of running the binary directly during development.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
```

`App/StatusMenu.swift`:

```swift
import AppKit
import Dictation

/// The menu bar item and its menu.
///
/// The icon never changes: the panel is what reports what dictation is doing, and an icon that
/// blinks in a place the owner is not looking would be noise. The menu exists for the things
/// that have no other home — the config file and the permissions.
@MainActor
final class StatusMenu {
    private let item: NSStatusItem
    private let statusLine: NSMenuItem

    init(onQuit: @escaping () -> Void, onReloadConfig: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: "NoHands"
        )

        statusLine = NSMenuItem(title: "Проверяю…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Открыть конфиг", action: #selector(Actions.openConfig), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(
            withTitle: "Перечитать конфиг", action: #selector(Actions.reloadConfig), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(
            withTitle: "Проверить разрешения", action: #selector(Actions.checkPermissions), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Выход", action: #selector(Actions.quit), keyEquivalent: "q")
        quit.target = Actions.shared
        Actions.shared.onQuit = onQuit
        Actions.shared.onReloadConfig = onReloadConfig

        item.menu = menu
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    /// Menu targets have to be Objective-C objects; keeping them on one small class keeps that
    /// requirement from leaking into everything else.
    @MainActor
    final class Actions: NSObject {
        static let shared = Actions()
        var onQuit: (() -> Void)?
        var onReloadConfig: (() -> Void)?

        @objc func openConfig() {
            NSWorkspace.shared.open(DictationConfig.fileURL)
        }

        @objc func reloadConfig() {
            onReloadConfig?()
        }

        /// Passing the prompt option opens the system dialog when the permission has not been
        /// granted — the only way to get there without walking the owner through Settings.
        @objc func checkPermissions() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }

        @objc func quit() {
            onQuit?()
            NSApplication.shared.terminate(nil)
        }
    }
}
```

`App/AppDelegate.swift`:

```swift
import AppKit
import Core
import Dictation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(onQuit: {}, onReloadConfig: { [weak self] in
            self?.statusMenu?.setStatus(self?.readiness() ?? "")
        })
        statusMenu = menu
        menu.setStatus(readiness())
    }

    /// One line the owner can read at a glance when dictation does not work. Both causes are
    /// things only they can fix, and both are invisible otherwise.
    private func readiness() -> String {
        if !AXIsProcessTrusted() {
            return "Нет разрешения на управление компьютером"
        }
        let key = try? Keychain.password(
            service: Keychain.deepSeekService, account: Keychain.deepSeekAccount
        )
        if key == nil {
            return "Нет ключа DeepSeek в связке ключей"
        }
        return "Готов"
    }
}
```

- [ ] **Шаг 4: Написать скрипт сборки**

`Scripts/make-app.sh`:

```bash
#!/bin/bash
# Собирает NoHands.app и подписывает его.
#
# Подпись — самоподписанным сертификатом, а не ad-hoc: ad-hoc пишет в требование к коду хеш
# самого бинарника, и после каждой пересборки macOS считает приложение другой программой,
# отзывая разрешение на управление компьютером. Сертификат создаётся один раз вручную в
# Связке ключей: Ассистент сертификатов → Создать сертификат → тип «Подпись кода».
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${NOHANDS_SIGNING_IDENTITY:-NoHands Local}"
APP="build/NoHands.app"

swift build -c release --product NoHandsApp
BIN_PATH="$(swift build -c release --product NoHandsApp --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/NoHandsApp" "$APP/Contents/MacOS/NoHands"
cp App/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier com.nohands.app "$APP"
codesign --verify --verbose "$APP"

echo "готово: $APP"
```

Сделать исполняемым: `chmod +x Scripts/make-app.sh`

В `.gitignore` добавить строку `build/`.

- [ ] **Шаг 5: Собрать и подписать**

Run: `./Scripts/make-app.sh`
Expected: `готово: build/NoHands.app`, а `codesign --verify` не ругается. Если ругается «no identity found» — имя сертификата в связке ключей другое, передать своё: `NOHANDS_SIGNING_IDENTITY="…" ./Scripts/make-app.sh`.

- [ ] **Шаг 6: Проверить требование к коду**

Run: `codesign -d --requirements - build/NoHands.app`
Expected: в требовании есть `identifier "com.nohands.app"` и упоминание сертификата — и **нет** `cdhash`. Наличие `cdhash` означало бы ad-hoc подпись, то есть разрешение, слетающее при каждой пересборке; тогда вернуться к шагу 4 и разобраться с сертификатом.

- [ ] **Шаг 7: Запустить**

Run: `open build/NoHands.app`
Expected: в менюбаре появилась иконка микрофона. В её меню — строка состояния, «Открыть конфиг», «Проверить разрешения», «Выход». В доке приложения нет. «Открыть конфиг» открывает json. «Выход» закрывает.

- [ ] **Шаг 8: Коммит**

```bash
git add App Scripts Package.swift .gitignore
git commit -m "Бандл приложения, подпись сертификатом, статус-бар"
```

---

### Задача 8: Перехват клавиатуры, звуки, координатор

Соответствует задаче 5 спеки. Здесь появляется второе системное разрешение и здесь всё сходится вместе. Вставки ещё нет: готовый текст кладётся в буфер обмена, и приёмка — это `Cmd+V` руками. Печатать текст в лог нельзя, а буфер обмена показывает результат, ничего не записывая.

**Files:**
- Create: `Features/Dictation/FnKeyMonitor.swift`, `Features/Dictation/SoundPlayer.swift`, `Features/Dictation/TextInserter.swift`, `Features/Dictation/DictationCoordinator.swift`
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `KeyEventReader.kind(type:keyCode:flags:)`, `DictationMachine`, `MicrophoneRecorder`, `ParakeetTranscriber`, `DeepSeekClient`, `DictationConfig`.
- Produces:
  - `public enum KeyMonitorError: Error, Equatable, LocalizedError { case accessibilityDenied, tapCreationFailed }`
  - `public final class FnKeyMonitor` с `init(onEvent:)`, `start() throws`, `stop()`, `setSwallow(space:escape:)`
  - `@MainActor public struct SoundPlayer { init(sounds:); func play(_ sound: DictationMachine.Sound) }`
  - `@MainActor public struct TextInserter { func copy(_ text: String) }` — в задаче 9 дополняется вставкой
  - `@MainActor public final class DictationCoordinator` с `init(config:recorder:transcriber:cleaner:inserter:sounds:showPanel:hidePanel:onLevel:)`, `start() throws`, `stop()`

- [ ] **Шаг 1: Написать монитор клавиатуры**

Тестов у монитора нет — он весь состоит из системных вызовов, а его единственное решаемое правило уже покрыто тестами `KeyEventReader`.

`Features/Dictation/FnKeyMonitor.swift`:

```swift
import ApplicationServices
import CoreGraphics
import Foundation
import os

public enum KeyMonitorError: Error, Equatable, LocalizedError {
    case accessibilityDenied
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is not granted; grant it in System Settings > " +
                "Privacy & Security > Accessibility"
        case .tapCreationFailed:
            return "Could not create the keyboard event tap"
        }
    }
}

/// Watches for fn, space and escape, and swallows the last two while dictation owns them.
///
/// An active tap on `keyDown` sees every keystroke on the machine. This one compares the key
/// code against three numbers and hands the event straight back: nothing is accumulated,
/// written or sent anywhere. That is the whole cost of latching on space and cancelling on
/// escape, and it is written down in the decisions log.
public final class FnKeyMonitor: @unchecked Sendable {
    private struct Swallow: Sendable {
        var space = false
        var escape = false
        /// Set by the tap itself, not by the coordinator. See `handle`.
        var fnIsDown = false
    }

    private let onEvent: @Sendable (KeyEventKind) -> Void
    private let swallow = OSAllocatedUnfairLock(initialState: Swallow())
    /// Touched only on the main run loop, which is where both `start`/`stop` and the callback
    /// run.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(onEvent: @escaping @Sendable (KeyEventKind) -> Void) {
        self.onEvent = onEvent
    }

    public func setSwallow(space: Bool, escape: Bool) {
        swallow.withLock {
            $0.space = space
            $0.escape = escape
        }
    }

    public func start() throws {
        guard AXIsProcessTrusted() else { throw KeyMonitorError.accessibilityDenied }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // An active tap, not a listener: a listener cannot swallow the space that latches
            // a recording, and that space would land in whatever the owner is typing into.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw KeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off — silently, and for good — when its callback takes too long,
        // or when the user does something the system treats as reason to. Turning it back on
        // here is the only thing standing between one slow moment and dictation never working
        // again for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let kind = KeyEventReader.kind(type: type, keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        // Read the decision before delivering the event, never after: delivering it changes the
        // state machine, and by the time it returns the flags describe the world the keystroke
        // has already created rather than the one it arrived in. Latching is exactly that case
        // — the space that latches a recording turns space-swallowing off.
        let shouldSwallow = swallow.withLock { state -> Bool in
            switch kind {
            case .fnDown:
                state.fnIsDown = true
                return false
            case .fnUp:
                state.fnIsDown = false
                return false
            case .spaceDown:
                // `fnIsDown` is the tap's own knowledge, so this needs no round trip through
                // the coordinator and cannot be stale: space is eaten exactly while fn is
                // physically held, which is exactly when it means "latch".
                return state.space || state.fnIsDown
            case .escapeDown:
                return state.escape
            }
        }

        // FIFO by contract, unlike unstructured tasks: fn down must never be processed after
        // the fn up that follows it.
        let deliver = onEvent
        DispatchQueue.main.async { deliver(kind) }

        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }
}
```

- [ ] **Шаг 2: Написать звуки и запись в буфер**

`Features/Dictation/SoundPlayer.swift`:

```swift
import AppKit
import Foundation

/// The one channel that works while the owner is looking at the text field rather than at the
/// menu bar. System sounds by name — no files in the bundle.
@MainActor
public struct SoundPlayer {
    private let sounds: DictationConfig.Sounds

    public init(sounds: DictationConfig.Sounds) {
        self.sounds = sounds
    }

    public func play(_ sound: DictationMachine.Sound) {
        guard sounds.enabled else { return }
        let name: String
        switch sound {
        case .start: name = sounds.start
        case .done: name = sounds.done
        case .error: name = sounds.error
        }
        NSSound(named: name)?.play()
    }
}
```

`Features/Dictation/TextInserter.swift`:

```swift
import AppKit
import Foundation

/// Puts dictated text where it was aimed.
///
/// In this task it only reaches the pasteboard; `insert(_:into:)` — activation, Cmd+V and
/// putting the pasteboard back — arrives with the accessibility work in the next task.
@MainActor
public struct TextInserter {
    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
```

- [ ] **Шаг 3: Написать координатор**

`Features/Dictation/DictationCoordinator.swift`:

```swift
import AppKit
import Core
import Foundation

/// Performs what the state machine decides.
///
/// Everything here is glue: it holds no rules of its own, and every branch it takes is one the
/// machine already chose. The panel is the single thing it cannot do itself, so drawing arrives
/// as closures from the `App` target — a protocol with one implementation would only obscure
/// which way the dependency runs.
@MainActor
public final class DictationCoordinator {
    private let config: DictationConfig
    private let recorder: MicrophoneRecorder
    private let transcriber: any Transcriber
    private let cleaner: DeepSeekClient
    private let inserter: TextInserter
    private let sounds: SoundPlayer
    private let showPanel: (PanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let onLevel: (Float) -> Void

    private var machine: DictationMachine
    private var monitor: FnKeyMonitor?
    private var ticker: Timer?
    private var work: Task<Void, Never>?
    private var audioURL: URL?

    public init(
        config: DictationConfig,
        recorder: MicrophoneRecorder,
        transcriber: any Transcriber,
        cleaner: DeepSeekClient,
        inserter: TextInserter,
        sounds: SoundPlayer,
        showPanel: @escaping (PanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onLevel: @escaping (Float) -> Void
    ) {
        self.config = config
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.sounds = sounds
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.onLevel = onLevel
        self.machine = DictationMachine(limits: DictationMachine.Limits(config: config))
    }

    public func start() throws {
        let monitor = FnKeyMonitor { [weak self] kind in
            MainActor.assumeIsolated {
                self?.received(kind)
            }
        }
        try monitor.start()
        self.monitor = monitor
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        ticker?.invalidate()
        ticker = nil
        work?.cancel()
    }

    private func received(_ kind: KeyEventKind) {
        let now = Date()
        switch kind {
        case .fnDown:
            // The target is fixed when recording starts, not when the text is pasted: if the
            // owner switches windows mid-sentence, the text still goes where they were aiming.
            apply(.fnDown(at: now, target: Self.frontmostApp()))
        case .fnUp:
            apply(.fnUp(at: now))
        case .spaceDown:
            apply(.spaceDown)
        case .escapeDown:
            apply(.escapeDown)
        }
    }

    private static func frontmostApp() -> TargetApp {
        let app = NSWorkspace.shared.frontmostApplication
        return TargetApp(
            bundleIdentifier: app?.bundleIdentifier,
            name: app?.localizedName ?? "активное окно"
        )
    }

    private func apply(_ event: DictationMachine.Event) {
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    private func perform(_ effect: DictationMachine.Effect) {
        switch effect {
        case .startRecording:
            startRecording()

        case .stopRecording:
            stopTicker()
            run { [recorder] in
                do {
                    let url = try await recorder.stop()
                    return .recordingStopped(url)
                } catch {
                    return .recordingFailed(error.localizedDescription)
                }
            }

        case .discardRecording:
            stopTicker()
            let url = audioURL
            audioURL = nil
            Task { [recorder] in
                await recorder.discard()
                if let url { try? FileManager.default.removeItem(at: url) }
            }

        case .cancelWork:
            work?.cancel()
            work = nil
            discardAudioFile()

        case .transcribe(let url):
            run { [transcriber] in
                do {
                    return .transcribed(try await transcriber.transcribe(audio: url))
                } catch {
                    return .transcriptionFailed(error.localizedDescription)
                }
            }

        case .clean(let text):
            run { [cleaner] in
                do {
                    return .cleaned(try await cleaner.clean(text))
                } catch {
                    return .cleanupFailed(error.localizedDescription)
                }
            }

        case .insert(let text, _, _):
            inserter.copy(text)
            discardAudioFile()
            apply(.inserted)

        case .show(let state):
            showPanel(state)

        case .hidePanel(let delay):
            hidePanel(delay)

        case .play(let sound):
            sounds.play(sound)

        case .swallow(let space, let escape):
            monitor?.setSwallow(space: space, escape: escape)
        }
    }

    private func startRecording() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nohands-dictation-\(UUID().uuidString).wav")
        audioURL = url
        let level = onLevel
        Task { [recorder] in
            do {
                try await recorder.start(to: url) { value in
                    DispatchQueue.main.async { level(value) }
                }
            } catch {
                await MainActor.run { self.apply(.recordingFailed(error.localizedDescription)) }
            }
        }
        // Both thresholds — the accidental brush and the five-minute cut-off — are noticed by
        // the machine, which needs a clock to notice them with.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(.tick(Date()))
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func discardAudioFile() {
        guard let url = audioURL else { return }
        audioURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs one step of the pipeline and feeds its outcome back as an event. Cancellation is
    /// checked before feeding: escape must leave nothing behind.
    private func run(_ body: @escaping @Sendable () async -> DictationMachine.Event) {
        work?.cancel()
        work = Task { [weak self] in
            let event = await body()
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.apply(event) }
        }
    }
}
```

- [ ] **Шаг 4: Собрать координатор в приложении**

`App/AppDelegate.swift` — заменить `applicationDidFinishLaunching` и добавить сборку зависимостей:

```swift
    private var coordinator: DictationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(
            onQuit: { [weak self] in self?.coordinator?.stop() },
            // Re-reading means rebuilding: the thresholds live in the machine, the prompt and
            // the model live in the client, and none of them is consulted again after start.
            onReloadConfig: { [weak self] in
                guard let self, let menu = self.statusMenu else { return }
                Task { await self.buildCoordinator(menu: menu) }
            }
        )
        statusMenu = menu
        menu.setStatus("Загружаю модель…")
        Task { await self.buildCoordinator(menu: menu) }
    }

    private func buildCoordinator(menu: StatusMenu) async {
        coordinator?.stop()
        coordinator = nil
        do {
            let config = try DictationConfig.loadOrCreate()
            // Loaded once and kept resident: 470 MB against 16 GB, and the alternative is
            // paying the load on every dictation, which is when waiting is least acceptable.
            let transcriber = try await ParakeetTranscriber.load(language: config.language)
            let cleaner = try DeepSeekClient.fromKeychain(
                model: config.model, prompt: config.prompt, timeout: config.timeoutSeconds
            )
            let coordinator = DictationCoordinator(
                config: config,
                recorder: MicrophoneRecorder(),
                transcriber: transcriber,
                cleaner: cleaner,
                inserter: TextInserter(),
                sounds: SoundPlayer(sounds: config.sounds),
                showPanel: { _ in },
                hidePanel: { _ in },
                onLevel: { _ in }
            )
            try coordinator.start()
            self.coordinator = coordinator
            menu.setStatus("Готов")
        } catch {
            menu.setStatus(error.localizedDescription)
        }
    }
```

- [ ] **Шаг 5: Сборка и тесты**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Шаг 6: Настроить систему и выдать разрешение**

Сначала — клавиша. Системные настройки → Клавиатура → действие клавиши 🌐 (fn) → **«Ничего не делать»**. По умолчанию за ней закреплены системная диктовка или панель эмодзи, и macOS перехватывает нажатие раньше любого приложения: без этой настройки тап не увидит fn вообще, и отладка уйдёт в код, где всё исправно.

Run: `./Scripts/make-app.sh && open build/NoHands.app`
В меню — «Проверить разрешения», выдать универсальный доступ. Перезапустить приложение.
Expected: в меню «Готов». Если «Нет разрешения на управление компьютером» — разрешение не применилось; проверить, что в списке именно `build/NoHands.app`, а не старая копия.

- [ ] **Шаг 7: Проверить перехват и звуки**

Открыть текстовый редактор. Зажать fn на секунду, наговорить фразу, отпустить.
Expected: звук в начале (через 0,3 с после нажатия, не сразу), звук в конце. Затем `Cmd+V` — вставляется чистый текст.

- [ ] **Шаг 8: Проверить края**

Expected по пунктам:
- Быстрое касание fn — ни звука, ни записи.
- Стрелки и клавиши F-ряда работают как обычно, диктовку не запускают.
- Пробел при зажатой fn — фиксация: звук фиксации не нужен, но запись продолжается после отпускания fn, и в текст пробел не попал. Второе нажатие fn останавливает.
- Пробел без зажатой fn печатается как обычно.
- Esc во время записи — тишина, ничего в буфер не легло, Esc не дошёл до приложения под курсором.
- Esc вне диктовки работает как обычно.
- Отключить сеть, продиктовать: два звука, в буфере — сырой текст с паразитами.

- [ ] **Шаг 9: Коммит**

```bash
git add Features/Dictation App
git commit -m "Перехват fn, пробела и Esc; звуки; координатор диктовки"
```

---

### Задача 9: Вставка текста

Соответствует задаче 6 спеки. Шесть шагов, каждый из которых существует по конкретной причине — их порядок и есть содержание задачи.

**Files:**
- Create: `Features/Dictation/PasteboardSnapshot.swift`
- Modify: `Features/Dictation/TextInserter.swift`, `Features/Dictation/DictationCoordinator.swift`
- Test: `Tests/DictationTests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Produces: `public struct PasteboardSnapshot: Equatable, Sendable { static func capture(_:) -> PasteboardSnapshot; func restore(to:); static func shouldRestore(writtenChangeCount:currentChangeCount:) -> Bool }`; `TextInserter.insert(_ text: String, into target: TargetApp) async throws`; `TextInserter.InsertionError`.

- [ ] **Шаг 1: Написать падающие тесты**

`Tests/DictationTests/PasteboardSnapshotTests.swift`. Именованная монтировка `NSPasteboard` даёт настоящий буфер, не трогая общий, — то есть это честный тест, а не заглушка.

```swift
import AppKit
import Foundation
import Testing
@testable import Dictation

private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("nohands-test-\(UUID().uuidString)"))
}

@MainActor
@Test func snapshotRestoresAString() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.string(forType: .string) == "что было")
}

// The owner may have copied something that is not text at all. Restoring only the string would
// quietly destroy it.
@MainActor
@Test func snapshotRestoresNonTextTypesToo() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    let type = NSPasteboard.PasteboardType("com.nohands.test")
    pasteboard.clearContents()
    pasteboard.setData(Data([1, 2, 3]), forType: type)

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.data(forType: type) == Data([1, 2, 3]))
}

@MainActor
@Test func emptyPasteboardRestoresAsEmpty() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.string(forType: .string) == nil)
}

@Test func restoreHappensWhenNobodyElseWrote() {
    #expect(PasteboardSnapshot.shouldRestore(writtenChangeCount: 7, currentChangeCount: 7))
}

// Somebody copied something in the moment between the paste and the restore. Putting the old
// contents back now would throw away what they just copied.
@Test func restoreIsSkippedWhenSomebodyElseWrote() {
    #expect(!PasteboardSnapshot.shouldRestore(writtenChangeCount: 7, currentChangeCount: 8))
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter PasteboardSnapshot`
Expected: FAIL — `cannot find 'PasteboardSnapshot' in scope`

- [ ] **Шаг 3: Реализовать снимок буфера**

`Features/Dictation/PasteboardSnapshot.swift`:

```swift
import AppKit
import Foundation

/// What was in the pasteboard before dictation borrowed it.
///
/// Pasting through the pasteboard is more reliable than synthesizing the text keystroke by
/// keystroke, especially in Cyrillic — but it means taking something that belongs to the owner
/// and putting it back afterwards, exactly as it was, including the types that are not text.
public struct PasteboardSnapshot: Equatable, Sendable {
    private let items: [[String: Data]]

    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    stored[type.rawValue] = data
                }
            }
            return stored
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Only put the old contents back if nothing else has written since. A copy that happened
    /// in the window between the paste and the restore belongs to the owner, not to us.
    public static func shouldRestore(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
        writtenChangeCount == currentChangeCount
    }
}
```

- [ ] **Шаг 4: Тесты проходят**

Run: `swift test --filter PasteboardSnapshot`
Expected: PASS, пять тестов

- [ ] **Шаг 5: Дописать вставку**

`Features/Dictation/TextInserter.swift` — заменить целиком:

```swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Puts dictated text where it was aimed: pasteboard, Cmd+V, pasteboard back.
@MainActor
public struct TextInserter: Sendable {
    public enum InsertionError: Error, Equatable, LocalizedError {
        case accessibilityDenied
        case eventSourceUnavailable

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is not granted, so the text cannot be pasted; " +
                    "it is on the clipboard — paste it with Cmd+V"
            case .eventSourceUnavailable:
                return "Could not synthesize the paste keystroke"
            }
        }
    }

    /// `kVK_ANSI_V`
    private static let vKeyCode: CGKeyCode = 9
    /// How long the receiving application is given to read the pasteboard before the previous
    /// contents go back.
    private static let readDelay = Duration.milliseconds(300)
    /// How long the target application is given to come to the front.
    private static let activationTimeout = Duration.milliseconds(300)

    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func insert(_ text: String, into target: TargetApp) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        copy(text)
        let written = pasteboard.changeCount

        // The text reaches the pasteboard before the permission is checked, and stays there if
        // the check fails. Without the permission nothing can be pasted anyway, and throwing
        // first would lose the dictation outright; this way the panel names the problem and
        // Cmd+V finishes the job by hand.
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityDenied }

        // Text landing in the wrong window is the worst failure this app has, because it is
        // silent: the dictation looks like it simply vanished.
        await bringToFront(target)
        try postPaste()

        // The receiving application reads the pasteboard asynchronously, after the keystroke.
        // Putting the old contents back on the next line pastes the old contents instead.
        try? await Task.sleep(for: Self.readDelay)
        if PasteboardSnapshot.shouldRestore(
            writtenChangeCount: written, currentChangeCount: pasteboard.changeCount
        ) {
            snapshot.restore(to: pasteboard)
        }
    }

    private func bringToFront(_ target: TargetApp) async {
        guard let identifier = target.bundleIdentifier else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != identifier else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier).first else { return }

        app.activate()
        let deadline = ContinuousClock.now + Self.activationTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == identifier { return }
        }
    }

    private func postPaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            throw InsertionError.eventSourceUnavailable
        }
        // Assigned, not merged: whatever the owner still happens to be holding — Shift, Option —
        // would otherwise ride along and turn Cmd+V into a different command.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
```

- [ ] **Шаг 6: Подключить вставку в координаторе**

`Features/Dictation/DictationCoordinator.swift` — заменить ветку `.insert`:

```swift
        case .insert(let text, let target, _):
            discardAudioFile()
            run { [inserter] in
                do {
                    try await inserter.insert(text, into: target)
                    return .inserted
                } catch {
                    return .insertionFailed(error.localizedDescription)
                }
            }
```

- [ ] **Шаг 7: Сборка и тесты**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Шаг 8: Проверка в трёх приложениях**

Run: `./Scripts/make-app.sh && open build/NoHands.app`

Продиктовать по фразе в каждое из трёх, одно обязательно с автодополнением — Заметки, Telegram или Slack, и терминал:
- текст появляется в поле, а не где-то ещё;
- прежнее содержимое буфера обмена на месте — проверить `Cmd+V` сразу после диктовки: должно вставиться то, что было скопировано до неё;
- продиктовать, затем **во время** диктовки переключиться в другое окно: текст всё равно уходит в то приложение, в котором диктовка началась.

- [ ] **Шаг 9: Коммит**

```bash
git add Features/Dictation Tests/DictationTests/PasteboardSnapshotTests.swift
git commit -m "Вставка текста: буфер обмена, Cmd+V, возврат прежнего содержимого"
```

---

### Задача 10: Панель

Соответствует задаче 7 спеки. Единственная задача без тестов: панель проверяется глазами, потому что проверять в ней нечего, кроме внешнего вида.

**Files:**
- Create: `App/PanelModel.swift`, `App/PanelView.swift`, `App/DictationPanel.swift`
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `PanelState`, `TargetApp`.
- Produces: `@MainActor final class DictationPanel` с `init()`, `func show(_ state: PanelState)`, `func hide(after: TimeInterval)`, `func setLevel(_ level: Float)`.

- [ ] **Шаг 1: Написать модель и вид**

`App/PanelModel.swift`:

```swift
import AppKit
import Dictation
import SwiftUI

/// What the panel is drawing right now.
@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState?
    /// A short history rather than one number: a single bar jumping around reads as noise,
    /// while a row of recent levels reads as a voice.
    @Published var levels: [Float] = Array(repeating: 0, count: 32)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 32)
    }
}
```

`App/PanelView.swift`:

```swift
import AppKit
import Dictation
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            if let target = target {
                icon(for: target)
                Text(target.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

            if case .recording = model.state {
                Levels(values: model.levels)
                if case .recording(_, true) = model.state {
                    Text("фиксация")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 520)
    }

    private var target: TargetApp? {
        switch model.state {
        case .recording(let target, _), .transcribing(let target),
             .cleaning(let target), .inserting(let target, _):
            return target
        case .failure, nil:
            return nil
        }
    }

    private var isFailure: Bool {
        if case .failure = model.state { return true }
        return false
    }

    private var caption: String {
        switch model.state {
        case .transcribing: return "распознаю"
        case .cleaning: return "чищу"
        case .inserting(_, let skipped):
            guard let skipped else { return "вставляю" }
            return "вставляю без чистки: \(skipped)"
        case .failure(let message): return message
        case .recording, nil: return ""
        }
    }

    private func icon(for target: TargetApp) -> some View {
        let image = target.bundleIdentifier
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }?
            .icon
        return Group {
            if let image {
                Image(nsImage: image).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
        }
    }
}

/// The live level while recording. No honest progress exists for the stages after it — neither
/// recognition nor a single API call reports any — so those get a caption instead of a bar
/// that would be pretending.
private struct Levels: View {
    let values: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(3, CGFloat(value) * 22))
            }
        }
        .frame(height: 22)
    }
}
```

- [ ] **Шаг 2: Написать окно**

`App/DictationPanel.swift`:

```swift
import AppKit
import Dictation
import SwiftUI

/// The floating strip above the Dock.
///
/// `.nonactivatingPanel` and refusing key status are not decoration: a panel that can become
/// key steals the focus, and the dictated text lands in the panel instead of the field the
/// owner was aiming at.
@MainActor
final class DictationPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let model = PanelModel()
    private let panel: Panel
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PanelView(model: model))
    }

    func show(_ state: PanelState) {
        pendingHide?.cancel()
        pendingHide = nil
        if case .recording = state, model.state == nil {
            model.resetLevels()
        }
        model.state = state
        position()
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.model.state = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setLevel(_ level: Float) {
        model.push(level: level)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 24
            )
        )
    }
}
```

- [ ] **Шаг 3: Подключить панель**

`App/AppDelegate.swift` — завести панель и передать её замыкания координатору:

```swift
    private let panel = DictationPanel()
```

```swift
                showPanel: { [panel] state in panel.show(state) },
                hidePanel: { [panel] delay in panel.hide(after: delay) },
                onLevel: { [panel] level in panel.setLevel(level) }
```

- [ ] **Шаг 4: Сборка и тесты**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Шаг 5: Проверить глазами**

Run: `./Scripts/make-app.sh && open build/NoHands.app`

Expected по пунктам:
- Быстрое касание fn — панель не появляется вовсе.
- Удержание дольше 0,3 с — панель снизу по центру: иконка и имя приложения, в которое пойдёт текст, живые полоски уровня.
- Панель **не забирает фокус**: курсор остаётся мигать в текстовом поле, набор с клавиатуры продолжает идти туда же.
- Пробел при зажатой fn — появляется подпись «фиксация».
- После отпускания fn подписи сменяются: «распознаю», «чищу», «вставляю», затем панель уходит.
- Без сети — «вставляю без чистки: …» с причиной.
- Отключить микрофон и продиктовать — красная строка с причиной, гаснет через три секунды.

- [ ] **Шаг 6: Коммит**

```bash
git add App
git commit -m "Плавающая панель: получатель, уровень звука, стадия, отказ"
```

---

### Задача 11: Задел под правку слов

Соответствует задаче 8 спеки. Самого окна правки в фазе 1 нет — есть то, без чего его потом не сделать: последняя диктовка целиком, чтобы в момент «оно опять сломало это слово» было что разбирать. Ничего не пишется на диск сверх того временного wav, который и так был записан, и ничего не логируется.

**Files:**
- Create: `Features/Dictation/LastDictation.swift`
- Modify: `Features/Dictation/DictationMachine.swift`, `Features/Dictation/DictationCoordinator.swift`, `Tests/DictationTests/DictationMachineTests.swift`
- Test: `Tests/DictationTests/LastDictationTests.swift`

**Interfaces:**
- Produces: `public actor LastDictation { struct Entry: Equatable, Sendable { let audio: URL; let raw: String; let cleaned: String? }; func remember(_ entry: Entry); func current() -> Entry? }`; новый случай `DictationMachine.Effect.remember(raw: String, cleaned: String?)`.

- [ ] **Шаг 1: Написать падающие тесты хранилища**

`Tests/DictationTests/LastDictationTests.swift`:

```swift
import Foundation
import Testing
@testable import Dictation

private func scratchFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-last-\(UUID().uuidString).wav")
    try Data([0]).write(to: url)
    return url
}

@Test func nothingIsRememberedAtFirst() async {
    #expect(await LastDictation().current() == nil)
}

@Test func theLastEntryIsReturned() async throws {
    let store = LastDictation()
    let audio = try scratchFile()
    defer { try? FileManager.default.removeItem(at: audio) }

    await store.remember(LastDictation.Entry(audio: audio, raw: "эээ привет", cleaned: "Привет."))
    let current = await store.current()
    #expect(current?.raw == "эээ привет")
    #expect(current?.cleaned == "Привет.")
}

// Exactly one recording is kept. Keeping more would grow without bound on a 256 GB disk, and
// keeping none would leave nothing to examine when a word comes out wrong.
@Test func rememberingAgainDeletesThePreviousAudio() async throws {
    let store = LastDictation()
    let first = try scratchFile()
    let second = try scratchFile()
    defer { try? FileManager.default.removeItem(at: second) }

    await store.remember(LastDictation.Entry(audio: first, raw: "один", cleaned: nil))
    await store.remember(LastDictation.Entry(audio: second, raw: "два", cleaned: nil))

    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(await store.current()?.raw == "два")
}

@Test func aDictationWithoutCleanupIsStillRemembered() async throws {
    let store = LastDictation()
    let audio = try scratchFile()
    defer { try? FileManager.default.removeItem(at: audio) }

    await store.remember(LastDictation.Entry(audio: audio, raw: "сырой", cleaned: nil))
    #expect(await store.current()?.cleaned == nil)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter LastDictation`
Expected: FAIL — `cannot find 'LastDictation' in scope`

- [ ] **Шаг 3: Реализовать хранилище**

`Features/Dictation/LastDictation.swift`:

```swift
import Foundation

/// The most recent dictation, kept in memory until the next one replaces it.
///
/// A word only reveals itself as misheard when the text is already in the field, and by then
/// there is nothing left to look at: cleanup cannot repair a name it has never seen, so the
/// difference between raw and cleaned text does not point at those cases either. Keeping the
/// last recording and both versions of its text is what makes a later correction window
/// possible at all — the window itself is deliberately not part of phase 1.
///
/// One recording, never two: a growing pile of audio on a 256 GB disk is the failure mode this
/// is guarding against.
public actor LastDictation {
    public struct Entry: Equatable, Sendable {
        public let audio: URL
        public let raw: String
        public let cleaned: String?

        public init(audio: URL, raw: String, cleaned: String?) {
            self.audio = audio
            self.raw = raw
            self.cleaned = cleaned
        }
    }

    private var entry: Entry?

    public init() {}

    public func remember(_ entry: Entry) {
        if let previous = self.entry, previous.audio != entry.audio {
            try? FileManager.default.removeItem(at: previous.audio)
        }
        self.entry = entry
    }

    public func current() -> Entry? {
        entry
    }
}
```

- [ ] **Шаг 4: Тесты хранилища проходят**

Run: `swift test --filter LastDictation`
Expected: PASS, четыре теста

- [ ] **Шаг 5: Добавить эффект в автомат — сначала тесты**

В `Tests/DictationTests/DictationMachineTests.swift` заменить два теста и добавить один. Оба заменяемых теста перечисляют полный список эффектов, поэтому появление нового ломает их — это и требуется.

```swift
@Test func cleanedTextIsInserted() {
    var subject = cleaning()
    let effects = subject.handle(.cleaned("Привет."))
    #expect(effects == [
        .remember(raw: "эээ привет", cleaned: "Привет."),
        .show(.inserting(target: target, cleanupSkipped: nil)),
        .insert(text: "Привет.", into: target, cleaned: true),
    ])
}

@Test func failedCleanupInsertsTheRawTextAndSaysSo() {
    var subject = cleaning()
    let effects = subject.handle(.cleanupFailed("offline"))
    #expect(effects == [
        .play(.error),
        .remember(raw: "эээ привет", cleaned: nil),
        .show(.inserting(target: target, cleanupSkipped: "offline")),
        .insert(text: "эээ привет", into: target, cleaned: false),
    ])
}

// A dictation that never reached cleanup has nothing worth keeping: the audio is thrown away
// with it, so a failed recognition cannot leave a file behind.
@Test func aFailedRecognitionRemembersNothing() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(2)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    let effects = subject.handle(.transcriptionFailed("Transcription returned no text"))
    #expect(!effects.contains { if case .remember = $0 { return true } else { return false } })
}
```

- [ ] **Шаг 6: Убедиться, что тесты падают**

Run: `swift test --filter DictationMachine`
Expected: FAIL — `type 'DictationMachine.Effect' has no member 'remember'`

- [ ] **Шаг 7: Добавить эффект**

`Features/Dictation/DictationMachine.swift` — в `Effect`:

```swift
        /// Hand the finished dictation to `LastDictation`, which also takes ownership of the
        /// audio file. Emitted only once cleanup has run one way or the other: earlier than
        /// that there is no text worth keeping.
        case remember(raw: String, cleaned: String?)
```

и в двух ветках `handle`:

```swift
        case (.cleaning(let raw, let target), .cleaned(let text)):
            state = .inserting(target: target, cleanupSkipped: nil)
            return [
                .remember(raw: raw, cleaned: text),
                .show(.inserting(target: target, cleanupSkipped: nil)),
                .insert(text: text, into: target, cleaned: true),
            ]

        case (.cleaning(let raw, let target), .cleanupFailed(let message)):
            state = .inserting(target: target, cleanupSkipped: message)
            return [
                .play(.error),
                .remember(raw: raw, cleaned: nil),
                .show(.inserting(target: target, cleanupSkipped: message)),
                .insert(text: raw, into: target, cleaned: false),
            ]
```

- [ ] **Шаг 8: Тесты автомата проходят**

Run: `swift test --filter DictationMachine`
Expected: PASS, двадцать четыре теста

- [ ] **Шаг 9: Подключить в координаторе**

`Features/Dictation/DictationCoordinator.swift`:

```swift
    private let lastDictation = LastDictation()
```

новая ветка в `perform`, и ветка `.insert` больше не удаляет файл — им теперь владеет хранилище:

```swift
        case .remember(let raw, let cleaned):
            guard let audio = audioURL else { break }
            audioURL = nil
            Task { [lastDictation] in
                await lastDictation.remember(
                    LastDictation.Entry(audio: audio, raw: raw, cleaned: cleaned)
                )
            }

        case .insert(let text, let target, _):
            run { [inserter] in
                do {
                    try await inserter.insert(text, into: target)
                    return .inserted
                } catch {
                    return .insertionFailed(error.localizedDescription)
                }
            }
```

Остальные пути — отмена, отказ записи, отказ распознавания — по-прежнему зовут `discardAudioFile()`: там нечего запоминать, и файл не должен остаться.

- [ ] **Шаг 10: Сборка и весь набор тестов**

Run: `swift build && swift test`
Expected: PASS

- [ ] **Шаг 11: Проверить, что файлы не копятся**

Run: `ls /tmp/nohands-dictation-*.wav | wc -l` после пяти диктовок подряд и одной отменённой по Esc.
Expected: ровно один файл — последняя диктовка. Отменённая не оставила ничего.

- [ ] **Шаг 12: Коммит**

```bash
git add Features/Dictation Tests/DictationTests
git commit -m "Последняя диктовка живёт в памяти: задел под правку слов"
```

---

## Приёмка фазы

После задачи 11 — не следующая задача, а несколько дней настоящей работы. Список правок после этого будет полезнее любого планирования наперёд, и именно ради него фаза устроена так.

Что проверить до того, как считать фазу закрытой:

- [ ] Подписка VoiceOS отменена — то, ради чего всё затевалось
- [ ] Замерена настоящая задержка на коротких и длинных фразах; если она сильно расходится с 2,4 с из фазы 0, это запись в журнал решений
- [ ] Проверено фактическое списание у DeepSeek за неделю против сметы в $0,40 в месяц. Ошибка такого рода не видна ни в коде, ни в качестве — только в счёте, и фаза 0 уже один раз на этом обожглась
- [ ] Собран список слов, которые распознавание портит регулярно, — материал для решения об окне правки
- [ ] `docs/ARCHITECTURE.md` приведён в соответствие: раздел про Xcode-проект, состояние фаз, известные расхождения
- [ ] Записи в `docs/DECISIONS.md` о том, что показала настоящая работа

---
