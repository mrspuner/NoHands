# Фаза 2а — захват созвонов. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Приложение само замечает начало созвона, пишет две дорожки одним потоком и кладёт в `~/Meetings/.queue/` папку на встречу, готовую для фазы 2б.

**Architecture:** Тот же слоёный порядок, что в фазе 1. Правила живут в чистом автомате `MeetingMachine` — ни одного системного вызова, всё поведение проверяется тестами. Системные умения живут в `Core/Audio`: `AudioProcessMonitor` отвечает на вопрос «кто держит вход и выход», `MeetingAudioRecorder` пишет обе дорожки одним `SCStream`. `MeetingCoordinator` только исполняет то, что решил автомат. Слова интерфейса — в таргете `App`.

**Tech Stack:** Swift 6, swift-testing (`import Testing`, `@Test`, `#expect`), ScreenCaptureKit, CoreAudio, AVFoundation. Новых зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-09-03-phase2a-capture-design.md`

## Global Constraints

- Платформа пакета поднимается с `.macOS(.v14)` на `.macOS(.v15)`: `SCStreamConfiguration.captureMicrophone` появился в macOS 15
- Новых зависимостей не добавляем. Единственная внешняя — FluidAudio, закреплённая на `.exact("0.14.8")`
- Общение, документация и коммиты — по-русски. Идентификаторы, комментарии в коде и сообщения об ошибках — по-английски
- Тест раньше кода. Каждая задача заканчивается зелёным `swift test` и коммитом
- Не логировать содержимое транскриптов и распознанного текста. В фазе 2а распознавания нет, но и имена участников, и заголовки окон под тем же правилом
- Ни одного молчаливого фолбэка: любой отказ называется в панели
- Формат дорожек: 16 кГц, моно, WAV, обе
- Пороги из конфига: `silenceSeconds` 60, `autoStopSeconds` 120, `startPromptSeconds` 30, `maxMeetingSeconds` 14400
- Молчание никогда не удаляет запись. Удаляет только явное «нет» или «удалить»
- Запуск тестов: `swift test`. Сборка бандла: `Scripts/make-app.sh`

---

## Карта файлов

**Создаются:**

| Файл | За что отвечает |
|---|---|
| `Features/Meetings/MeetingsConfig.swift` | Объект `meetings` в `config.json`: два списка, четыре порога |
| `Features/Meetings/MeetingMachine.swift` | Все правила записи встречи как чистая функция состояния и события |
| `Features/Meetings/MeetingPanelState.swift` | Что показывает панель во время встречи. Структура без слов |
| `Features/Meetings/MeetingMetadata.swift` | `meeting.json`: чтение и запись |
| `Features/Meetings/MeetingFolder.swift` | Имена папок, коллизии, атомарное переименование, поиск черновиков |
| `Features/Meetings/MeetingWatcher.swift` | Мост от списка процессов к событиям автомата: кто из списка триггеров занял устройства |
| `Features/Meetings/MeetingCoordinator.swift` | Исполняет эффекты автомата, держит таймер, владеет папкой текущей записи |
| `Core/Audio/AudioProcessMonitor.swift` | CoreAudio: какие процессы держат вход и выход прямо сейчас |
| `Core/Audio/MeetingAudioRecorder.swift` | `SCStream` на обе дорожки, сведение в 16 кГц моно, два WAV |
| `Core/Audio/WavHeaderRepair.swift` | Починка заголовка WAV, оставшегося от упавшего приложения |
| `Tests/MeetingsTests/*.swift` | Тесты всего перечисленного, кроме системных умений |

**Изменяются:**

| Файл | Что меняется |
|---|---|
| `Package.swift` | Платформа `.v15`, таргеты `Meetings` и `MeetingsTests`, зависимость `App` от `Meetings` |
| `App/AppDelegate.swift` | Создание координатора встреч, связывание с панелью и меню |
| `App/StatusMenu.swift` | Пункты «Записать созвон», «Остановить запись», «Разрешить запись экрана…» |
| `App/PanelModel.swift`, `App/PanelView.swift`, `App/DictationPanel.swift` | Состояния встречи, кнопки, включение и выключение приёма мыши |
| `App/Info.plist` | `NSScreenCaptureUsageDescription` |
| `Features/Dictation/DictationCoordinator.swift` | Отказ начинать диктовку, пока идёт запись встречи |

**Границы.** `Core` отвечает на вопросы «кто держит устройства» и «запиши обе дорожки» и ничего не знает про встречи. `Meetings` знает правила и не делает ни одного системного вызова, кроме файловых операций в `MeetingFolder`. `App` знает слова и рисует.

---

## Task 0: Спайк — CoreAudio и микрофон в SCStream

Выбрасываемый. Проверяет три предположения, на которых стоит вся фаза. Код в репозиторий не попадает, результат — запись в журнале решений.

**Files:**
- Create (вне репозитория): `<scratchpad>/probe-audio-processes.swift`, `<scratchpad>/probe-scstream.swift`

**Interfaces:**
- Consumes: ничего
- Produces: ответы на три вопроса, от которых зависят задачи 5 и 6

- [ ] **Step 1: Написать пробу списка процессов**

```swift
// probe-audio-processes.swift — throwaway
import CoreAudio
import Foundation
import AppKit

func processObjects() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }
    return ids
}

func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
        return false
    }
    return value != 0
}

func pid(_ object: AudioObjectID) -> pid_t {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return value
}

while true {
    for object in processObjects() {
        let id = pid(object)
        let app = NSRunningApplication(processIdentifier: id)
        let input = flag(object, kAudioProcessPropertyIsRunningInput)
        let output = flag(object, kAudioProcessPropertyIsRunningOutput)
        guard input || output else { continue }
        print("\(Date()) \(app?.bundleIdentifier ?? "pid \(id)") вход=\(input) выход=\(output)")
    }
    print("---")
    Thread.sleep(forTimeInterval: 1)
}
```

- [ ] **Step 2: Собрать и запустить пробу**

```bash
cd "<scratchpad>"
swiftc -o probe-processes probe-audio-processes.swift && ./probe-processes
```

Ожидаемое: строки с идентификаторами бандлов и двумя флагами. Если константы `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput` не компилируются — это и есть ответ спайка: раздельных признаков по процессам нет, дальше идём запасным путём из раздела 3 спеки.

- [ ] **Step 3: Проверить мьют на живой встрече**

Запустить Телемост, войти в комнату, снять и поставить мьют несколько раз, не выходя из встречи. Затем выйти из встречи. Повторить с Zoom.

Записать в блокнот: что происходит с `вход` и `выход` при мьюте и при выходе. Ожидание, на котором стоит спека: мьют убирает `вход`, оставляя `выход`; выход из встречи убирает оба.

- [ ] **Step 4: Написать пробу SCStream с микрофоном**

```swift
// probe-scstream.swift — throwaway
import AVFoundation
import Foundation
import ScreenCaptureKit

final class Sink: NSObject, SCStreamOutput {
    var systemSamples = 0
    var micSamples = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: systemSamples += CMSampleBufferGetNumSamples(buffer)
        case .microphone: micSamples += CMSampleBufferGetNumSamples(buffer)
        default: break
        }
    }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let display = content.displays[0]
let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = true
config.captureMicrophone = true
config.sampleRate = 48000
config.channelCount = 2

let sink = Sink()
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: .global())
try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: .global())
try await stream.startCapture()
try await Task.sleep(for: .seconds(10))
try await stream.stopCapture()
print("система: \(sink.systemSamples), микрофон: \(sink.micSamples)")
```

- [ ] **Step 5: Собрать, запустить, поговорить в микрофон при играющем звуке**

```bash
cd "<scratchpad>"
swiftc -parse-as-library -o probe-scstream probe-scstream.swift && ./probe-scstream
```

Ожидаемое: оба счётчика больше нуля, то есть потоки приходят раздельно. Разрешение на запись экрана спросит терминал — это разрешение терминала, а не `NoHands.app`, и на задачу 4 не влияет.

- [ ] **Step 6: Записать результат в журнал решений**

Дописать в `docs/DECISIONS.md` запись «2026-09-0X — Результаты спайка перед фазой 2а»: что отдаёт CoreAudio, что делает мьют в Телемосте и Zoom, приходят ли два потока раздельно. Если хоть одно предположение не подтвердилось — прямо назвать, какой раздел спеки это меняет.

```bash
git add docs/DECISIONS.md
git commit -m "Журнал решений: результаты спайка перед фазой 2а"
git push
```

Код проб не коммитить.

---

## Task 1: Таргет `Meetings`, платформа macOS 15, конфиг

**Files:**
- Modify: `Package.swift`
- Create: `Features/Meetings/MeetingsConfig.swift`
- Test: `Tests/MeetingsTests/MeetingsConfigTests.swift`

**Interfaces:**
- Consumes: `DictationConfig.fileURL` из таргета `Dictation`
- Produces: `MeetingsConfig` со свойствами `triggerApps: [MeetingsConfig.TriggerApp]`, `excludedApps: [String]`, `silenceSeconds: Double`, `autoStopSeconds: Double`, `startPromptSeconds: Double`, `maxMeetingSeconds: Double`; `TriggerApp` со свойствами `bundleID: String`, `slug: String?` и вычисляемым `resolvedSlug: String`; `MeetingsConfig.default`; `MeetingsConfig.loadOrCreate(at:) throws -> MeetingsConfig`

- [ ] **Step 1: Добавить таргеты и поднять платформу**

В `Package.swift`: заменить `platforms: [.macOS(.v14)]` на `platforms: [.macOS(.v15)]`, добавить в `products` библиотеку `Meetings`, добавить таргеты:

```swift
.target(
    name: "Meetings",
    dependencies: ["Core"],
    path: "Features/Meetings"
),
.testTarget(
    name: "MeetingsTests",
    dependencies: ["Meetings"],
    path: "Tests/MeetingsTests"
),
```

и добавить `"Meetings"` в зависимости таргета `App`.

- [ ] **Step 2: Написать падающие тесты конфига**

```swift
// Tests/MeetingsTests/MeetingsConfigTests.swift
import Foundation
import Testing
@testable import Meetings

@Test func defaultsFillEveryMissingKey() throws {
    let config = try MeetingsConfig.decode(Data("{}".utf8))
    #expect(config == MeetingsConfig.default)
}

@Test func triggerAppsAreReadWithTheirSlugs() throws {
    let json = """
    { "triggerApps": [{ "bundleId": "ru.yandex.telemost", "slug": "telemost" }] }
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.triggerApps.count == 1)
    #expect(config.triggerApps[0].bundleID == "ru.yandex.telemost")
    #expect(config.triggerApps[0].resolvedSlug == "telemost")
}

// Слаг необязателен: без него берётся последний компонент идентификатора бандла, чтобы
// добавление приложения стоило одной строки.
@Test func aMissingSlugFallsBackToTheLastComponentOfTheBundleID() throws {
    let json = """
    { "triggerApps": [{ "bundleId": "ru.yandex.Telemost" }] }
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.triggerApps[0].resolvedSlug == "telemost")
}

@Test func thresholdsAreReadAndTheRestKeepDefaults() throws {
    let config = try MeetingsConfig.decode(Data("""
    { "silenceSeconds": 90 }
    """.utf8))
    #expect(config.silenceSeconds == 90)
    #expect(config.autoStopSeconds == MeetingsConfig.default.autoStopSeconds)
}
```

- [ ] **Step 3: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingsConfigTests`
Expected: FAIL — `cannot find 'MeetingsConfig' in scope`

- [ ] **Step 4: Написать `MeetingsConfig`**

```swift
// Features/Meetings/MeetingsConfig.swift
import Foundation

/// The `meetings` object inside the same `config.json` the dictation settings live in.
///
/// Every key is optional on read and falls back to the default: the file is edited by hand,
/// and a missing line must not stop the app. Two lists that are easy to confuse live here —
/// `triggerApps` decides when a recording starts, `excludedApps` decides whose audio is not
/// written at all.
public struct MeetingsConfig: Equatable, Sendable, Codable {
    public struct TriggerApp: Equatable, Sendable, Codable {
        public var bundleID: String
        /// Goes into the folder name. Optional because the last component of the bundle
        /// identifier is a usable slug for most applications.
        public var slug: String?

        public var resolvedSlug: String {
            if let slug, !slug.isEmpty { return slug }
            return bundleID.split(separator: ".").last.map { $0.lowercased() } ?? bundleID
        }

        public init(bundleID: String, slug: String? = nil) {
            self.bundleID = bundleID
            self.slug = slug
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case slug
        }
    }

    public var triggerApps: [TriggerApp]
    public var excludedApps: [String]
    public var silenceSeconds: Double
    public var autoStopSeconds: Double
    public var startPromptSeconds: Double
    public var maxMeetingSeconds: Double

    public static let `default` = MeetingsConfig(
        triggerApps: [
            TriggerApp(bundleID: "ru.yandex.telemost", slug: "telemost"),
            TriggerApp(bundleID: "us.zoom.xos", slug: "zoom"),
        ],
        excludedApps: [],
        silenceSeconds: 60,
        autoStopSeconds: 120,
        startPromptSeconds: 30,
        maxMeetingSeconds: 14400
    )

    public init(
        triggerApps: [TriggerApp],
        excludedApps: [String],
        silenceSeconds: Double,
        autoStopSeconds: Double,
        startPromptSeconds: Double,
        maxMeetingSeconds: Double
    ) {
        self.triggerApps = triggerApps
        self.excludedApps = excludedApps
        self.silenceSeconds = silenceSeconds
        self.autoStopSeconds = autoStopSeconds
        self.startPromptSeconds = startPromptSeconds
        self.maxMeetingSeconds = maxMeetingSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MeetingsConfig.default
        triggerApps = try container.decodeIfPresent([TriggerApp].self, forKey: .triggerApps)
            ?? fallback.triggerApps
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps)
            ?? fallback.excludedApps
        silenceSeconds = try container.decodeIfPresent(Double.self, forKey: .silenceSeconds)
            ?? fallback.silenceSeconds
        autoStopSeconds = try container.decodeIfPresent(Double.self, forKey: .autoStopSeconds)
            ?? fallback.autoStopSeconds
        startPromptSeconds = try container.decodeIfPresent(Double.self, forKey: .startPromptSeconds)
            ?? fallback.startPromptSeconds
        maxMeetingSeconds = try container.decodeIfPresent(Double.self, forKey: .maxMeetingSeconds)
            ?? fallback.maxMeetingSeconds
    }

    public static func decode(_ data: Data) throws -> MeetingsConfig {
        try JSONDecoder().decode(MeetingsConfig.self, from: data)
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter MeetingsConfigTests`
Expected: PASS

- [ ] **Step 6: Написать падающий тест на чтение из общего файла**

```swift
// в тот же файл тестов
@Test func theMeetingsObjectIsReadFromTheSharedConfigFileWithoutTouchingDictationKeys() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    try Data("""
    { "language": "ru", "meetings": { "silenceSeconds": 45 } }
    """.utf8).write(to: url)

    let config = try MeetingsConfig.loadOrCreate(at: url)
    #expect(config.silenceSeconds == 45)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["language"] as? String == "ru")
}

// Первый запуск должен оставить владельцу полный файл: иначе имена ключей придётся вспоминать.
// Ключи диктовки при этом обязаны уцелеть — секция дописывается в разобранный объект, а не
// поверх файла целиком.
@Test func aMissingMeetingsObjectIsWrittenInAndOtherKeysSurvive() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    try Data(#"{ "language": "ru", "model": "deepseek-chat" }"#.utf8).write(to: url)

    let config = try MeetingsConfig.loadOrCreate(at: url)
    #expect(config == MeetingsConfig.default)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["model"] as? String == "deepseek-chat")
    #expect(raw?["meetings"] != nil)
}
```

- [ ] **Step 7: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingsConfigTests`
Expected: FAIL — `type 'MeetingsConfig' has no member 'loadOrCreate'`

- [ ] **Step 8: Реализовать `loadOrCreate`**

```swift
// в MeetingsConfig.swift
extension MeetingsConfig {
    /// Reads the `meetings` object out of the shared config file, writing the defaults into it
    /// when the key is absent.
    ///
    /// Works on the parsed JSON dictionary rather than on a typed root: the dictation settings
    /// live in the same file under their own keys, and re-encoding a typed root would drop
    /// every key that root does not know about.
    public static func loadOrCreate(at url: URL = DictationConfigFileURL) throws -> MeetingsConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingsConfigError.notAnObject(url.path)
        }
        if let section = root["meetings"] {
            let sectionData = try JSONSerialization.data(withJSONObject: section)
            return try decode(sectionData)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let defaults = try JSONSerialization.jsonObject(with: encoder.encode(MeetingsConfig.default))
        root["meetings"] = defaults
        let merged = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try merged.write(to: url)
        return .default
    }
}

public enum MeetingsConfigError: Error, Equatable {
    case notAnObject(String)
}
```

`DictationConfigFileURL` — вычисляемая константа в том же файле, чтобы `Meetings` не зависел от таргета `Dictation`:

```swift
/// The same file the dictation settings live in. Duplicated here rather than imported: the
/// two features share a file, not a module, and a dependency from `Meetings` to `Dictation`
/// would exist for one URL.
public var DictationConfigFileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
}
```

- [ ] **Step 9: Прогнать все тесты**

Run: `swift test`
Expected: PASS, включая 178 тестов фаз 0 и 1

- [ ] **Step 10: Коммит**

```bash
git add Package.swift Features/Meetings Tests/MeetingsTests
git commit -m "Таргет Meetings и конфиг встреч: два списка и четыре порога"
```

---

## Task 2: Автомат — старт, подтверждение, отказ, ручной стоп

**Files:**
- Create: `Features/Meetings/MeetingMachine.swift`, `Features/Meetings/MeetingPanelState.swift`
- Test: `Tests/MeetingsTests/MeetingMachineTests.swift`

**Interfaces:**
- Consumes: `MeetingsConfig` из задачи 1
- Produces: `MeetingMachine` с `init(limits:)`, `state: State`, `mutating func handle(_ event: Event) -> [Effect]`; типы `MeetingMachine.Limits(silence:autoStop:startPrompt:maxMeeting:)`, `MeetingMachine.MeetingApp(bundleID:name:slug:pid:)`, `State`, `Event`, `Effect`; `MeetingPanelState`

- [ ] **Step 1: Написать состояния панели**

```swift
// Features/Meetings/MeetingPanelState.swift
import Foundation

/// What the panel shows while a meeting is being recorded. Structure only — no wording: the
/// interface speaks Russian and that belongs to the `App` target.
///
/// `acceptsClicks` is the whole reason this is an enum and not a pair of booleans: the panel
/// stays deaf to the mouse except while a prompt is up, and the rule for which states those
/// are must be testable without a window.
public enum MeetingPanelState: Equatable, Sendable {
    case startPrompt(appName: String)
    /// `confirmed` is false while the recording is still a draft nobody has answered for.
    case recording(since: Date, confirmed: Bool)
    case stopPrompt(duration: TimeInterval)
    case savePrompt(duration: TimeInterval)
    case orphanFound(duration: TimeInterval)
    case limitReached
    case failure(String)

    public var acceptsClicks: Bool {
        switch self {
        case .startPrompt, .stopPrompt, .savePrompt, .orphanFound: true
        case .recording, .limitReached, .failure: false
        }
    }
}
```

- [ ] **Step 2: Написать падающие тесты старта и отказа**

```swift
// Tests/MeetingsTests/MeetingMachineTests.swift
import Foundation
import Testing
@testable import Meetings

private let start = Date(timeIntervalSince1970: 1_000_000)

private let telemost = MeetingMachine.MeetingApp(
    bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost", pid: 501
)

private func machine() -> MeetingMachine {
    MeetingMachine(limits: MeetingMachine.Limits(
        silence: 60, autoStop: 120, startPrompt: 30, maxMeeting: 14400
    ))
}

/// Drives a machine to a draft that is already recording — the state most tests start from.
private func drafting() -> MeetingMachine {
    var subject = machine()
    _ = subject.handle(.streamsChanged(app: telemost, input: true, output: true, at: start))
    return subject
}

@Test func aTriggerAppTakingTheInputStartsADraftAndAsks() {
    var subject = machine()
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: false, at: start)
    )
    #expect(effects == [
        .startCapture(app: telemost, at: start),
        .blockDictation(true),
        .show(.startPrompt(appName: "Телемост")),
    ])
}

// Черновик пишется с первой секунды: полминуты, пока человек читает подсказку, — это те
// полминуты, где договариваются о повестке.
@Test func theDraftIsAlreadyRecordingBeforeAnyoneAnswered() {
    let subject = drafting()
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: false, promptShown: true, quietSince: nil))
}

@Test func confirmingCollapsesThePromptAndKeepsRecording() {
    var subject = drafting()
    let effects = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
    #expect(effects == [.show(.recording(since: start, confirmed: true))])
}

@Test func decliningDeletesTheDraftImmediately() {
    var subject = drafting()
    let effects = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    #expect(effects == [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)])
    #expect(subject.state == .declined(pid: 501))
}

// Отказ помнится до освобождения устройств, иначе одна встреча спросит десять раз.
@Test func aDeclinedMeetingIsNotAskedAboutAgainWhileItHoldsTheDevices() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: true, at: start.addingTimeInterval(10))
    )
    #expect(effects == [])
}

@Test func releasingTheDevicesForgetsTheDecline() {
    var subject = drafting()
    _ = subject.handle(.declinePressed(at: start.addingTimeInterval(5)))
    _ = subject.handle(
        .streamsChanged(app: telemost, input: false, output: false, at: start.addingTimeInterval(10))
    )
    #expect(subject.state == .idle)
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: true, output: false, at: start.addingTimeInterval(20))
    )
    #expect(effects.first == .startCapture(app: telemost, at: start.addingTimeInterval(20)))
}

@Test func stoppingAConfirmedRecordingByHandSavesItWithoutAsking() {
    var subject = drafting()
    _ = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
    let effects = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(effects == [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)])
    #expect(subject.state == .idle)
}

// Ручной стоп неподтверждённого черновика закрывает файлы и спрашивает: запись уже кончилась,
// продолжать её ради вопроса незачем.
@Test func stoppingADraftByHandClosesTheFilesAndAsksWhetherToKeepThem() {
    var subject = drafting()
    let effects = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(effects == [.stopCapture, .blockDictation(false), .show(.savePrompt(duration: 600))])
    #expect(subject.state == .savePending(since: start, stoppedAt: start.addingTimeInterval(600)))
}

@Test func savingFromTheSavePromptPromotesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.keepPressed) == [.keepDraft, .hide(after: 0)])
    #expect(subject.state == .idle)
}

@Test func deletingFromTheSavePromptRemovesTheFolder() {
    var subject = drafting()
    _ = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(subject.handle(.deletePressed) == [.discardDraft, .hide(after: 0)])
    #expect(subject.state == .idle)
}

// Ручной старт вне встречи: приложения нет, автостопа не будет, слаг папки — manual.
@Test func aManualStartWithNoMeetingAppRecordsWithoutAnAppAndWithoutAPrompt() {
    var subject = machine()
    let effects = subject.handle(.startPressed(app: nil, at: start))
    #expect(effects == [
        .startCapture(app: nil, at: start),
        .blockDictation(true),
        .show(.recording(since: start, confirmed: true)),
    ])
}

@Test func aFailedCaptureReportsAndReturnsToIdle() {
    var subject = drafting()
    let effects = subject.handle(.captureFailed("нет разрешения на запись экрана"))
    #expect(effects == [
        .discardDraft,
        .blockDictation(false),
        .show(.failure("нет разрешения на запись экрана")),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}
```

- [ ] **Step 3: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingMachineTests`
Expected: FAIL — `cannot find 'MeetingMachine' in scope`

- [ ] **Step 4: Написать автомат в объёме этих тестов**

```swift
// Features/Meetings/MeetingMachine.swift
import Foundation

/// Everything meeting recording does, as a pure function of state and event.
///
/// Not one system call lives here: no CoreAudio, no ScreenCaptureKit, no file system, no
/// window. Events come in, a list of effects goes out, and the coordinator performs them.
///
/// Two rules run through the whole type and explain most of its shape:
/// - the draft records from the first second, before anybody answered, because the opening
///   minutes of a meeting are the ones worth having;
/// - silence never deletes. Only an explicit refusal does.
public struct MeetingMachine: Sendable {
    public struct Limits: Equatable, Sendable {
        /// How long both devices stay free before the meeting looks finished.
        public var silence: TimeInterval
        /// How long the stop prompt waits for an answer before saving by itself.
        public var autoStop: TimeInterval
        /// How long the start prompt stays up before collapsing to the marker.
        public var startPrompt: TimeInterval
        /// Hard stop, so a forgotten recording cannot eat the disk.
        public var maxMeeting: TimeInterval

        public init(silence: TimeInterval, autoStop: TimeInterval, startPrompt: TimeInterval, maxMeeting: TimeInterval) {
            self.silence = silence
            self.autoStop = autoStop
            self.startPrompt = startPrompt
            self.maxMeeting = maxMeeting
        }

        public init(config: MeetingsConfig) {
            self.init(
                silence: config.silenceSeconds,
                autoStop: config.autoStopSeconds,
                startPrompt: config.startPromptSeconds,
                maxMeeting: config.maxMeetingSeconds
            )
        }
    }

    /// The meeting application, as the watcher recognised it. `pid` is what makes "the same
    /// meeting" answerable: bundle identifiers repeat across launches, process identifiers do
    /// not.
    public struct MeetingApp: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var slug: String
        public var pid: Int32

        public init(bundleID: String, name: String, slug: String, pid: Int32) {
            self.bundleID = bundleID
            self.name = name
            self.slug = slug
            self.pid = pid
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Recording. `confirmed` decides what happens at the end: a confirmed recording is
        /// saved silently, a draft asks. `quietSince` is when both devices last went free.
        case recording(app: MeetingApp?, since: Date, confirmed: Bool, promptShown: Bool, quietSince: Date?)
        /// Both devices have been free long enough that the meeting looks over. Capture keeps
        /// running: a meeting that comes back to life must not be cut in two.
        case stopOffered(app: MeetingApp?, since: Date, offeredAt: Date)
        /// Capture is stopped, the folder is still a draft, and the answer decides its fate.
        case savePending(since: Date, stoppedAt: Date)
        /// This process was refused. Nothing it does raises a prompt until it lets both
        /// devices go.
        case declined(pid: Int32)
    }

    public enum Event: Equatable, Sendable {
        /// Delivered by the watcher for trigger applications only.
        case streamsChanged(app: MeetingApp, input: Bool, output: Bool, at: Date)
        case appExited(pid: Int32, at: Date)
        case startPressed(app: MeetingApp?, at: Date)
        case stopPressed(at: Date)
        case confirmPressed(at: Date)
        case declinePressed(at: Date)
        case keepPressed
        case deletePressed
        /// Delivered often enough to notice every threshold.
        case tick(Date)
        case captureFailed(String)
    }

    public enum Effect: Equatable, Sendable {
        case startCapture(app: MeetingApp?, at: Date)
        /// Close both files. The folder stays a draft.
        case stopCapture
        /// Rename the draft folder to its final name — the atomic hand-off to phase 2б.
        case keepDraft
        case discardDraft
        case show(MeetingPanelState)
        /// One case rather than two: `hide` and `hide(after:)` would be a redeclaration, and
        /// the dictation machine already spells the immediate case as `after: 0`.
        case hide(after: TimeInterval)
        /// True while a meeting is being recorded: fn must not start a dictation.
        case blockDictation(Bool)
    }

    /// How long a named failure stays on the panel. Not configurable: nothing about it depends
    /// on the owner's habits.
    static let failureDwell: TimeInterval = 5

    public let limits: Limits
    public private(set) var state: State = .idle

    public init(limits: Limits) {
        self.limits = limits
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .streamsChanged(let app, let input, let output, let at)) where input || output:
            state = .recording(app: app, since: at, confirmed: false, promptShown: true, quietSince: nil)
            return [
                .startCapture(app: app, at: at),
                .blockDictation(true),
                .show(.startPrompt(appName: app.name)),
            ]

        case (.idle, .startPressed(let app, let at)):
            state = .recording(app: app, since: at, confirmed: true, promptShown: false, quietSince: nil)
            return [
                .startCapture(app: app, at: at),
                .blockDictation(true),
                .show(.recording(since: at, confirmed: true)),
            ]

        case (.recording(let app, let since, _, _, let quiet), .confirmPressed):
            state = .recording(app: app, since: since, confirmed: true, promptShown: false, quietSince: quiet)
            return [.show(.recording(since: since, confirmed: true))]

        case (.recording(let app, _, _, _, _), .declinePressed):
            state = app.map { State.declined(pid: $0.pid) } ?? .idle
            return [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)]

        case (.recording(_, let since, let confirmed, _, _), .stopPressed(let at)):
            if confirmed {
                state = .idle
                return [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)]
            }
            state = .savePending(since: since, stoppedAt: at)
            return [
                .stopCapture,
                .blockDictation(false),
                .show(.savePrompt(duration: at.timeIntervalSince(since))),
            ]

        case (.savePending, .keepPressed):
            state = .idle
            return [.keepDraft, .hide(after: 0)]

        case (.savePending, .deletePressed):
            state = .idle
            return [.discardDraft, .hide(after: 0)]

        case (.declined(let pid), .streamsChanged(let app, let input, let output, _))
            where app.pid == pid:
            if !input && !output {
                state = .idle
            }
            return []

        case (.recording, .captureFailed(let message)), (.stopOffered, .captureFailed(let message)):
            state = .idle
            return [
                .discardDraft,
                .blockDictation(false),
                .show(.failure(message)),
                .hide(after: Self.failureDwell),
            ]

        default:
            return []
        }
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter MeetingMachineTests`
Expected: PASS

- [ ] **Step 6: Коммит**

```bash
git add Features/Meetings Tests/MeetingsTests
git commit -m "Автомат встречи: черновик, подтверждение, отказ, ручной стоп"
```

---

## Task 3: Автомат — тишина, оживание, автостоп, предел, гашение подсказки

**Files:**
- Modify: `Features/Meetings/MeetingMachine.swift`
- Test: `Tests/MeetingsTests/MeetingMachineTests.swift`

**Interfaces:**
- Consumes: `MeetingMachine` из задачи 2
- Produces: те же типы, обработку `.tick`, `.appExited` и переходы через `.stopOffered`

- [ ] **Step 1: Написать падающие тесты правила конца встречи**

```swift
// в Tests/MeetingsTests/MeetingMachineTests.swift

/// Черновик, которому дали поработать: подсказка погасла, запись идёт.
private func recordingConfirmed() -> MeetingMachine {
    var subject = drafting()
    _ = subject.handle(.confirmPressed(at: start.addingTimeInterval(5)))
    return subject
}

// Мьют отпускает вход и оставляет выход: приложение продолжает проигрывать собеседников.
// Это середина встречи, а не её конец.
@Test func muteReleasesTheInputAndChangesNothing() {
    var subject = recordingConfirmed()
    let effects = subject.handle(
        .streamsChanged(app: telemost, input: false, output: true, at: start.addingTimeInterval(60))
    )
    #expect(effects == [])
    _ = subject.handle(.tick(start.addingTimeInterval(600)))
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: true, promptShown: false, quietSince: nil))
}

@Test func bothDevicesGoingFreeStartsTheSilenceClockButOffersNothingYet() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    #expect(subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet)) == [])
    #expect(subject.handle(.tick(quiet.addingTimeInterval(59))) == [])
}

@Test func silenceLongerThanTheThresholdOffersToStopWhileStillRecording() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let effects = subject.handle(.tick(quiet.addingTimeInterval(61)))
    #expect(effects == [.show(.stopPrompt(duration: 121))])
    #expect(subject.state == .stopOffered(app: telemost, since: start, offeredAt: quiet.addingTimeInterval(61)))
}

// Встреча ожила — предложение снимается, запись продолжается тем же файлом.
@Test func devicesComingBackToLifeWithdrawTheStopPrompt() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    let alive = quiet.addingTimeInterval(70)
    let effects = subject.handle(.streamsChanged(app: telemost, input: true, output: true, at: alive))
    #expect(effects == [.show(.recording(since: start, confirmed: true))])
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: true, promptShown: false, quietSince: nil))
}

@Test func theProcessExitingOffersToStopAtOnce() {
    var subject = recordingConfirmed()
    let effects = subject.handle(.appExited(pid: 501, at: start.addingTimeInterval(600)))
    #expect(effects == [.show(.stopPrompt(duration: 600))])
}

// Молчание сохраняет: подсказку легко не заметить, и невнимательность должна стоить места на
// диске, а не встречи.
@Test func anUnansweredStopPromptSavesTheRecording() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    let effects = subject.handle(.tick(offered.addingTimeInterval(121)))
    #expect(effects == [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)])
    #expect(subject.state == .idle)
}

@Test func answeringTheStopPromptWithKeepSavesImmediately() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    #expect(subject.handle(.keepPressed) == [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)])
}

@Test func answeringTheStopPromptWithDeleteRemovesTheFolder() {
    var subject = recordingConfirmed()
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    _ = subject.handle(.tick(quiet.addingTimeInterval(61)))
    #expect(subject.handle(.deletePressed) == [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)])
}

// Предел длительности останавливает сразу, а не предлагает: он и заведён ради того, чтобы
// забытая запись не съела диск.
@Test func theLengthLimitStopsWithoutAsking() {
    var subject = recordingConfirmed()
    let effects = subject.handle(.tick(start.addingTimeInterval(14400)))
    #expect(effects == [
        .stopCapture,
        .keepDraft,
        .blockDictation(false),
        .show(.limitReached),
        .hide(after: 5),
    ])
    #expect(subject.state == .idle)
}

// Погасшая подсказка старта меняет только вид панели: встреча остаётся черновиком и спросит
// о себе при остановке.
@Test func theStartPromptCollapsesButTheRecordingStaysADraft() {
    var subject = drafting()
    let effects = subject.handle(.tick(start.addingTimeInterval(31)))
    #expect(effects == [.show(.recording(since: start, confirmed: false))])
    #expect(subject.state == .recording(app: telemost, since: start, confirmed: false, promptShown: false, quietSince: nil))
    let stop = subject.handle(.stopPressed(at: start.addingTimeInterval(600)))
    #expect(stop.contains(.show(.savePrompt(duration: 600))))
}

@Test func theStopPromptOfADraftAsksAboutSavingRatherThanSavingSilently() {
    var subject = drafting()
    _ = subject.handle(.tick(start.addingTimeInterval(31)))
    let quiet = start.addingTimeInterval(60)
    _ = subject.handle(.streamsChanged(app: telemost, input: false, output: false, at: quiet))
    let offered = quiet.addingTimeInterval(61)
    _ = subject.handle(.tick(offered))
    #expect(subject.handle(.tick(offered.addingTimeInterval(121))) == [
        .stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0),
    ])
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingMachineTests`
Expected: FAIL — тики и `.appExited` ничего не возвращают, потому что попадают в `default`

- [ ] **Step 3: Дописать обработку в автомат**

Добавить в `handle` перед `default`:

```swift
        case (.recording(let app, let since, let confirmed, let promptShown, let quiet), .streamsChanged(let changed, let input, let output, let at))
            where changed.pid == app?.pid:
            let quietSince = (input || output) ? nil : (quiet ?? at)
            state = .recording(app: app, since: since, confirmed: confirmed, promptShown: promptShown, quietSince: quietSince)
            return []

        case (.stopOffered(let app, let since, _), .streamsChanged(let changed, let input, let output, _))
            where changed.pid == app?.pid && (input || output):
            // A meeting that came back to life must not be cut in two: the same file keeps
            // being written, and only the panel changes back.
            state = .recording(app: app, since: since, confirmed: true, promptShown: false, quietSince: nil)
            return [.show(.recording(since: since, confirmed: true))]

        case (.recording(let app, let since, _, _, let quiet), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit()
            }
            if let quiet, now.timeIntervalSince(quiet) >= limits.silence {
                return offerStop(app: app, since: since, at: now)
            }
            return collapseStartPromptIfDue(now)

        case (.recording(let app, let since, _, _, _), .appExited(let pid, let at)) where pid == app?.pid:
            return offerStop(app: app, since: since, at: at)

        case (.stopOffered(_, let since, let offeredAt), .tick(let now)):
            if now.timeIntervalSince(since) >= limits.maxMeeting {
                return stopAtLimit()
            }
            guard now.timeIntervalSince(offeredAt) >= limits.autoStop else { return [] }
            return keepAndFinish()

        case (.stopOffered, .keepPressed):
            return keepAndFinish()

        case (.stopOffered, .deletePressed):
            state = .idle
            return [.stopCapture, .discardDraft, .blockDictation(false), .hide(after: 0)]

        case (.stopOffered, .stopPressed):
            state = .idle
            return [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)]
```

и приватные помощники:

```swift
    private mutating func offerStop(app: MeetingApp?, since: Date, at now: Date) -> [Effect] {
        state = .stopOffered(app: app, since: since, offeredAt: now)
        return [.show(.stopPrompt(duration: now.timeIntervalSince(since)))]
    }

    /// Silence saves. The draft flag stops mattering here: an unanswered stop prompt is not a
    /// refusal, and the only thing that deletes is an explicit "delete".
    private mutating func keepAndFinish() -> [Effect] {
        state = .idle
        return [.stopCapture, .keepDraft, .blockDictation(false), .hide(after: 0)]
    }

    private mutating func stopAtLimit() -> [Effect] {
        state = .idle
        return [
            .stopCapture,
            .keepDraft,
            .blockDictation(false),
            .show(.limitReached),
            .hide(after: Self.failureDwell),
        ]
    }

    private mutating func collapseStartPromptIfDue(_ now: Date) -> [Effect] {
        guard case .recording(let app, let since, let confirmed, true, let quiet) = state,
              now.timeIntervalSince(since) >= limits.startPrompt
        else { return [] }
        state = .recording(app: app, since: since, confirmed: confirmed, promptShown: false, quietSince: quiet)
        return [.show(.recording(since: since, confirmed: confirmed))]
    }
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter MeetingMachineTests`
Expected: PASS

- [ ] **Step 5: Прогнать всё**

Run: `swift test`
Expected: PASS

- [ ] **Step 6: Коммит**

```bash
git add Features/Meetings Tests/MeetingsTests
git commit -m "Автомат встречи: мьют, тишина, оживание, автостоп и предел длительности"
```

---

## Task 4: Метаданные и папка встречи

**Files:**
- Create: `Features/Meetings/MeetingMetadata.swift`, `Features/Meetings/MeetingFolder.swift`
- Test: `Tests/MeetingsTests/MeetingFolderTests.swift`, `Tests/MeetingsTests/MeetingMetadataTests.swift`

**Interfaces:**
- Consumes: `MeetingMachine.MeetingApp`
- Produces: `MeetingMetadata` (Codable, поля ниже) с `write(to:)` и `read(from:)`; `MeetingFolder` со статическими `draftName(startedAt:slug:)`, `createDraft(in:startedAt:slug:)`, `promote(_:)`, `drafts(in:)`, `queueURL`

- [ ] **Step 1: Написать падающие тесты имён и переименования**

```swift
// Tests/MeetingsTests/MeetingFolderTests.swift
import Foundation
import Testing
@testable import Meetings

private func temporaryQueue() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func aDraftFolderIsNamedByDateTimeAndSlugAndStartsWithADot() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let draft = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    #expect(draft.lastPathComponent.hasPrefix(".draft-"))
    #expect(draft.lastPathComponent.hasSuffix("-telemost"))
    #expect(FileManager.default.fileExists(atPath: draft.path))
}

// Точка в начале и есть признак незаконченности: 2б берёт папки без точки и не нуждается ни в
// блокировках, ни в чтении метаданных.
@Test func promotingDropsTheDotAndKeepsTheRest() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let draft = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "zoom")
    let final = try MeetingFolder.promote(draft)
    #expect(final.lastPathComponent == String(draft.lastPathComponent.dropFirst(".draft-".count)))
    #expect(FileManager.default.fileExists(atPath: final.path))
    #expect(!FileManager.default.fileExists(atPath: draft.path))
}

@Test func twoMeetingsStartedInTheSameMinuteGetDifferentFolders() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let first = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    _ = try MeetingFolder.promote(first)
    let second = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    #expect(second.lastPathComponent != first.lastPathComponent)
    #expect(second.lastPathComponent.hasSuffix("-2"))
}

@Test func onlyDraftsAreListedAsUnfinished() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let done = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "zoom")
    _ = try MeetingFolder.promote(done)
    let live = try MeetingFolder.createDraft(
        in: queue, startedAt: noon.addingTimeInterval(3600), slug: "telemost"
    )
    let drafts = try MeetingFolder.drafts(in: queue)
    #expect(drafts.map(\.lastPathComponent) == [live.lastPathComponent])
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingFolderTests`
Expected: FAIL — `cannot find 'MeetingFolder' in scope`

- [ ] **Step 3: Написать `MeetingFolder`**

```swift
// Features/Meetings/MeetingFolder.swift
import Foundation

/// Names, creates and hands over the folder of one meeting.
///
/// The whole hand-off to phase 2б is a rename. A folder whose name starts with a dot is still
/// being written; renaming it is atomic, so the queue never has to guess whether a file is
/// finished, and Obsidian — which reads the same `~/Meetings` — never sees the unfinished ones.
public enum MeetingFolder {
    static let draftPrefix = ".draft-"

    public static var queueURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
            .appendingPathComponent(".queue")
    }

    /// `2026-09-03-1430-telemost`. Local time on purpose: the archive is read by a human who
    /// remembers when the meeting was, not by a machine reconciling time zones.
    public static func baseName(startedAt: Date, slug: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(formatter.string(from: startedAt))-\(slug)"
    }

    public static func createDraft(
        in queue: URL,
        startedAt: Date,
        slug: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: queue, withIntermediateDirectories: true)
        let base = baseName(startedAt: startedAt, slug: slug)
        var candidate = base
        var suffix = 1
        while fileManager.fileExists(atPath: queue.appendingPathComponent(candidate).path)
            || fileManager.fileExists(atPath: queue.appendingPathComponent(draftPrefix + candidate).path) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        let draft = queue.appendingPathComponent(draftPrefix + candidate)
        try fileManager.createDirectory(at: draft, withIntermediateDirectories: false)
        return draft
    }

    /// Atomic hand-off: after this returns, phase 2б may pick the folder up.
    @discardableResult
    public static func promote(_ draft: URL, fileManager: FileManager = .default) throws -> URL {
        let name = draft.lastPathComponent
        guard name.hasPrefix(draftPrefix) else { return draft }
        let final = draft.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropFirst(draftPrefix.count)))
        try fileManager.moveItem(at: draft, to: final)
        return final
    }

    /// Folders left behind by an application that died mid-recording.
    public static func drafts(in queue: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: queue.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: queue, includingPropertiesForKeys: nil, options: []
        )
        return entries
            .filter { $0.lastPathComponent.hasPrefix(draftPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter MeetingFolderTests`
Expected: PASS

- [ ] **Step 5: Написать падающие тесты метаданных**

```swift
// Tests/MeetingsTests/MeetingMetadataTests.swift
import Foundation
import Testing
@testable import Meetings

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func metadataSurvivesAWriteAndARead() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(2820),
        app: MeetingMetadata.App(bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: MeetingMetadata.InputDevice(name: "Yeti", sampleRate: 48000, isNarrowband: false),
        stopReason: .automatic,
        excludedApps: ["com.spotify.client"],
        gaps: [MeetingMetadata.Gap(track: .microphone, from: noon.addingTimeInterval(60), to: noon.addingTimeInterval(75))]
    )

    let url = directory.appendingPathComponent("meeting.json")
    try metadata.write(to: url)
    #expect(try MeetingMetadata.read(from: url) == metadata)
}

// Причина остановки читается человеком при разборе «почему запись такая», поэтому пишется
// словом, а не числом.
@Test func theStopReasonIsWrittenAsAWord() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meeting.json")

    let metadata = MeetingMetadata(
        startedAt: noon,
        stoppedAt: noon.addingTimeInterval(60),
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: .lengthLimit,
        excludedApps: [],
        gaps: []
    )
    try metadata.write(to: url)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(raw?["stopReason"] as? String == "lengthLimit")
    #expect(raw?["app"] == nil)
}
```

- [ ] **Step 6: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingMetadataTests`
Expected: FAIL — `cannot find 'MeetingMetadata' in scope`

- [ ] **Step 7: Написать `MeetingMetadata`**

```swift
// Features/Meetings/MeetingMetadata.swift
import Foundation

/// `meeting.json` — what phase 2б needs and what makes a bad recording explainable afterwards.
///
/// Not a placeholder for the future: 2б needs the start timestamp to place words on a
/// timeline, and "why does this sound wrong" cannot be answered without knowing which input
/// device was recording.
public struct MeetingMetadata: Equatable, Sendable, Codable {
    public struct App: Equatable, Sendable, Codable {
        public var bundleID: String
        public var name: String
        public var slug: String

        public init(bundleID: String, name: String, slug: String) {
            self.bundleID = bundleID
            self.name = name
            self.slug = slug
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case name, slug
        }
    }

    public struct InputDevice: Equatable, Sendable, Codable {
        public var name: String
        public var sampleRate: Double
        public var isNarrowband: Bool

        public init(name: String, sampleRate: Double, isNarrowband: Bool) {
            self.name = name
            self.sampleRate = sampleRate
            self.isNarrowband = isNarrowband
        }
    }

    public enum Track: String, Equatable, Sendable, Codable {
        case system
        case microphone
    }

    /// A stretch where one track received nothing — an unplugged microphone, a stream that
    /// died. Written down rather than silently closed over: phase 2б must not read silence as
    /// speech that was never there.
    public struct Gap: Equatable, Sendable, Codable {
        public var track: Track
        public var from: Date
        public var to: Date

        public init(track: Track, from: Date, to: Date) {
            self.track = track
            self.from = from
            self.to = to
        }
    }

    public enum StopReason: String, Equatable, Sendable, Codable {
        case manual
        case automatic
        case appExited
        case lengthLimit
        case failure
    }

    public var startedAt: Date
    public var stoppedAt: Date?
    public var app: App?
    public var sampleRate: Double
    public var channelCount: Int
    public var inputDevice: InputDevice?
    public var stopReason: StopReason?
    public var excludedApps: [String]
    public var gaps: [Gap]

    public init(
        startedAt: Date,
        stoppedAt: Date?,
        app: App?,
        sampleRate: Double,
        channelCount: Int,
        inputDevice: InputDevice?,
        stopReason: StopReason?,
        excludedApps: [String],
        gaps: [Gap]
    ) {
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.app = app
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.inputDevice = inputDevice
        self.stopReason = stopReason
        self.excludedApps = excludedApps
        self.gaps = gaps
    }

    public static let fileName = "meeting.json"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func write(to url: URL) throws {
        try Self.encoder.encode(self).write(to: url)
    }

    public static func read(from url: URL) throws -> MeetingMetadata {
        try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 8: Прогнать всё**

Run: `swift test`
Expected: PASS

- [ ] **Step 9: Коммит**

```bash
git add Features/Meetings Tests/MeetingsTests
git commit -m "Папка встречи и метаданные: атомарная передача в очередь"
```

---

## Task 5: Кто держит вход и выход

**Files:**
- Create: `Core/Audio/AudioProcessMonitor.swift`, `Features/Meetings/MeetingWatcher.swift`
- Test: `Tests/MeetingsTests/MeetingWatcherTests.swift`

**Interfaces:**
- Consumes: `MeetingsConfig`, `MeetingMachine.MeetingApp`
- Produces: `AudioProcessMonitor.State(pid:bundleID:name:isRunningInput:isRunningOutput:)`, `AudioProcessMonitor.current() -> [State]`, `AudioProcessMonitor.observe(_:)`; `MeetingWatcher.match(states:config:) -> [(MeetingMachine.MeetingApp, Bool, Bool)]`

> Если спайк задачи 0 показал, что раздельных признаков по процессам нет, `AudioProcessMonitor` строится на запасном пути из раздела 3 спеки — «кто-то занял вход» плюс список запущенных приложений, — а `isRunningOutput` всегда равен `isRunningInput`. Чистая часть и её тесты от этого не меняются.

- [ ] **Step 1: Написать падающие тесты сопоставления со списком**

```swift
// Tests/MeetingsTests/MeetingWatcherTests.swift
import Core
import Foundation
import Testing
@testable import Meetings

private let config = MeetingsConfig(
    triggerApps: [MeetingsConfig.TriggerApp(bundleID: "ru.yandex.telemost", slug: "telemost")],
    excludedApps: [],
    silenceSeconds: 60,
    autoStopSeconds: 120,
    startPromptSeconds: 30,
    maxMeetingSeconds: 14400
)

@Test func onlyTriggerApplicationsAreReported() {
    let states = [
        AudioProcessMonitor.State(pid: 501, bundleID: "ru.yandex.telemost", name: "Телемост", isRunningInput: true, isRunningOutput: true),
        AudioProcessMonitor.State(pid: 777, bundleID: "com.apple.Music", name: "Музыка", isRunningInput: false, isRunningOutput: true),
    ]
    let matched = MeetingWatcher.match(states: states, config: config)
    #expect(matched.count == 1)
    #expect(matched[0].app.pid == 501)
    #expect(matched[0].app.slug == "telemost")
}

// Собственный процесс не должен поднимать встречу: диктовка тоже занимает вход.
@Test func ourOwnProcessIsNeverAMeeting() {
    let mine = AudioProcessMonitor.State(
        pid: ProcessInfo.processInfo.processIdentifier,
        bundleID: "com.nohands.app",
        name: "NoHands",
        isRunningInput: true,
        isRunningOutput: false
    )
    #expect(MeetingWatcher.match(states: [mine], config: config).isEmpty)
}

@Test func bothFlagsAreCarriedThroughUnchanged() {
    let muted = AudioProcessMonitor.State(
        pid: 501, bundleID: "ru.yandex.telemost", name: "Телемост",
        isRunningInput: false, isRunningOutput: true
    )
    let matched = MeetingWatcher.match(states: [muted], config: config)
    #expect(matched[0].input == false)
    #expect(matched[0].output == true)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter MeetingWatcherTests`
Expected: FAIL — `cannot find 'AudioProcessMonitor' in scope`

- [ ] **Step 3: Написать `AudioProcessMonitor`**

```swift
// Core/Audio/AudioProcessMonitor.swift
import AppKit
import CoreAudio
import Foundation

/// Which processes are holding the audio devices right now.
///
/// macOS 14.4 gave CoreAudio process objects: one object per process that touches audio, with
/// separate flags for input and output. The separation is the whole point here — muting inside
/// a meeting releases the input and keeps the output, so a rule built on the input alone would
/// read every mute as the end of the meeting.
public enum AudioProcessMonitor {
    public struct State: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let name: String?
        public let isRunningInput: Bool
        public let isRunningOutput: Bool

        public init(pid: Int32, bundleID: String?, name: String?, isRunningInput: Bool, isRunningOutput: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isRunningInput = isRunningInput
            self.isRunningOutput = isRunningOutput
        }
    }

    public static func current() -> [State] {
        processObjects().compactMap { object in
            let pid = pid(of: object)
            guard pid > 0 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return State(
                pid: pid,
                bundleID: app?.bundleIdentifier,
                name: app?.localizedName,
                isRunningInput: flag(object, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: flag(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func pid(of object: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return -1
        }
        return value
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
```

- [ ] **Step 4: Написать `MeetingWatcher`**

```swift
// Features/Meetings/MeetingWatcher.swift
import Core
import Foundation

/// Turns "who is holding the audio devices" into "which meeting application is doing what".
///
/// Split from `AudioProcessMonitor` so the rule — which processes count, and what our own
/// process must never count as — is testable without any audio hardware.
public enum MeetingWatcher {
    public struct Match: Equatable, Sendable {
        public let app: MeetingMachine.MeetingApp
        public let input: Bool
        public let output: Bool
    }

    public static func match(states: [AudioProcessMonitor.State], config: MeetingsConfig) -> [Match] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return states.compactMap { state in
            // Dictation holds the input too. Recording a meeting because we are recording is
            // the one loop this whole feature must not have.
            guard state.pid != ownPID else { return nil }
            guard let bundleID = state.bundleID,
                  let trigger = config.triggerApps.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
            else { return nil }
            return Match(
                app: MeetingMachine.MeetingApp(
                    bundleID: bundleID,
                    name: state.name ?? trigger.resolvedSlug,
                    slug: trigger.resolvedSlug,
                    pid: state.pid
                ),
                input: state.isRunningInput,
                output: state.isRunningOutput
            )
        }
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter MeetingWatcherTests`
Expected: PASS

- [ ] **Step 6: Отметить, где проверяется живьём**

Живой проверки на этой задаче нет и быть не может: `AudioProcessMonitor` без потребителя ничего не делает. Детект проверяется на задаче 8, где координатор уже опрашивает его раз в секунду, и окончательно — на задаче 10, живой встречей. Здесь зелёные тесты чистой части и успешная сборка `swift build` — весь возможный результат.

- [ ] **Step 7: Коммит**

```bash
git add Core/Audio/AudioProcessMonitor.swift Features/Meetings/MeetingWatcher.swift Tests/MeetingsTests
git commit -m "Кто держит вход и выход: CoreAudio и сопоставление со списком триггеров"
```

---

## Task 6: Запись двух дорожек одним `SCStream`

**Files:**
- Create: `Core/Audio/MeetingAudioRecorder.swift`
- Modify: `App/Info.plist`

**Interfaces:**
- Consumes: ничего из предыдущих задач
- Produces: `actor MeetingAudioRecorder` с `init(folder:excludedBundleIDs:)`, `func start() async throws`, `func stop() async throws -> MeetingAudioRecorder.Outcome`, `Outcome(systemURL:microphoneURL:gaps:)`; ошибки `MeetingCaptureError.permissionDenied`, `.noDisplay`, `.streamFailed(String)`

Тестами не покрывается: `SCStream` не поднимается в тестовом процессе без разрешения на запись экрана. Проверяется живой минутной записью.

- [ ] **Step 1: Добавить строку разрешения в `Info.plist`**

В `App/Info.plist` добавить:

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Запись системного звука созвона: дорожка собеседников.</string>
```

- [ ] **Step 2: Написать рекордер**

```swift
// Core/Audio/MeetingAudioRecorder.swift
import AVFoundation
import Foundation
import ScreenCaptureKit

public enum MeetingCaptureError: Error, Equatable {
    case permissionDenied
    case noDisplay
    case streamFailed(String)
}

/// Writes both meeting tracks — system audio and microphone — through one `SCStream`.
///
/// One stream rather than two sources is the point: a USB microphone and the system output run
/// off different clocks, and two independent captures drift apart over an hour. Phase 2б merges
/// the tracks by time, and it would inherit that drift as misplaced speaker labels.
///
/// Both files are 16 kHz mono: Parakeet and the voice-embedding model both work at 16 kHz, so
/// 48 kHz would only be downsampled later, after a week of sitting on a 256 GB disk.
public actor MeetingAudioRecorder {
    public struct Outcome: Sendable {
        public let systemURL: URL
        public let microphoneURL: URL
        public let gaps: [(track: String, from: Date, to: Date)]
    }

    public static let sampleRate: Double = 16000
    public static let channelCount: AVAudioChannelCount = 1

    private let folder: URL
    private let excludedBundleIDs: [String]
    private var stream: SCStream?
    private var writer: TrackWriter?

    public init(folder: URL, excludedBundleIDs: [String]) {
        self.folder = folder
        self.excludedBundleIDs = excludedBundleIDs
    }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // The only way this fails in practice is a denied screen recording permission, and
            // saying so is more useful than passing the raw error through.
            throw MeetingCaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }

        let excluded = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: excluded, exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // Our own sounds — the dictation chimes — must not end up in the meeting.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2

        let writer = try TrackWriter(
            systemURL: folder.appendingPathComponent("system.wav"),
            microphoneURL: folder.appendingPathComponent("mic.wav")
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            try await stream.startCapture()
        } catch {
            throw MeetingCaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
        self.writer = writer
    }

    public func stop() async throws -> Outcome {
        guard let stream, let writer else {
            throw MeetingCaptureError.streamFailed("stop called with no capture running")
        }
        try? await stream.stopCapture()
        self.stream = nil
        self.writer = nil
        return writer.finish()
    }
}
```

- [ ] **Step 3: Написать `TrackWriter` в том же файле**

```swift
/// Receives both output types on one queue and writes each into its own file.
///
/// A class rather than a closure because `SCStreamOutput` is a delegate protocol, and one
/// serial queue for both tracks because the two files must not be written concurrently by a
/// converter that is not thread-safe.
private final class TrackWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.nohands.meeting.capture")

    private let systemURL: URL
    private let microphoneURL: URL
    private var systemFile: AVAudioFile?
    private var microphoneFile: AVAudioFile?
    private var failure: Error?

    init(systemURL: URL, microphoneURL: URL) throws {
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
        super.init()
    }

    private var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MeetingAudioRecorder.sampleRate,
            AVNumberOfChannelsKey: MeetingAudioRecorder.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pcm = Self.convert(buffer) else { return }
        do {
            switch type {
            case .audio:
                if systemFile == nil {
                    systemFile = try AVAudioFile(forWriting: systemURL, settings: settings)
                }
                try systemFile?.write(from: pcm)
            case .microphone:
                if microphoneFile == nil {
                    microphoneFile = try AVAudioFile(forWriting: microphoneURL, settings: settings)
                }
                try microphoneFile?.write(from: pcm)
            default:
                break
            }
        } catch {
            if failure == nil { failure = error }
        }
    }

    /// Down-mixes to one channel and resamples to 16 kHz. Both files are written in the format
    /// recognition wants, so nothing downstream has to touch the audio again.
    private static func convert(_ buffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let sourceFormat = AVAudioFormat(streamDescription: asbd),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: MeetingAudioRecorder.sampleRate,
                  channels: MeetingAudioRecorder.channelCount,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let target = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(
                      Double(frames) * MeetingAudioRecorder.sampleRate / sourceFormat.sampleRate
                  ) + 1024
              )
        else { return nil }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList
        ) == noErr else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, target.frameLength > 0 else { return nil }
        return target
    }

    func finish() -> MeetingAudioRecorder.Outcome {
        queue.sync {
            systemFile = nil
            microphoneFile = nil
        }
        return MeetingAudioRecorder.Outcome(
            systemURL: systemURL, microphoneURL: microphoneURL, gaps: []
        )
    }
}
```

- [ ] **Step 4: Прогнать сборку и все тесты**

Run: `swift build && swift test`
Expected: сборка без ошибок, тесты PASS

- [ ] **Step 5: Живая проверка на минутной записи**

```bash
Scripts/make-app.sh && open build/NoHands.app
```

Дальше — временный вызов из меню на следующей задаче. Если хочется проверить прямо сейчас, добавить временный пункт меню «Тест записи», записать минуту с играющим видео и своей речью, затем:

```bash
afplay ~/Meetings/.queue/.draft-*/system.wav
afplay ~/Meetings/.queue/.draft-*/mic.wav
afinfo ~/Meetings/.queue/.draft-*/system.wav | head -20
```

Ожидаемое: в `system.wav` слышно видео и не слышно своего голоса, в `mic.wav` наоборот. Оба файла — 16000 Гц, 1 канал, длительности совпадают в пределах секунды. Временный пункт меню убрать до коммита.

- [ ] **Step 6: Коммит**

```bash
git add Core/Audio/MeetingAudioRecorder.swift App/Info.plist
git commit -m "Обе дорожки одним SCStream: 16 кГц моно, свой звук исключён"
```

---

## Task 7: Осиротевший черновик

**Files:**
- Create: `Core/Audio/WavHeaderRepair.swift`
- Test: `Tests/CoreTests/WavHeaderRepairTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces: `WavHeaderRepair.repair(at: URL) throws -> Bool` — true, если заголовок был починен

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/WavHeaderRepairTests.swift
import AVFoundation
import Foundation
import Testing
@testable import Core

private func brokenWav() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
    buffer.frameLength = 16000
    try file.write(from: buffer)
    // Имитация падения: длины в заголовке обнуляются, данные остаются на месте.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 4)
    try handle.write(contentsOf: Data([0, 0, 0, 0]))
    try handle.seek(toOffset: 40)
    try handle.write(contentsOf: Data([0, 0, 0, 0]))
    try handle.close()
    return url
}

// Незакрытый файл выглядит пустым, хотя звук в нём есть: длины пишутся в заголовок при
// закрытии. Черновик упавшего приложения без этой починки не открыть.
@Test func aTruncatedHeaderIsRepairedFromTheActualFileSize() throws {
    let url = try brokenWav()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try AVAudioFile(forReading: url).length == 0)
    #expect(try WavHeaderRepair.repair(at: url) == true)

    let repaired = try AVAudioFile(forReading: url)
    #expect(repaired.length == 16000)
}

@Test func aHealthyFileIsLeftAlone() throws {
    let url = try brokenWav()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try WavHeaderRepair.repair(at: url)
    #expect(try WavHeaderRepair.repair(at: url) == false)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter WavHeaderRepairTests`
Expected: FAIL — `cannot find 'WavHeaderRepair' in scope`

- [ ] **Step 3: Написать починку**

```swift
// Core/Audio/WavHeaderRepair.swift
import Foundation

/// Rewrites the two length fields of a WAV header from the file's actual size.
///
/// `AVAudioFile` writes those lengths when it closes. An application that died mid-recording
/// leaves them at zero, and the file then reads as empty even though every sample is there.
/// The draft of a crashed meeting is exactly that file.
public enum WavHeaderRepair {
    private static let riffSizeOffset: UInt64 = 4
    private static let dataSizeOffset: UInt64 = 40
    private static let headerSize: UInt64 = 44

    /// - Returns: true when the header was rewritten, false when it already matched the file.
    @discardableResult
    public static func repair(at url: URL) throws -> Bool {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        guard size > headerSize else { return false }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: dataSizeOffset)
        let existing = try handle.read(upToCount: 4) ?? Data()
        let expectedData = UInt32(size - headerSize)
        guard existing != le(expectedData) else { return false }

        try handle.seek(toOffset: riffSizeOffset)
        try handle.write(contentsOf: le(UInt32(size - 8)))
        try handle.seek(toOffset: dataSizeOffset)
        try handle.write(contentsOf: le(expectedData))
        return true
    }

    private static func le(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter WavHeaderRepairTests`
Expected: PASS

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/WavHeaderRepair.swift Tests/CoreTests/WavHeaderRepairTests.swift
git commit -m "Починка заголовка WAV: черновик упавшего приложения открывается"
```

---

## Task 8: Координатор и блокировка диктовки

**Files:**
- Create: `Features/Meetings/MeetingCoordinator.swift`
- Modify: `Features/Dictation/DictationMachine.swift`, `Features/Dictation/DictationCoordinator.swift`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`, `Tests/DictationTests/DictationMachineTests.swift`

**Interfaces:**
- Consumes: `MeetingMachine`, `MeetingFolder`, `MeetingMetadata`, `MeetingWatcher`, `MeetingAudioRecorder`, `AudioProcessMonitor`
- Produces: `@MainActor final class MeetingCoordinator` с `init(config:showPanel:hidePanel:onDictationBlocked:)`, `func start()`, `func stop()`, `func startPressed()`, `func stopPressed()`, `func answer(_ answer: MeetingCoordinator.Answer)`; `enum Answer { case confirm, decline, keep, delete }`; в `DictationMachine` — `Event.blocked` не нужен, блокировка живёт во внешнем флаге координатора диктовки

- [ ] **Step 1: Написать падающий тест блокировки диктовки**

```swift
// Tests/DictationTests/DictationMachineTests.swift — дописать
// Диктовка на время записи встречи блокируется: одновременный захват микрофона двумя
// потребителями не нужен ни одному сценарию владельца.
@Test func fnDoesNothingWhileAMeetingIsBeingRecorded() {
    var subject = machine()
    subject.isBlocked = true
    #expect(subject.handle(.fnDown(at: start)) == [.show(.blocked)])
    #expect(subject.state == .idle)
}

@Test func unblockingRestoresNormalDictation() {
    var subject = machine()
    subject.isBlocked = true
    _ = subject.handle(.fnDown(at: start))
    subject.isBlocked = false
    #expect(subject.handle(.fnDown(at: start)) == [.startRecording, .swallow(space: true, escape: true)])
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter DictationMachineTests`
Expected: FAIL — `value of type 'DictationMachine' has no member 'isBlocked'`

- [ ] **Step 3: Добавить блокировку в автомат диктовки**

В `DictationMachine`:

```swift
    /// True while a meeting is being recorded. Set by the coordinator, not by an event: the
    /// meeting machine owns this fact, and mirroring it as dictation state would give two
    /// machines two versions of the same truth.
    public var isBlocked = false
```

и первым случаем в `handle`:

```swift
        case (.idle, .fnDown) where isBlocked:
            return [.show(.blocked)]
```

В `PanelState` добавить случай `case blocked`.

В `App/PanelView.swift` дать ему слова: «идёт запись созвона».

- [ ] **Step 4: Прогнать тесты диктовки**

Run: `swift test --filter DictationTests`
Expected: PASS

- [ ] **Step 5: Написать координатор**

```swift
// Features/Meetings/MeetingCoordinator.swift
import Core
import Foundation

/// Performs what `MeetingMachine` decides.
///
/// Glue only: it holds no rules of its own. The folder of the current recording lives here,
/// because ownership of a half-written folder is exactly the thing a pure machine must not
/// have.
@MainActor
public final class MeetingCoordinator {
    public enum Answer: Sendable {
        case confirm
        case decline
        case keep
        case delete
    }

    private let config: MeetingsConfig
    private let showPanel: (MeetingPanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let onDictationBlocked: (Bool) -> Void

    private var machine: MeetingMachine
    private var poller: Timer?
    private var recorder: MeetingAudioRecorder?
    private var folder: URL?
    private var metadata: MeetingMetadata?
    private var knownPIDs: Set<Int32> = []

    public init(
        config: MeetingsConfig,
        showPanel: @escaping (MeetingPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onDictationBlocked: @escaping (Bool) -> Void
    ) {
        self.config = config
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.onDictationBlocked = onDictationBlocked
        self.machine = MeetingMachine(limits: MeetingMachine.Limits(config: config))
    }

    /// One timer drives both jobs: polling the audio processes and ticking the machine. A
    /// second of granularity is plenty for thresholds measured in tens of seconds.
    public func start() {
        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        poller?.invalidate()
        poller = nil
    }

    public func startPressed() {
        let app = MeetingWatcher
            .match(states: AudioProcessMonitor.current(), config: config)
            .first { $0.input || $0.output }?
            .app
        apply(machine.handle(.startPressed(app: app, at: Date())))
    }

    public func stopPressed() {
        apply(machine.handle(.stopPressed(at: Date())))
    }

    public func answer(_ answer: Answer) {
        let now = Date()
        switch answer {
        case .confirm: apply(machine.handle(.confirmPressed(at: now)))
        case .decline: apply(machine.handle(.declinePressed(at: now)))
        case .keep: apply(machine.handle(.keepPressed))
        case .delete: apply(machine.handle(.deletePressed))
        }
    }

    private func poll() {
        let now = Date()
        let matches = MeetingWatcher.match(states: AudioProcessMonitor.current(), config: config)
        let live = Set(matches.map(\.app.pid))
        for gone in knownPIDs.subtracting(live) {
            apply(machine.handle(.appExited(pid: gone, at: now)))
        }
        knownPIDs = live
        for match in matches {
            apply(machine.handle(.streamsChanged(
                app: match.app, input: match.input, output: match.output, at: now
            )))
        }
        apply(machine.handle(.tick(now)))
    }

    private func apply(_ effects: [MeetingMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startCapture(let app, let at):
                startCapture(app: app, at: at)
            case .stopCapture:
                stopCapture()
            case .keepDraft:
                keepDraft()
            case .discardDraft:
                discardDraft()
            case .show(let state):
                showPanel(state)
            case .hide(let after):
                hidePanel(after)
            case .blockDictation(let blocked):
                onDictationBlocked(blocked)
            }
        }
    }

    private func startCapture(app: MeetingMachine.MeetingApp?, at: Date) {
        do {
            let draft = try MeetingFolder.createDraft(
                in: MeetingFolder.queueURL, startedAt: at, slug: app?.slug ?? "manual"
            )
            folder = draft
            let device = AudioInputDevice.current()
            metadata = MeetingMetadata(
                startedAt: at,
                stoppedAt: nil,
                app: app.map {
                    MeetingMetadata.App(bundleID: $0.bundleID, name: $0.name, slug: $0.slug)
                },
                sampleRate: MeetingAudioRecorder.sampleRate,
                channelCount: Int(MeetingAudioRecorder.channelCount),
                inputDevice: device.map {
                    MeetingMetadata.InputDevice(
                        name: $0.name, sampleRate: $0.sampleRate, isNarrowband: $0.isNarrowband
                    )
                },
                stopReason: nil,
                excludedApps: config.excludedApps,
                gaps: []
            )
            let recorder = MeetingAudioRecorder(
                folder: draft, excludedBundleIDs: config.excludedApps
            )
            self.recorder = recorder
            Task { [weak self] in
                do {
                    try await recorder.start()
                } catch {
                    await MainActor.run {
                        self?.apply(self?.machine.handle(.captureFailed(Self.describe(error))) ?? [])
                    }
                }
            }
        } catch {
            apply(machine.handle(.captureFailed(Self.describe(error))))
        }
    }

    private func stopCapture() {
        guard let recorder, let folder else { return }
        self.recorder = nil
        var metadata = self.metadata
        metadata?.stoppedAt = Date()
        self.metadata = metadata
        Task {
            _ = try? await recorder.stop()
            if let metadata {
                try? metadata.write(to: folder.appendingPathComponent(MeetingMetadata.fileName))
            }
        }
    }

    private func keepDraft() {
        guard let folder else { return }
        // Deliberately after the capture task has been asked to stop: the rename is the
        // hand-off to phase 2б, and handing over a file still being written is the one thing
        // the dot prefix exists to prevent.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            try? MeetingFolder.promote(folder)
            self.folder = nil
        }
    }

    private func discardDraft() {
        guard let folder else { return }
        self.folder = nil
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MeetingCaptureError.permissionDenied: "нет разрешения на запись экрана"
        case MeetingCaptureError.noDisplay: "нет доступного дисплея"
        case MeetingCaptureError.streamFailed(let message): message
        default: error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Написать тест, что осиротевшие черновики находятся при запуске**

```swift
// Tests/MeetingsTests/MeetingCoordinatorTests.swift
import Foundation
import Testing
@testable import Meetings

// Осиротевший черновик не удаляется и не подхватывается молча: приложение спрашивает.
@Test func orphanDraftsAreFoundAndOfferedRatherThanDeleted() throws {
    let queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: queue) }
    let draft = try MeetingFolder.createDraft(
        in: queue, startedAt: Date(timeIntervalSince1970: 1_788_000_000), slug: "telemost"
    )
    try MeetingMetadata(
        startedAt: Date(timeIntervalSince1970: 1_788_000_000),
        stoppedAt: nil,
        app: nil,
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: nil,
        excludedApps: [],
        gaps: []
    ).write(to: draft.appendingPathComponent(MeetingMetadata.fileName))

    let found = try MeetingFolder.drafts(in: queue)
    #expect(found.count == 1)
    #expect(FileManager.default.fileExists(atPath: draft.path))
}
```

- [ ] **Step 7: Прогнать всё**

Run: `swift test`
Expected: PASS

- [ ] **Step 8: Коммит**

```bash
git add Features Tests
git commit -m "Координатор встреч и блокировка диктовки на время записи"
```

---

## Task 9: Панель и меню

**Files:**
- Modify: `App/PanelModel.swift`, `App/PanelView.swift`, `App/DictationPanel.swift`, `App/StatusMenu.swift`, `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `MeetingPanelState`, `MeetingCoordinator`
- Produces: рабочее приложение, в котором подсказки кликаются, а меню умеет старт и стоп

- [ ] **Step 1: Добавить состояние встречи в модель панели**

В `App/PanelModel.swift` — свойство `@Published var meeting: MeetingPanelState?` рядом с существующим состоянием диктовки. Диктовка имеет приоритет отображения: пока она идёт, подсказка встречи ждёт.

- [ ] **Step 2: Включать и выключать приём мыши**

В `App/DictationPanel.swift`, там где окно создаётся:

```swift
// The panel is deaf by default so a dictation never loses its target field. A prompt is the
// one thing that needs the mouse, and it gets it for exactly as long as it is up.
func setAcceptsClicks(_ accepts: Bool) {
    window.ignoresMouseEvents = !accepts
}
```

Вызывать из места, где модель получает новое состояние встречи: `setAcceptsClicks(state?.acceptsClicks ?? false)`.

- [ ] **Step 3: Нарисовать подсказки**

В `App/PanelView.swift` — развёрнутый вид для `.startPrompt`, `.stopPrompt`, `.savePrompt`, `.orphanFound` с двумя кнопками, свёрнутый с меткой и таймером для `.recording`. Слова:

| Состояние | Текст | Кнопки |
|---|---|---|
| `.startPrompt(appName)` | «Записать созвон в \(appName)?» | «Записать», «Нет» |
| `.recording(since:confirmed:)` | таймер от `since` | — |
| `.stopPrompt(duration)` | «Встреча кончилась? Сохранить запись \(минуты) мин» | «Сохранить», «Удалить» |
| `.savePrompt(duration)` | «Сохранить запись \(минуты) мин?» | «Сохранить», «Удалить» |
| `.orphanFound(duration)` | «Найдена незавершённая запись \(минуты) мин» | «Сохранить», «Удалить» |
| `.limitReached` | «Достигнут предел длительности, запись сохранена» | — |
| `.failure(text)` | текст как есть | — |

Кнопки шлют `coordinator.answer(.confirm)` и остальные три.

- [ ] **Step 4: Добавить пункты меню**

В `App/StatusMenu.swift`: «Записать созвон» → `coordinator.startPressed()`, «Остановить запись (12:34)» → `coordinator.stopPressed()`, показывается вместо первого во время записи. Пункт «Разрешить запись экрана…» виден, только когда разрешения нет, и открывает системные настройки:

```swift
NSWorkspace.shared.open(URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
)!)
```

- [ ] **Step 5: Связать в `AppDelegate`**

Создать `MeetingCoordinator` рядом с `DictationCoordinator`, передать ему замыкания панели, а в `onDictationBlocked` — установку `dictationCoordinator.isBlocked`. Вызвать `meetingCoordinator.start()` при запуске и `stop()` при выходе. При запуске проверить `MeetingFolder.drafts(in:)` и, если что-то нашлось, показать `.orphanFound`.

- [ ] **Step 6: Собрать и посмотреть глазами**

```bash
Scripts/make-app.sh && open build/NoHands.app
```

Проверить: свёрнутая полоска на месте; пункт меню запускает запись; во время записи полоска показывает таймер; fn во время записи не начинает диктовку и показывает «идёт запись созвона»; клик по кнопке подсказки не уводит фокус из текстового поля рядом.

- [ ] **Step 7: Коммит**

```bash
git add App
git commit -m "Панель встречи: подсказки с кнопками, таймер, пункты меню"
```

---

## Task 10: Живая встреча и записи в журнал

**Files:**
- Modify: `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`

- [ ] **Step 1: Записать живой созвон целиком**

Провести настоящую встречу в Телемосте. Не трогать ничего руками: детект должен сам предложить запись, а после выхода из встречи — предложить остановку.

- [ ] **Step 2: Проверить результат**

```bash
ls -la ~/Meetings/.queue/
afinfo ~/Meetings/.queue/*/system.wav
afinfo ~/Meetings/.queue/*/mic.wav
cat ~/Meetings/.queue/*/meeting.json
```

Ожидаемое: папка без точки в начале, две дорожки одинаковой длительности, 16 кГц моно, в `mic.wav` только свой голос, в `system.wav` только собеседники, в `meeting.json` заполнены начало, конец, приложение и устройство.

- [ ] **Step 3: Проверить мьют**

Во время встречи несколько раз снять и поставить мьют. Запись не должна прерваться и подсказка остановки не должна появиться.

- [ ] **Step 4: Записать наблюдения в журнал**

Дописать в `docs/DECISIONS.md` запись о первой живой встрече: какой порог тишины оказался нужен, срабатывал ли детект, попали ли в дорожку A уведомления. Обновить `docs/ARCHITECTURE.md`: раздел «Состояние по фазам» — 2а закрыта, число тестов, что осталось.

```bash
git add docs
git commit -m "Журнал и архитектура: фаза 2а закрыта живой встречей"
git push
```

---

## Самопроверка плана

**Покрытие спеки.** Раздел 1 спеки — задача 0 и весь план. Раздел 2 (границы) — задачи 1–9. Раздел 3 (детект) — задачи 0 и 5. Раздел 4 (захват) — задача 6. Раздел 5 (диск) — задача 4. Раздел 6 (автомат) — задачи 2 и 3. Раздел 7 (блокировка диктовки) — задача 8. Раздел 8 (панель и меню) — задача 9. Раздел 9 (конфиг) — задача 1. Раздел 10 (отказы) — задачи 2, 6, 7, 8. Раздел 11 (что тестируется) — задачи 1–5, 7. Раздел 12 (порядок задач) — совпадает.

**Пробелы, оставленные сознательно.** Отметки разрывов записи (`gaps`) читаются и пишутся в метаданных, но заполняются пустым списком: единственный источник разрыва — исчезнувшее устройство ввода, и правило для него подбирается на живой встрече в задаче 10. Диалог осиротевшего черновика показывается, но его ответы обрабатываются тем же путём, что и `savePrompt`.

**Согласованность имён.** `MeetingsConfig.TriggerApp.bundleID` и `MeetingMetadata.App.bundleID` оба кодируются ключом `bundleId` — в json одно написание. Сокрытие панели везде одно: `.hide(after:)`, немедленное — `.hide(after: 0)`, как и `hidePanel(after:)` в диктовке. Слаг папки приходит из `TriggerApp.resolvedSlug` в `MeetingWatcher.match`, оттуда в `MeetingApp.slug`, оттуда в `MeetingFolder.createDraft(slug:)` — одно значение, три перехода, ни одного пересчёта по дороге.
