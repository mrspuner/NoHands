# Приоритет входа и кнопка «Готово» в лотке — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** перед каждой записью приложение отбирает вход у блютус-микрофона, если есть широкополосный, а полоска лотка держится до кнопки «Готово», а не до истечения таймера.

**Architecture:** три независимых куска в одной ветке. Первый — новый тип `InputDeviceGuard` в `Core/Audio`, который перед стартом диктовки и перед стартом записи встречи проверяет системный дефолт входа и, если это блютус, пишет туда лучший широкополосный вход. Второй — лоток: окно приёма файлов больше не закрывается само через две минуты, его закрывает кнопка на панели, а десятиминутный предел остаётся страховкой. Третий — слаг папки входящего берётся из хоста адреса, когда захват сделан из браузера.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 15, CoreAudio, SwiftUI, Swift Testing.

**Spec:** отдельной спеки нет — работа классифицирована как ограниченная, дизайн согласован в чате 2026-09-09. Опорные записи: `docs/DECISIONS.md` за 2026-09-08 («Микрофонная дорожка гибнет на интерливленном буфере…», «Мишень для вложений занимает основную строку панели», «Возврат строки лотка после отказа держится на невидимом отсюда условии») и за 2026-09-09 («Живая проверка лотка»).

## Global Constraints

- Идентификаторы, комментарии в коде и сообщения об ошибках — по-английски. Интерфейс, документация и коммиты — по-русски.
- Новых зависимостей не добавлять.
- Не логировать содержимое транскриптов и распознанного текста.
- Тесты — Swift Testing (`import Testing`, `@Test`, `#expect`), рядом с существующими в `Tests/<Target>Tests/`.
- Прогон: `swift test`, сборка приложения: `Scripts/make-app.sh`.
- Правки в `docs/` коммитятся и пушатся отдельным коммитом сразу, не дожидаясь кода.
- Не заменять внятную ошибку молчаливым фолбэком.

## Измерено спайком 2026-09-09 (числа, на которые опирается план)

На этой машине, macOS 15.6, при подключённых AirPods Pro и микрофоне iPhone:

| Устройство | uid | Транспорт | Частоты |
|---|---|---|---|
| Микрофон (iPhone (Arslan)) | `094EF7FA-…-70B000000003` | `ccwd` | только 48000 |
| AirPods Pro, вход | `F0-D3-1F-6F-CA-96:input` | `blue` | только 24000 |
| AirPods Pro, выход | `F0-D3-1F-6F-CA-96:output` | `blue` | 24000 и 48000 |
| ZoomAudioDevice | `zoom.us.zoomaudiodevice.001` | `virt` | 44100…192000 |

Запись `kAudioHardwarePropertyDefaultInputDevice` вернула `noErr`. Пока входом были AirPods, их выход стоял на 24000 Гц моно; после переключения входа на iPhone — 48000 Гц стерео. Обратно так же. Никаких разрешений, ничего не открывая на запись.

---

### Task 1: Журнал решений

**Files:**
- Modify: `docs/DECISIONS.md`

- [ ] **Step 1: Дописать две записи в конец файла**

Первая — про приоритет входа. Текст (целиком, дословно):

```markdown
## 2026-09-09 — Перед записью вход отбирается у блютус-микрофона

Правка владельца. AirPods, подключаясь, забирают системный вход, и это стоит не только диктовки:
измерено спайком, что выбор AirPods входом переводит их же выход с 48000 Гц стерео на 24000 Гц моно
мгновенно, до того как хоть кто-то открыл поток. То есть узкая полоса приходит не в дорожку
владельца, а в дорожку собеседников, которую пишет ScreenCaptureKit из системного микса, — и в фазе
2г по ней придётся различать голоса.

Отсюда форма решения: приложение пишет **системный** дефолт входа, а не выбирает устройство для
себя. Выбрать устройство только себе бессмысленно — полосу роняет сам факт дефолта, а страдает от
неё общий микс.

Порядок предпочтения: USB, затем Continuity (микрофон iPhone), затем встроенный. Виртуальные и
агрегатные устройства исключены: `ZoomAudioDevice` принимает запись и отдаёт тишину, что ниже по
конвейеру читается как отказ распознавания, а не как неверное устройство. Узкополосный кандидат не
берётся тоже — менять шило на мыло незачем.

**Момент — перед записью, а не постоянно.** Решение владельца из двух предложенных. Цена названа
заранее: детект встречи срабатывает через секунду после того, как Телемост занял устройства, и
успеет ли смена дефолта отобрать у него микрофон — зависит от того, следует ли Телемост за
системным дефолтом на лету. Для диктовки вариант работает всегда: движок открывается уже после
починки. Проверяется живой встречей; если не следует — возвращаемся к постоянному слежению.

**Ручной выбор уважается.** Если после нашей починки вход снова блютусный, вернуть его мог только
владелец — и с этого момента устройство не трогается. Память живёт, пока устройство в списке:
исчезло и появилось снова — спор начинается заново, вчерашнее не помнится.

Обратная сторона этой памяти названа вслух: различить «система переключила» и «владелец
переключил» без постоянного слежения нечем, поэтому повторное переключение самой системой будет
принято за ручной выбор и уступлено. Это прямое следствие выбранного момента, а не недосмотр.

Отвергнуто: постоянное слежение за дефолтом (чинит и встречу, начатую до нашего детекта, но
вмешивается в систему всё время работы приложения); подсказка с вопросом на панели (требует
внимания ровно в ту секунду, когда человек входит в созвон).
```

Вторая — про полоску лотка:

```markdown
## 2026-09-09 — Полоску лотка закрывает кнопка, а не таймер

Правка владельца по итогам живого разбора: после успешного перетаскивания окно приёма продлевалось
ещё на две минуты, и полоска висела над доком, когда всё уже принесено.

Сделано не сокращением таймера, а сменой того, кто закрывает окно: в строке появилась кнопка
«Готово», она сворачивает полоску и закрывает папку для приёма немедленно. Таймер остался
страховкой на случай, когда кнопку не нажали, и вырос с двух минут до десяти — теперь он не
основной путь, а предохранитель.

Предохранитель обязателен: по правилу от 2026-09-04 висящая подсказка принимает мышь и глушит
клики по доку под собой, а в полноэкранном созвоне под полоской ровно кнопки мьюта и выхода.
Бесконечно висящая мишень нарушала бы это правило.

Заодно починена ловушка, записанная 2026-09-08: возврат строки после отказа считал остаток окна по
снимку, снятому в момент отказа, а не по текущему сроку. Пока мишень нельзя было продлить из
строки отказа, это было недостижимо; кнопка «Готово» делает состояние строки изменяемым, и снимок
стал бы враньём.
```

- [ ] **Step 2: Проверить, что записи не редактируют старые**

Run: `git diff --stat docs/DECISIONS.md`
Expected: только добавления, `1 file changed, N insertions(+)`, ни одного удаления.

- [ ] **Step 3: Коммит и пуш**

```bash
git add docs/DECISIONS.md
git commit -m "Журнал: приоритет входа перед записью и кнопка «Готово» в лотке"
git push
```

---

### Task 2: Транспорт устройства и список входов

**Files:**
- Modify: `Core/Audio/AudioInputDevice.swift`
- Test: `Tests/CoreTests/AudioInputDeviceTests.swift`

**Interfaces:**
- Produces: `InputTransport` (`.builtIn`, `.usb`, `.continuity`, `.bluetooth`, `.virtual`, `.other`); `AudioInputDevice.transport: InputTransport`; `AudioInputDevice.init(name:uid:sampleRate:channelCount:transport:)` с `transport` по умолчанию `.other`; `AudioInputDevice.inputDevices() -> [AudioInputDevice]`; `AudioInputDevice.setDefaultInput(uid: String) -> Bool`.

- [ ] **Step 1: Написать падающие тесты**

Дописать в конец `Tests/CoreTests/AudioInputDeviceTests.swift`:

```swift
// The four-character codes are CoreAudio's own; they are matched against the SDK constants
// rather than against literals, so a renamed constant fails to compile instead of silently
// falling through to `.other`.
@Test func transportsAreMappedFromCoreAudioCodes() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeUSB) == .usb)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    #expect(InputTransport.from(kAudioDeviceTransportTypeVirtual) == .virtual)
    #expect(InputTransport.from(kAudioDeviceTransportTypeAggregate) == .virtual)
}

// Both flavours of a Continuity microphone are one thing to this application: an iPhone on the
// desk. Measured on this machine — the iPhone microphone reports `ccwd`.
@Test func bothContinuityFlavoursAreOneTransport() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeContinuityCaptureWired) == .continuity)
    #expect(InputTransport.from(kAudioDeviceTransportTypeContinuityCaptureWireless) == .continuity)
}

// Anything this application has no rule for stays `.other`, and `.other` is never chosen as a
// replacement — an unknown transport is not an argument for switching the owner's microphone.
@Test func anUnknownTransportIsOther() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeHDMI) == .other)
    #expect(InputTransport.from(kAudioDeviceTransportTypeAirPlay) == .other)
}

// The same shape the single-device test has, for the same reason: this machine may have no input
// at all, and a half-filled entry is the only outcome that is always wrong.
@Test func everyListedInputIsFullyDescribed() {
    for device in AudioInputDevice.inputDevices() {
        #expect(!device.name.isEmpty)
        #expect(device.sampleRate > 0)
        #expect(device.channelCount > 0)
    }
}

// A uid nothing answers to must not be written anywhere: the call reports the miss instead of
// picking some other device, and the system default is left exactly as it was.
@Test func settingAnUnknownDeviceAsDefaultIsRefused() {
    let before = AudioInputDevice.current()?.uid
    #expect(AudioInputDevice.setDefaultInput(uid: "no-such-device") == false)
    #expect(AudioInputDevice.current()?.uid == before)
}
```

В шапку файла добавить `import CoreAudio`.

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter AudioInputDeviceTests`
Expected: FAIL, компиляция не проходит — `cannot find 'InputTransport' in scope`.

- [ ] **Step 3: Реализовать**

В `Core/Audio/AudioInputDevice.swift` перед `AudioInputDevice` добавить:

```swift
/// How CoreAudio says a device is attached.
///
/// Only the values this application acts on are named. Everything else is `.other`, which is
/// never chosen as a replacement: an unknown transport is not a reason to move the owner's
/// microphone.
public enum InputTransport: Equatable, Sendable {
    case builtIn
    case usb
    /// A Continuity microphone — an iPhone on the desk, wired or not.
    case continuity
    /// Bluetooth in both its flavours. The input side of a Bluetooth headset runs at 24 kHz and
    /// nothing else, and choosing it drops the whole device — the output included — into that
    /// band. Measured on this machine 2026-09-09.
    case bluetooth
    /// Virtual and aggregate devices. `ZoomAudioDevice` is the one that matters here: it accepts
    /// a recording and hands back silence.
    case virtual
    case other

    static func from(_ raw: UInt32) -> InputTransport {
        switch raw {
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
        default: .other
        }
    }
}
```

В `AudioInputDevice` добавить поле и параметр (остальные свойства и их порядок не трогать):

```swift
    public let transport: InputTransport
```

```swift
    public init(
        name: String,
        uid: String,
        sampleRate: Double,
        channelCount: UInt32,
        transport: InputTransport = .other
    ) {
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.transport = transport
    }
```

В `current()` заполнить транспорт: `transport: transportType(deviceID)` последним аргументом.

Добавить в тип статические методы:

```swift
    /// Every device with at least one input channel, as CoreAudio lists them.
    ///
    /// Filtered by input channels rather than by name: an AirPods pair is two separate devices
    /// on macOS 15 — `…:input` and `…:output` — and only the first of them can be a default
    /// input at all.
    public static func inputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
                  let name = deviceName(id),
                  let format = streamFormat(id)
            else { return nil }
            return AudioInputDevice(
                name: name,
                uid: deviceUID(id) ?? "",
                sampleRate: format.mSampleRate,
                channelCount: format.mChannelsPerFrame,
                transport: transportType(id)
            )
        }
    }

    /// Writes the system-wide default input. Reports the refusal rather than throwing: the one
    /// caller treats a refusal as "record on whatever is there", which is the honest outcome —
    /// the recording still happens, in the band the system chose.
    @discardableResult
    public static func setDefaultInput(uid: String) -> Bool {
        guard !uid.isEmpty, let match = deviceIDs().first(where: { deviceUID($0) == uid }) else {
            return false
        }
        var value = match
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        return status == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> InputTransport {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return .other
        }
        return InputTransport.from(value)
    }

    private static func channelCount(
        _ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter AudioInputDeviceTests`
Expected: PASS, все тесты файла.

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/AudioInputDevice.swift Tests/CoreTests/AudioInputDeviceTests.swift
git commit -m "Устройства ввода: транспорт, полный список и запись системного дефолта"
```

---

### Task 3: Правило выбора замены

**Files:**
- Create: `Core/Audio/InputPreference.swift`
- Test: `Tests/CoreTests/InputPreferenceTests.swift`

**Interfaces:**
- Consumes: `AudioInputDevice`, `InputTransport` из Task 2.
- Produces: `InputPreference.replacement(among: [AudioInputDevice]) -> AudioInputDevice?`.

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CoreTests/InputPreferenceTests.swift`:

```swift
import Testing
@testable import Core

private func device(
    _ name: String,
    _ transport: InputTransport,
    rate: Double = 48000,
    uid: String? = nil
) -> AudioInputDevice {
    AudioInputDevice(
        name: name,
        uid: uid ?? "uid-\(name)",
        sampleRate: rate,
        channelCount: 1,
        transport: transport
    )
}

// A USB microphone was plugged in on purpose; an iPhone is merely on the desk. When both are
// there, the deliberate one wins.
@Test func usbIsPreferredToContinuity() {
    let picked = InputPreference.replacement(among: [
        device("iPhone", .continuity),
        device("Yeti", .usb),
    ])
    #expect(picked?.name == "Yeti")
}

@Test func continuityIsTakenWhenThereIsNoUSB() {
    let picked = InputPreference.replacement(among: [
        device("AirPods", .bluetooth, rate: 24000),
        device("iPhone", .continuity),
    ])
    #expect(picked?.name == "iPhone")
}

// `ZoomAudioDevice` accepts a recording and hands back silence, which reads downstream as a
// failed transcription rather than as a wrong device. Never chosen, whatever else is missing.
@Test func aVirtualDeviceIsNeverChosen() {
    #expect(InputPreference.replacement(among: [device("ZoomAudioDevice", .virtual)]) == nil)
}

// Switching one narrowband input for another buys nothing.
@Test func aNarrowbandCandidateIsNotWorthSwitchingTo() {
    #expect(InputPreference.replacement(among: [device("cheap", .usb, rate: 16000)]) == nil)
}

// The uid is what the switch is written with; a device CoreAudio would not name cannot be set.
@Test func aDeviceWithoutAUidIsSkipped() {
    let picked = InputPreference.replacement(among: [
        device("безымянный", .usb, uid: ""),
        device("iPhone", .continuity),
    ])
    #expect(picked?.name == "iPhone")
}

@Test func bluetoothIsNeverAReplacement() {
    #expect(InputPreference.replacement(among: [device("AirPods", .bluetooth, rate: 24000)]) == nil)
}

@Test func anEmptyListHasNoReplacement() {
    #expect(InputPreference.replacement(among: []) == nil)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InputPreferenceTests`
Expected: FAIL — `cannot find 'InputPreference' in scope`.

- [ ] **Step 3: Реализовать**

Создать `Core/Audio/InputPreference.swift`:

```swift
import Foundation

/// Picks the input a recording should run on when macOS has handed the default to Bluetooth.
public enum InputPreference {
    /// USB first, then a Continuity microphone, then whatever is built into the machine.
    ///
    /// The order is by how deliberate the choice behind the device is: a USB microphone was
    /// plugged in on purpose, an iPhone merely happens to be on the desk, and a built-in
    /// microphone — which a Mac mini does not have at all — is the last resort.
    static let order: [InputTransport] = [.usb, .continuity, .builtIn]

    /// - Returns: the best full-band input among `devices`, or nil when there is none — in which
    ///   case the recording goes ahead on whatever the system chose, with the narrowband warning
    ///   the panel already shows.
    public static func replacement(among devices: [AudioInputDevice]) -> AudioInputDevice? {
        for transport in order {
            if let match = devices.first(where: {
                $0.transport == transport && !$0.uid.isEmpty && !$0.isNarrowband
            }) {
                return match
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter InputPreferenceTests`
Expected: PASS, семь тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/InputPreference.swift Tests/CoreTests/InputPreferenceTests.swift
git commit -m "Правило выбора входа: USB, затем iPhone, затем встроенный"
```

---

### Task 4: `InputDeviceGuard` — починка с памятью о ручном выборе

**Files:**
- Create: `Core/Audio/InputDeviceGuard.swift`
- Test: `Tests/CoreTests/InputDeviceGuardTests.swift`

**Interfaces:**
- Consumes: `AudioInputDevice.inputDevices`, `AudioInputDevice.current`, `AudioInputDevice.setDefaultInput(uid:)`, `InputPreference.replacement(among:)`.
- Produces: `@MainActor final class InputDeviceGuard` с `init(list:current:setDefault:)` (все три параметра имеют системные значения по умолчанию) и `@discardableResult func prepare() -> InputDeviceGuard.Outcome`, где `Outcome` — `.unchanged`, `.switched(name: String)`, `.yielded`, `.failed`.

- [ ] **Step 1: Написать падающие тесты**

Создать `Tests/CoreTests/InputDeviceGuardTests.swift`:

```swift
import Testing
@testable import Core

private let airpods = AudioInputDevice(
    name: "AirPods", uid: "airpods", sampleRate: 24000, channelCount: 1, transport: .bluetooth
)
private let iphone = AudioInputDevice(
    name: "Микрофон iPhone", uid: "iphone", sampleRate: 48000, channelCount: 1,
    transport: .continuity
)

@MainActor
private final class Harness {
    var devices: [AudioInputDevice] = [airpods, iphone]
    var current: AudioInputDevice? = airpods
    var refuse = false
    private(set) var writes: [String] = []
    var guardian: InputDeviceGuard!

    init() {
        guardian = InputDeviceGuard(
            list: { [unowned self] in self.devices },
            current: { [unowned self] in self.current },
            setDefault: { [unowned self] uid in
                self.writes.append(uid)
                guard !self.refuse else { return false }
                self.current = self.devices.first { $0.uid == uid }
                return true
            }
        )
    }
}

@MainActor
@Test func aBluetoothDefaultIsSwitchedToTheBestInput() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    #expect(harness.writes == ["iphone"])
}

@MainActor
@Test func aFullBandDefaultIsLeftAlone() {
    let harness = Harness()
    harness.current = iphone
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}

// Nothing better to switch to: the recording goes ahead on the Bluetooth microphone, and the
// narrowband warning the panel already shows is the whole reporting this case gets.
@MainActor
@Test func withoutACandidateNothingIsWritten() {
    let harness = Harness()
    harness.devices = [airpods]
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}

@MainActor
@Test func aRefusedWriteIsReportedRatherThanRetried() {
    let harness = Harness()
    harness.refuse = true
    #expect(harness.guardian.prepare() == .failed)
    #expect(harness.writes == ["iphone"])
}

// The owner put the Bluetooth input back by hand — nothing else could have — so it is theirs
// from now on, and no later recording argues with it.
@MainActor
@Test func aManualReturnToBluetoothIsRespected() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    harness.current = airpods
    #expect(harness.guardian.prepare() == .yielded)
    #expect(harness.guardian.prepare() == .yielded)
    #expect(harness.writes == ["iphone"])
}

// Unplugged and plugged in again starts the argument over: the memory is about the device that
// is here, not about what happened yesterday.
@MainActor
@Test func aVanishedDeviceIsForgotten() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    harness.current = airpods
    #expect(harness.guardian.prepare() == .yielded)

    harness.devices = [iphone]
    harness.current = iphone
    #expect(harness.guardian.prepare() == .unchanged)

    harness.devices = [airpods, iphone]
    harness.current = airpods
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    #expect(harness.writes == ["iphone", "iphone"])
}

// No input at all — a Mac mini with nothing plugged in. There is nothing to prefer over nothing.
@MainActor
@Test func noInputDeviceIsNotAnOccasionToWriteAnything() {
    let harness = Harness()
    harness.current = nil
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InputDeviceGuardTests`
Expected: FAIL — `cannot find 'InputDeviceGuard' in scope`.

- [ ] **Step 3: Реализовать**

Создать `Core/Audio/InputDeviceGuard.swift`:

```swift
import Foundation

/// Keeps a Bluetooth microphone from holding the system input when a recording is about to start.
///
/// Measured on this machine 2026-09-09: choosing the AirPods input drops the AirPods *output*
/// from 48000 Hz stereo to 24000 Hz mono in the same instant, before anything opens a stream, and
/// choosing another input puts it back. That is why this writes the system default rather than
/// picking a device for itself — the narrow band is caused by the default, and the track that
/// suffers from it is the one ScreenCaptureKit records out of the system mix.
///
/// Called before a recording starts, not continuously. The cost of that is named in the decisions
/// journal: a meeting whose application grabbed the Bluetooth microphone before the detector saw
/// it may keep it for the rest of the call.
@MainActor
public final class InputDeviceGuard {
    public enum Outcome: Equatable, Sendable {
        /// The default was fine, or there was nothing better to move to.
        case unchanged
        /// The default was moved to this device.
        case switched(name: String)
        /// The Bluetooth input is the owner's own choice and is left alone.
        case yielded
        /// A switch was attempted and CoreAudio refused it.
        case failed
    }

    private let list: () -> [AudioInputDevice]
    private let current: () -> AudioInputDevice?
    private let setDefault: (String) -> Bool

    /// The Bluetooth input this guard moved away from, for as long as that device is still
    /// around. Seeing it as the default again means the owner put it back by hand.
    private var switchedAwayFrom: String?
    /// The device the owner insisted on. Cleared when it disappears, so plugging the headphones
    /// in tomorrow starts the argument over rather than remembering yesterday's.
    private var yieldedTo: String?

    public init(
        list: @escaping () -> [AudioInputDevice] = AudioInputDevice.inputDevices,
        current: @escaping () -> AudioInputDevice? = AudioInputDevice.current,
        setDefault: @escaping (String) -> Bool = { AudioInputDevice.setDefaultInput(uid: $0) }
    ) {
        self.list = list
        self.current = current
        self.setDefault = setDefault
    }

    @discardableResult
    public func prepare() -> Outcome {
        let devices = list()
        forget(missingFrom: devices)
        guard let current = current(), current.transport == .bluetooth else { return .unchanged }
        if yieldedTo == current.uid { return .yielded }
        // Back on Bluetooth after this guard moved it off: only the owner could have done that,
        // since nothing here writes the default twice for the same device. Their choice stands
        // until the device goes away.
        if switchedAwayFrom == current.uid {
            yieldedTo = current.uid
            switchedAwayFrom = nil
            return .yielded
        }
        guard let replacement = InputPreference.replacement(among: devices) else {
            return .unchanged
        }
        guard setDefault(replacement.uid) else { return .failed }
        switchedAwayFrom = current.uid
        return .switched(name: replacement.name)
    }

    private func forget(missingFrom devices: [AudioInputDevice]) {
        let present = Set(devices.map(\.uid))
        if let uid = switchedAwayFrom, !present.contains(uid) { switchedAwayFrom = nil }
        if let uid = yieldedTo, !present.contains(uid) { yieldedTo = nil }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter InputDeviceGuardTests`
Expected: PASS, семь тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/InputDeviceGuard.swift Tests/CoreTests/InputDeviceGuardTests.swift
git commit -m "Отбор входа у блютус-микрофона с памятью о ручном выборе"
```

---

### Task 5: `MeetingNotice` переименован в `PanelNotice`

**Files:**
- Rename: `Features/Meetings/MeetingNotice.swift` → `Features/Meetings/PanelNotice.swift`
- Rename: `Tests/MeetingsTests/MeetingNoticeTests.swift` → `Tests/MeetingsTests/PanelNoticeTests.swift`
- Modify: `Core/Transcript/MeetingMarkdown.swift`, `App/PanelModel.swift`, `App/PanelWindow.swift`, `App/AppDelegate.swift`, `Features/Meetings/MeetingCoordinator.swift`, `Features/Meetings/MeetingFolderState.swift`

**Interfaces:**
- Produces: `PanelNotice` вместо `MeetingNotice`, поля и фабрики без изменений (`text`, `isFailure`, `dwell`, `forOutcome(_:)`, `forSummary(_:)`).

Механическая правка по прямой инструкции: тип перестал принадлежать встречам — следующая задача показывает им же уведомление о переключении входа.

- [ ] **Step 1: Переименовать файлы и все вхождения**

```bash
git mv Features/Meetings/MeetingNotice.swift Features/Meetings/PanelNotice.swift
git mv Tests/MeetingsTests/MeetingNoticeTests.swift Tests/MeetingsTests/PanelNoticeTests.swift
grep -rl "MeetingNotice" --include="*.swift" App Core Features Tests \
  | xargs sed -i '' 's/MeetingNotice/PanelNotice/g'
```

- [ ] **Step 2: Поправить доккомментарий типа**

В `Features/Meetings/PanelNotice.swift` заменить первую строку доккомментария на:

```swift
/// One line the panel says about something that has already happened.
///
/// Not only about meetings, despite living in this module: a switched input device reports
/// itself the same way. Kept here rather than moved to `Core` because `App` — the only place
/// that draws it — already depends on this module, and `Core` has no notion of a panel.
```

- [ ] **Step 3: Прогнать все тесты**

Run: `swift test`
Expected: PASS, ни одного упоминания `MeetingNotice` — проверить `grep -rn "MeetingNotice" --include="*.swift" .`, ожидается пусто.

- [ ] **Step 4: Коммит**

```bash
git add -A
git commit -m "Уведомление панели больше не называется встречным"
```

---

### Task 6: Диктовка чинит вход перед записью

**Files:**
- Modify: `Features/Dictation/DictationCoordinator.swift`

**Interfaces:**
- Produces: у `DictationCoordinator.init` появляется параметр `prepareInput: @escaping () -> Void = {}`, вызываемый первым делом в `startRecording()`.

Юнит-теста здесь нет и написать его негде: `DictationCoordinator` не конструируется ни в одном тесте — он требует `MicrophoneRecorder` с живым `AVAudioEngine`, `Transcriber`, `DeepSeekClient` и `TextInserter`. Правило, которое он исполняет, покрыто тестами `InputDeviceGuard`; порядок вызова покрыт тестом встречи в Task 7, где координатор конструируется. Это записано здесь, чтобы следующий читатель не искал тест, которого нет.

- [ ] **Step 1: Добавить параметр**

В `init` после `onNarrowbandInput` добавить параметр:

```swift
        /// Called before the engine opens, to take the system input away from a Bluetooth
        /// microphone if there is something better. A closure rather than a dependency, for the
        /// same reason the panel is one.
        prepareInput: @escaping () -> Void = {},
```

и сохранить его в `private let prepareInput: () -> Void`.

- [ ] **Step 2: Вызвать в начале записи**

В `startRecording()` первой строкой, до `onNarrowbandInput`:

```swift
        // Before the band is read, not after: the whole point is that the number reported here
        // describes the device this recording will actually run on.
        prepareInput()
```

- [ ] **Step 3: Собрать и прогнать тесты**

Run: `swift build && swift test`
Expected: сборка без новых предупреждений, все тесты проходят.

- [ ] **Step 4: Коммит**

```bash
git add Features/Dictation/DictationCoordinator.swift
git commit -m "Диктовка чинит вход перед открытием движка"
```

---

### Task 7: Встреча чинит вход перед стартом захвата

**Files:**
- Modify: `Features/Meetings/MeetingCoordinator.swift`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Produces: у `MeetingCoordinator.init` появляется параметр `prepareInput: @escaping () -> Void = {}`, вызываемый в `startCapture(app:at:)` до `readInputDevice()`.

- [ ] **Step 1: Написать падающий тест**

В `Tests/MeetingsTests/MeetingCoordinatorTests.swift` добавить в `Harness` счётчик и параметр, а затем тест. В harness:

```swift
    /// Order matters here, not just the count: the band written into `meeting.json` has to
    /// describe the device the recording will run on, which it only does if the input is fixed
    /// before it is read.
    private(set) var inputEvents: [String] = []
```

в замыкании `readInputDevice` первой строкой дописать `self.inputEvents.append("read")`, и передать в координатор:

```swift
            prepareInput: { [unowned self] in self.inputEvents.append("prepare") },
```

Тест:

```swift
@MainActor
@Test @MainActor func theInputIsFixedBeforeItsBandIsRead() async throws {
    let harness = try Harness()
    harness.processes = [telemost]

    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    #expect(harness.inputEvents.first == "prepare")
    #expect(harness.inputEvents.contains("read"))
}
```

`telemost`, `noon`, `startPressed(at:)` и `settle()` — те же, что в
`startingARecordingCreatesADraftThatAlreadyKnowsWhenItBegan` двадцатью строками выше в этом файле.

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter theInputIsFixedBeforeItsBandIsRead`
Expected: FAIL — `extra argument 'prepareInput' in call`.

- [ ] **Step 3: Реализовать**

В `MeetingCoordinator` добавить `private let prepareInput: () -> Void`, параметр `prepareInput: @escaping () -> Void = {}` в `init` (после `readInputDevice`, до `readProcesses`), присвоение в теле `init`, и вызов в `startCapture(app:at:)` — первой строкой внутри `do`, до `let device = readInputDevice()`:

```swift
            // Before the device is read, so the band written into `meeting.json` describes the
            // microphone this recording actually runs on rather than the one it was about to.
            prepareInput()
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter MeetingCoordinatorTests`
Expected: PASS, включая новый тест.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingCoordinator.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Встреча чинит вход до чтения полосы"
```

---

### Task 8: Приложение собирает страж и называет переключение

**Files:**
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `InputDeviceGuard`, `PanelNotice`, параметры `prepareInput` обоих координаторов.

Тестового таргета на `App` в проекте нет — проверка здесь сборкой и живым запуском, как во всех предыдущих фазах.

- [ ] **Step 1: Завести страж и обработчик**

В `AppDelegate` рядом с другими полями:

```swift
    /// One guard for both recorders: its memory of what the owner chose by hand is about the
    /// machine, not about which of the two is recording.
    private let inputGuard = InputDeviceGuard()
```

и метод:

```swift
    /// Takes the system input away from a Bluetooth microphone before a recording starts, and
    /// says so. Silent when nothing changed and when the owner's own choice was left alone —
    /// a notice for "everything is as you left it" would be noise on every dictation.
    private func prepareInput() {
        switch inputGuard.prepare() {
        case .switched(let name):
            panel.show(notice: PanelNotice(text: "Вход переключён на \(name)", isFailure: false))
            panel.hideNotice(after: PanelNotice.dwell)
        case .failed:
            panel.show(notice: PanelNotice(
                text: "Не удалось увести вход с блютус-микрофона", isFailure: true
            ))
            panel.hideNotice(after: PanelNotice.dwell)
        case .unchanged, .yielded:
            break
        }
    }
```

- [ ] **Step 2: Передать в оба координатора**

В месте создания `DictationCoordinator` добавить `prepareInput: { [weak self] in self?.prepareInput() },`, и то же — в месте создания `MeetingCoordinator`.

- [ ] **Step 3: Собрать приложение**

Run: `swift build && Scripts/make-app.sh`
Expected: сборка проходит, `build/NoHands.app` собран и подписан.

- [ ] **Step 4: Коммит**

```bash
git add App/AppDelegate.swift
git commit -m "Приложение уводит вход с блютус-микрофона перед записью"
```

---

### Task 9: Лоток — окно приёма закрывает кнопка

**Files:**
- Modify: `Features/Inbox/InboxCoordinator.swift`
- Test: `Tests/InboxTests/InboxCoordinatorTests.swift`

**Interfaces:**
- Produces: `InboxCoordinator.doneRequested()`; `InboxCoordinator.dropWindow` = 600.

- [ ] **Step 1: Написать падающие тесты**

Дописать в `Tests/InboxTests/InboxCoordinatorTests.swift`:

```swift
// The owner said they were done: the strip goes at once and the folder stops taking files.
// Anything dropped after that has nowhere to go, and the panel must not pretend otherwise.
@MainActor
@Test func doneClosesTheWindowImmediately() async throws {
    let root = try temporaryRoot()
    let harness = Harness(root: root)
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    harness.coordinator.doneRequested()

    #expect(harness.hidden.last == 0)
    #expect(harness.coordinator.drop([root.appendingPathComponent("whatever.txt")]) == false)
}

// Ten minutes, not two: the timer stopped being the way this row ends and became the guard
// against a row nobody closed. It cannot be infinite — a strip that takes the mouse sits over
// the mute button of a full-screen call.
@MainActor
@Test func theDropWindowIsTenMinutes() {
    #expect(InboxCoordinator.dropWindow == 600)
}

// A drop still buys another full window: files arrive in batches, and the second batch must not
// find the target gone. What changed is that the window is no longer how this ends.
@MainActor
@Test func aDropKeepsTheWindowOpen() async throws {
    let root = try temporaryRoot()
    // The window is passed explicitly rather than left at the harness default of 120: this test
    // is about the drop re-arming whatever window it was given, and the harness default is not
    // the constant.
    let harness = Harness(root: root, dropWindow: 600)
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    let file = root.appendingPathComponent("attachment.txt")
    try Data("x".utf8).write(to: file)
    #expect(harness.coordinator.drop([file]) == true)

    #expect(harness.hidden.last == 600)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxCoordinatorTests`
Expected: FAIL — `value of type 'InboxCoordinator' has no member 'doneRequested'`.

- [ ] **Step 3: Реализовать**

В `InboxCoordinator` изменить константу и её комментарий:

```swift
    /// How long the strip stays a target when nobody closes it. Ten minutes, and it is a
    /// backstop rather than the way this ends: the owner closes the row with «Готово» the moment
    /// everything is brought over. It cannot be infinite — the strip takes the mouse while it is
    /// up, and in a full-screen call it sits exactly over the mute and leave buttons.
    public static let dropWindow: TimeInterval = 600
```

Добавить метод рядом с `drop(_:)`:

```swift
    /// «Готово» on the panel. Closes both the row and the folder it was pointing at.
    ///
    /// Nothing is undone and nothing is deleted: the capture and every file already dropped on
    /// it stay where they are. This says only that no more files are coming.
    public func doneRequested() {
        expiry?.cancel()
        expiry = nil
        target = nil
        targetExpiresAt = nil
        hidePanel(0)
    }
```

В `reportFailure` заменить снимок на чтение текущего значения:

```swift
        guard let failedTarget = target, targetExpiresAt != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + failureDwell) { [weak self] in
            // Read now, not captured above: «Готово» and a later drop both change what is left
            // on the window while this failure is being read, and a snapshot taken at the start
            // would bring the row back for a target that is already closed — or hide it early.
            guard let self, self.target == failedTarget,
                  let expiresAt = self.targetExpiresAt else { return }
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return }
            self.showPanel(.captured(app: self.appName, lines: self.lines, attachments: self.attachments))
            self.hidePanel(remaining)
        }
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter InboxTests`
Expected: PASS, включая три новых теста и все существующие.

Существующий `#expect(harness.hidden == [120])` не ломается: `Harness` держит собственное значение окна по умолчанию и не читает константу. Трогать его не нужно.

- [ ] **Step 5: Коммит**

```bash
git add Features/Inbox/InboxCoordinator.swift Tests/InboxTests/InboxCoordinatorTests.swift
git commit -m "Лоток: окно приёма закрывает «Готово», таймер стал предохранителем"
```

---

### Task 10: Кнопка «Готово» на панели

**Files:**
- Modify: `App/PanelModel.swift`, `App/PanelWindow.swift`, `App/PanelView.swift`, `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `InboxCoordinator.doneRequested()`.
- Produces: `PanelModel.onInboxDone: (() -> Void)?`, `PanelWindow.setInboxDone(_:)`.

- [ ] **Step 1: Завести колбэк в модели**

В `PanelModel` рядом с `onInboxDrop`:

```swift
    /// Answers the «Готово» button on the inbox row. Not published, like `onInboxDrop` and
    /// `onMeetingAnswer`: it is read at the moment of the press, never drawn.
    var onInboxDone: (() -> Void)?
```

- [ ] **Step 2: Пробросить через окно**

В `PanelWindow` рядом с `setInboxDrop`:

```swift
    func setInboxDone(_ handler: @escaping () -> Void) {
        model.onInboxDone = handler
    }
```

- [ ] **Step 3: Нарисовать кнопку**

В `PanelView.swift`, в `InboxContent`, случай `.captured` рисуется строкой с кнопкой. Заменить тело случая на:

```swift
        case .captured(let app, let lines, let attachments):
            HStack(spacing: 10) {
                Text(caption(app: app, lines: lines, attachments: attachments))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                PromptButton(title: "Готово", prominent: false) { model.onInboxDone?() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Surface(recording: true))
            .frame(maxWidth: 520)
            .overlay(
                RoundedRectangle(cornerRadius: Surface.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(targeted ? 0.5 : 0), lineWidth: 1.5)
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.onInboxDrop?(urls) ?? false
            } isTargeted: { targeted = $0 }
```

Случай `.failure` продолжает пользоваться `row(_:failed:)`. Метод `row` остаётся: он рисует строку отказа.

- [ ] **Step 4: Связать в делегате**

В `AppDelegate`, рядом с `panel.setInboxDrop`:

```swift
        panel.setInboxDone { [weak inbox] in inbox?.doneRequested() }
```

- [ ] **Step 5: Собрать и запустить**

Run: `swift build && Scripts/make-app.sh && open build/NoHands.app`
Expected: сборка проходит; после fn+C на выделенном тексте в строке видна кнопка «Готово», нажатие сворачивает полоску.

- [ ] **Step 6: Коммит**

```bash
git add App/PanelModel.swift App/PanelWindow.swift App/PanelView.swift App/AppDelegate.swift
git commit -m "Панель: кнопка «Готово» закрывает строку лотка"
```

---

### Task 11: Слаг папки из хоста адреса

**Files:**
- Modify: `Features/Inbox/InboxSource.swift`
- Test: `Tests/InboxTests/InboxSourceTests.swift` (создать, если файла нет)

**Interfaces:**
- Produces: `InboxSource.slug` берёт первую метку хоста, когда у захвата есть адрес.

- [ ] **Step 1: Написать падающие тесты**

```swift
import Testing
@testable import Inbox

private func source(url: String?) -> InboxSource {
    InboxSource(appName: "Safari", bundleID: "com.apple.Safari", url: url)
}

// Тracker and Messenger are both Safari, and before this both folders were named `-safari`.
// The address is the only thing that tells them apart.
@Test func aBrowserCaptureIsNamedAfterTheHost() {
    #expect(source(url: "https://tracker.yandex.ru/CRM-123").slug == "tracker")
    #expect(source(url: "https://360.yandex.ru/messenger").slug == "360")
}

@Test func wwwIsNotAName() {
    #expect(source(url: "https://www.example.com/page").slug == "example")
}

// No address means no browser: the bundle identifier is what names the folder, as before.
@Test func withoutAnAddressTheBundleIdentifierNamesTheFolder() {
    #expect(InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil).slug == "telegram")
}

// A string that is not an address must not produce a folder named after its wreckage.
@Test func anUnparsableAddressFallsBackToTheBundleIdentifier() {
    #expect(source(url: "не адрес").slug == "safari")
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxSourceTests`
Expected: FAIL — `tracker` ожидается, приходит `safari`.

- [ ] **Step 3: Реализовать**

В `InboxSource` заменить `slug`:

```swift
    /// The folder name of this capture.
    ///
    /// A browser is asked what page it is on, and the first label of that host names the folder:
    /// Tracker and Messenger are both Safari, and `-safari` for either of them said only
    /// "a browser". `www` is skipped because it names nothing.
    ///
    /// Everything else — and any address that will not parse — falls back to the bundle
    /// identifier, which is what named every folder before.
    public var slug: String {
        if let url, let host = URLComponents(string: url)?.host {
            let labels = host.split(separator: ".").map(String.init)
            let first = labels.first == "www" ? labels.dropFirst().first : labels.first
            if let first, !first.isEmpty { return first.lowercased() }
        }
        return InboxFolder.slug(forBundleID: bundleID ?? "")
    }
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter InboxTests`
Expected: PASS, включая четыре новых.

- [ ] **Step 5: Коммит**

```bash
git add Features/Inbox/InboxSource.swift Tests/InboxTests/InboxSourceTests.swift
git commit -m "Слаг входящего из хоста адреса, а не только из бандла"
```

---

### Task 12: Сверка целиком

**Files:** ничего не меняется, кроме `docs/DECISIONS.md`, если что-то из проверок разошлось с планом.

- [ ] **Step 1: Полный прогон**

Run: `swift test 2>&1 | tail -5`
Expected: прогон зелёный. Число тестов — на двадцать с лишним больше, чем было до ветки; точное значение записать в отчёт последней задачи.

- [ ] **Step 2: Сборка приложения**

Run: `Scripts/make-app.sh`
Expected: собрано и подписано, без ошибок.

- [ ] **Step 3: Проверить, что новых предупреждений не появилось**

Run:

```bash
touch Core/Audio/*.swift Features/Inbox/*.swift && swift build 2>&1 \
  | grep -E "^[^ ].*warning:" | sed 's|.*/NoHands/||' | sort -u
```

Expected: ровно пять строк, все из них замерены до ветки 2026-09-09 — `MicrophoneRecorder.swift:1`, `:131`, `:135`, `:137` и `AudioInputDevice.swift:80`. Любая шестая строка — предупреждение, добавленное этой веткой; починить здесь, а не оставлять на потом.

Строка `AudioInputDevice.swift:80` (`forming 'UnsafeMutableRawPointer' to a variable of type 'CFString'`) относится к `readCFStringProperty`, которая существовала до ветки. Если после правок она переехала на другой номер строки — это то же самое предупреждение, а не новое.

- [ ] **Step 4: Отчёт владельцу**

Живьём проверяется владельцем, потому что тестам это недоступно:
1. Подключить AirPods при подключённом iPhone, нажать fn и продиктовать фразу — панель должна сказать «Вход переключён на Микрофон iPhone», а системные настройки звука — показать iPhone входом.
2. Выбрать AirPods входом руками, продиктовать ещё раз — приложение не должно ничего переключать.
3. Начать созвон при подключённых AirPods и посмотреть, отберётся ли вход у Телемоста на лету. Это единственная непроверяемая заранее часть решения — результат дописать в журнал.
4. Сделать fn+C, бросить файл, нажать «Готово» — полоска уходит сразу.
5. Захват из Трекера и из Мессенджера — папки должны называться `-tracker` и `-360`.
