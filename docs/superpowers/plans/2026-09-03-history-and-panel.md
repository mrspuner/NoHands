# История диктовок и поведение панели. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Приложение перестаёт терять сказанное и начинает сообщать то, что владелец обязан знать: последние десять диктовок доступны из меню, панель висит над доком постоянно, узкополосный вход назван вслух, а текст идёт туда, где фокус в момент вставки.

**Architecture:** Три из пяти задач вычитают, а не добавляют. Хранилище последней диктовки становится кольцом на десять и переезжает из координатора в `AppDelegate`, чтобы пережить пересборку. Понятие фиксированного получателя удаляется из автомата и из вставки целиком — вместе с механизмом активации окна и двумя отказами. Панель перестаёт появляться и исчезать: nil в её модели теперь значит «свёрнута», а не «нет».

**Tech Stack:** Swift 6, Swift Package Manager без Xcode-проекта, swift-testing (`import Testing`), AppKit (`NSMenu`, `NSPanel`, `NSWorkspace`, `NSPasteboard`), SwiftUI для содержимого панели, CoreAudio.

**Spec:** `docs/superpowers/specs/2026-09-03-history-and-panel-design.md`

## Global Constraints

- Swift 6 language mode. `Package.swift` объявляет `// swift-tools-version: 6.0` — **эту строку не менять**. Строгая проверка конкурентности включена.
- **Новых зависимостей не добавлять.** AppKit, SwiftUI, CoreAudio и `os` — системные фреймворки, не зависимости. `FluidAudio` закреплён `.exact("0.14.8")` и не трогается.
- Идентификаторы, комментарии в коде и **сообщения об ошибках — по-английски**. Текст интерфейса и вывод CLI — по-русски. Коммиты — по-русски.
- **Русских формулировок в модуле `Dictation` быть не должно.** Координатор передаёт наружу факты, `App` пишет текст.
- **Не заменять внятную ошибку молчаливым фолбэком.**
- **Не логировать содержимое транскриптов и распознанного текста.** История держит тексты в памяти; ничего из неё не пишется в файлы и не печатается.
- Модуль `Dictation` не импортирует ничего оконного. `App` не знает, как устроена диктовка.
- Тест раньше кода. Каждая задача заканчивается коммитом.
- В сборке есть ровно пять предупреждений, все в `Core/Audio/`, все из фазы 0. Их не чиним и новых не добавляем.
- Ни одно утверждение в существующих тестах не ослабляется. Там, где задача меняет ожидаемое значение, ожидание исправляется на верное, а не смягчается.

---

## Структура файлов

```
Features/Dictation/
  RecentDictations.swift        НОВ   кольцо на десять, аудио только у свежей
  MenuTitle.swift               НОВ   обрезка заголовка пункта меню, чистая
  LastDictation.swift           УДАЛ  заменяется первым
  TargetApp.swift               УДАЛ  после смены правила ничего не определяет
  DictationMachine.swift        ИЗМ   TargetApp уходит из событий, состояний, эффектов
  PanelState.swift              ИЗМ   состояния теряют получателя
  TextInserter.swift            ИЗМ   уходят активация, план и два отказа
  DictationCoordinator.swift    ИЗМ   хранилище извне, вставка без цели, канал полосы

Core/Audio/
  AudioInputDevice.swift        ИЗМ   порог и предикат узкой полосы

App/
  AppDelegate.swift             ИЗМ   владеет хранилищем, подписан на NSWorkspace
  StatusMenu.swift              ИЗМ   подменю «Последние диктовки»
  DictationPanel.swift          ИЗМ   всегда видна, сворачивается вместо исчезновения
  PanelModel.swift              ИЗМ   активное приложение и узкая полоса
  PanelView.swift               ИЗМ   свёрнутый вид, живое приложение, предупреждение

CLI/
  NoHands.swift                 ИЗМ   предупреждение через общий предикат

Tests/
  DictationTests/RecentDictationsTests.swift   НОВ
  DictationTests/MenuTitleTests.swift          НОВ
  DictationTests/LastDictationTests.swift      УДАЛ
  DictationTests/TextInserterTests.swift       УДАЛ  вместе с ActivationPlan
  DictationTests/DictationMachineTests.swift   ИЗМ   ожидания без получателя
  CoreTests/AudioInputDeviceTests.swift        ИЗМ   + порог с обеих сторон
```

---

### Задача 1: Кольцо последних диктовок

Соответствует разделу 2 спеки. `LastDictation` держит одну запись и живёт внутри координатора, поэтому «Перечитать конфиг» стирает подстраховку. Становится кольцом на десять и переезжает наружу.

**Files:**
- Create: `Features/Dictation/RecentDictations.swift`
- Delete: `Features/Dictation/LastDictation.swift`, `Tests/DictationTests/LastDictationTests.swift`
- Modify: `Features/Dictation/DictationCoordinator.swift`, `App/AppDelegate.swift`
- Test: `Tests/DictationTests/RecentDictationsTests.swift`

**Interfaces:**
- Consumes: ничего нового.
- Produces: `@MainActor public final class RecentDictations` со `static let capacity = 10`, вложенной `struct Entry: Equatable, Identifiable` (поля `id: UUID`, `raw: String`, `cleaned: String?`, `audio: URL?`; вычисляемые `inserted: String`, `wasCleaned: Bool`), методами `entries() -> [Entry]`, `remember(raw:cleaned:audio:)`, `discardAudio()`. `DictationCoordinator.init` получает новый параметр `recent: RecentDictations`.

- [ ] **Шаг 1: Написать падающие тесты**

`Tests/DictationTests/RecentDictationsTests.swift`:

```swift
import Foundation
import Testing
@testable import Dictation

@MainActor
private func scratchFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nohands-recent-\(UUID().uuidString).wav")
    try Data([0]).write(to: url)
    return url
}

@MainActor
@Test func nothingIsRememberedAtFirst() {
    #expect(RecentDictations().entries().isEmpty)
}

@MainActor
@Test func theNewestComesFirst() {
    let store = RecentDictations()
    store.remember(raw: "один", cleaned: nil, audio: nil)
    store.remember(raw: "два", cleaned: nil, audio: nil)
    #expect(store.entries().map(\.raw) == ["два", "один"])
}

// Ten covers a working session; the eleventh pushes the oldest out rather than growing without
// bound.
@MainActor
@Test func theEleventhPushesTheOldestOut() {
    let store = RecentDictations()
    for index in 1...11 {
        store.remember(raw: "\(index)", cleaned: nil, audio: nil)
    }
    #expect(store.entries().count == RecentDictations.capacity)
    #expect(store.entries().first?.raw == "11")
    #expect(store.entries().last?.raw == "2")
}

// Exactly one recording is ever on disk: the previous newest gives up its file the moment a
// new dictation arrives.
@MainActor
@Test func onlyTheNewestKeepsItsAudio() throws {
    let store = RecentDictations()
    let first = try scratchFile()
    let second = try scratchFile()
    defer { try? FileManager.default.removeItem(at: second) }

    store.remember(raw: "один", cleaned: nil, audio: first)
    store.remember(raw: "два", cleaned: nil, audio: second)

    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(store.entries().first?.audio == second)
    #expect(store.entries().last?.audio == nil)
}

// The texts are the safety net and outlive the coordinator; the audio belongs to the
// coordinator and does not.
@MainActor
@Test func discardingAudioKeepsTheTexts() throws {
    let store = RecentDictations()
    let audio = try scratchFile()
    store.remember(raw: "сырой", cleaned: "Чистый.", audio: audio)

    store.discardAudio()

    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(store.entries().count == 1)
    #expect(store.entries().first?.audio == nil)
    #expect(store.entries().first?.cleaned == "Чистый.")
}

@MainActor
@Test func discardingAudioOnAnEmptyStoreDoesNothing() {
    RecentDictations().discardAudio()
}

// What gets copied out of the menu is what was inserted, and cleanup may not have run.
@MainActor
@Test func insertedIsTheCleanedTextWhenThereIsOne() {
    let store = RecentDictations()
    store.remember(raw: "эээ привет", cleaned: "Привет.", audio: nil)
    let entry = try! #require(store.entries().first)
    #expect(entry.inserted == "Привет.")
    #expect(entry.wasCleaned)
}

@MainActor
@Test func insertedFallsBackToTheRawText() {
    let store = RecentDictations()
    store.remember(raw: "эээ привет", cleaned: nil, audio: nil)
    let entry = try! #require(store.entries().first)
    #expect(entry.inserted == "эээ привет")
    #expect(!entry.wasCleaned)
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter RecentDictations`
Expected: FAIL — `cannot find 'RecentDictations' in scope`

- [ ] **Шаг 3: Реализовать хранилище**

`Features/Dictation/RecentDictations.swift`:

```swift
import Foundation

/// The last few dictations, kept in memory until the application quits.
///
/// A dictation can fail to land: the accessibility permission may be missing, or the paste may
/// go somewhere unexpected. Before this existed the text was gone the moment the next copy
/// overwrote the clipboard. Now the last ten are two clicks away.
///
/// Only the newest keeps its recording. The audio exists for a future word-correction window,
/// which needs exactly one; ten recordings of the owner's speech on a 256 GB disk is the
/// failure this guards against.
///
/// Main-actor rather than an actor: everything that touches it — the coordinator and the menu —
/// already runs there, and `NSMenu` rebuilds itself synchronously and cannot await.
@MainActor
public final class RecentDictations {
    /// Ten covers a working session and still reads from a menu at a glance.
    public static let capacity = 10

    public struct Entry: Equatable, Identifiable {
        public let id: UUID
        public let raw: String
        public let cleaned: String?
        /// Set only on the newest entry; see the type's documentation.
        ///
        /// `fileprivate(set)` rather than the `private(set)` the spec sketches: the enclosing
        /// class has to clear this when a newer dictation takes over the file, and it lives
        /// outside the struct's own scope.
        public fileprivate(set) var audio: URL?

        /// What was actually inserted: the cleaned text, or the raw text when cleanup failed.
        public var inserted: String { cleaned ?? raw }
        public var wasCleaned: Bool { cleaned != nil }

        public init(id: UUID = UUID(), raw: String, cleaned: String?, audio: URL?) {
            self.id = id
            self.raw = raw
            self.cleaned = cleaned
            self.audio = audio
        }
    }

    private var stored: [Entry] = []

    public init() {}

    /// Newest first.
    public func entries() -> [Entry] {
        stored
    }

    public func remember(raw: String, cleaned: String?, audio: URL?) {
        // Order matters. The previous newest gives up its file first, then the new entry goes
        // in, then the tail is trimmed. Trimming first could carry an entry out of the ring
        // while it still owned a file, and nothing would ever delete it.
        releaseAudio()
        stored.insert(Entry(raw: raw, cleaned: cleaned, audio: audio), at: 0)
        if stored.count > Self.capacity {
            stored.removeLast(stored.count - Self.capacity)
        }
    }

    /// Deletes the held recording, if any. Texts are untouched: they are the safety net and
    /// outlive the coordinator, while the audio belongs to it.
    public func discardAudio() {
        releaseAudio()
    }

    private func releaseAudio() {
        guard let index = stored.firstIndex(where: { $0.audio != nil }) else { return }
        if let url = stored[index].audio {
            try? FileManager.default.removeItem(at: url)
        }
        stored[index].audio = nil
    }
}
```

Удалить `Features/Dictation/LastDictation.swift` и `Tests/DictationTests/LastDictationTests.swift`.

- [ ] **Шаг 4: Тесты хранилища проходят**

Run: `swift test --filter RecentDictations`
Expected: PASS, восемь тестов

- [ ] **Шаг 5: Подключить в координаторе**

`Features/Dictation/DictationCoordinator.swift`:

Заменить `private let lastDictation = LastDictation()` на `private let recent: RecentDictations`, добавить параметр в `init` рядом с `inserter` и присвоить его.

```swift
        recent: RecentDictations,
```

```swift
        self.recent = recent
```

Ветка `.remember` становится синхронной — хранилище теперь на главном акторе:

```swift
        case .remember(let raw, let cleaned):
            let audio = audioURL
            audioURL = nil
            recent.remember(raw: raw, cleaned: cleaned, audio: audio)
```

Обратите внимание: `guard let audio = audioURL else { break }` больше не нужен. Запись без аудио — валидный случай, а не повод потерять текст.

В `stop()` заменить очистку хранилища на удаление только аудио:

```swift
        // The texts are the owner's safety net and must survive a config reload; the recording
        // belongs to this coordinator and must not outlive it.
        recent.discardAudio()
```

- [ ] **Шаг 6: Передать хранилище из `AppDelegate`**

`App/AppDelegate.swift` — рядом с `private let panel = DictationPanel()`:

```swift
    /// Owned here rather than by the coordinator: a config reload rebuilds the coordinator, and
    /// the owner's last ten dictations must not vanish with it.
    private let recent = RecentDictations()
```

и в вызов `DictationCoordinator(...)` добавить `recent: recent,` рядом с `inserter:`.

- [ ] **Шаг 7: Сборка и весь набор тестов**

Run: `swift build && swift test && swift build -c release --product NoHandsApp`
Expected: PASS, всё чисто, предупреждений не прибавилось

- [ ] **Шаг 8: Коммит**

```bash
git add Features/Dictation App/AppDelegate.swift Tests/DictationTests
git commit -m "Кольцо последних диктовок вместо одной, хранилище переезжает в AppDelegate"
```

---

### Задача 2: Подменю «Последние диктовки»

Соответствует разделу 3 спеки. Кольцо есть, но добраться до него нельзя.

**Files:**
- Create: `Features/Dictation/MenuTitle.swift`
- Modify: `App/StatusMenu.swift`, `App/AppDelegate.swift`
- Test: `Tests/DictationTests/MenuTitleTests.swift`

**Interfaces:**
- Consumes: `RecentDictations.entries() -> [Entry]`, `Entry.inserted`, `Entry.wasCleaned`.
- Produces: `public enum MenuTitle { static func short(_ text: String, limit: Int = 60) -> String }`. `StatusMenu.init` получает первым параметром `recent: RecentDictations`.

- [ ] **Шаг 1: Написать падающие тесты**

`Tests/DictationTests/MenuTitleTests.swift`:

```swift
import Foundation
import Testing
@testable import Dictation

@Test func shortTextIsLeftAlone() {
    #expect(MenuTitle.short("Привет.") == "Привет.")
}

// A newline inside an NSMenuItem title breaks the row's layout, and dictated text is full of
// them once cleanup has added punctuation.
@Test func newlinesAndRunsOfSpacesCollapse() {
    #expect(MenuTitle.short("первая строка\nвторая   строка") == "первая строка вторая строка")
}

@Test func longTextIsCutWithAnEllipsis() {
    let text = String(repeating: "а", count: 100)
    let title = MenuTitle.short(text, limit: 10)
    #expect(title == "аааааааааа…")
}

@Test func aTextExactlyAtTheLimitIsNotCut() {
    let text = String(repeating: "а", count: 10)
    #expect(MenuTitle.short(text, limit: 10) == text)
}

// Cutting mid-word can leave a trailing space before the ellipsis, which reads as a typo.
@Test func theCutDoesNotLeaveATrailingSpace() {
    #expect(MenuTitle.short("абвг де", limit: 5) == "абвг…")
}

@Test func emptyTextStaysEmpty() {
    #expect(MenuTitle.short("") == "")
}
```

- [ ] **Шаг 2: Убедиться, что тесты падают**

Run: `swift test --filter MenuTitle`
Expected: FAIL — `cannot find 'MenuTitle' in scope`

- [ ] **Шаг 3: Реализовать обрезку**

`Features/Dictation/MenuTitle.swift`:

```swift
import Foundation

/// Turns a dictation into one line short enough to read from a menu.
///
/// Two rules, both learned from what dictated text actually looks like: it contains newlines
/// once cleanup has punctuated it, and a newline inside an `NSMenuItem` title breaks the row's
/// layout; and a cut that lands mid-phrase can leave a trailing space before the ellipsis,
/// which reads as a typo rather than as a truncation.
public enum MenuTitle {
    public static func short(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
```

- [ ] **Шаг 4: Тесты проходят**

Run: `swift test --filter MenuTitle`
Expected: PASS, шесть тестов

- [ ] **Шаг 5: Добавить подменю**

`App/StatusMenu.swift` — новый параметр в `init`, новое поле, новый пункт и делегат.

```swift
    private let recentDelegate: RecentMenuDelegate

    init(
        recent: RecentDictations,
        onQuit: @escaping () -> Void,
        onReloadConfig: @escaping () -> Void
    ) {
```

Внутри `init`, после `statusLine`, но до сборки меню:

```swift
        recentDelegate = RecentMenuDelegate(recent: recent)
        let recentMenu = NSMenu()
        // Rebuilt every time it opens, so it never shows a stale list.
        recentMenu.delegate = recentDelegate
        let recentItem = NSMenuItem(title: "Последние диктовки", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
```

и в сборке меню, сразу после `menu.addItem(.separator())`, идущего за строкой состояния:

```swift
        menu.addItem(recentItem)
        menu.addItem(.separator())
```

Новый тип в том же файле, рядом с `Actions`:

```swift
    /// Fills the recent-dictations submenu when it opens. A separate object because
    /// `NSMenuDelegate` needs an Objective-C class, and because this one owns the store while
    /// `Actions` owns the singleton callbacks.
    @MainActor
    final class RecentMenuDelegate: NSObject, NSMenuDelegate {
        private let recent: RecentDictations

        init(recent: RecentDictations) {
            self.recent = recent
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let entries = recent.entries()
            guard !entries.isEmpty else {
                let empty = NSMenuItem(title: "пока ничего", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for entry in entries {
                // Without this the rough text of a failed cleanup looks like a recognition bug.
                let suffix = entry.wasCleaned ? "" : " · без чистки"
                let item = NSMenuItem(
                    title: MenuTitle.short(entry.inserted) + suffix,
                    action: #selector(copyEntry(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                // The menu shows a shortened line; the clipboard gets the whole thing.
                item.representedObject = entry.inserted
                menu.addItem(item)
            }
        }

        @objc private func copyEntry(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
```

**Разрешённая правка, если компилятор потребует.** `NSMenuDelegate` может не быть помечен `@MainActor` в этом SDK. Тогда `menuNeedsUpdate` объявляется `nonisolated`, а тело оборачивается в `MainActor.assumeIsolated { ... }` — так же, как это уже сделано в `DictationCoordinator` для таймера и доставки событий клавиатуры. Скажите об этом в отчёте.

- [ ] **Шаг 6: Передать хранилище в меню**

`App/AppDelegate.swift` — в обоих местах, где создаётся `StatusMenu`, добавить первым аргументом `recent: recent`.

- [ ] **Шаг 7: Сборка и тесты**

Run: `swift build && swift test && swift build -c release --product NoHandsApp`
Expected: PASS, предупреждений не прибавилось

- [ ] **Шаг 8: Проверка глазами**

Run: `./Scripts/make-app.sh && open build/NoHands.app`
Expected: в меню появилось «Последние диктовки». До первой диктовки — «пока ничего». После диктовки там строка с началом текста; клик по ней кладёт полный текст в буфер обмена. Если микрофона нет, шаг остаётся за владельцем.

- [ ] **Шаг 9: Коммит**

```bash
git add Features/Dictation/MenuTitle.swift App/StatusMenu.swift App/AppDelegate.swift Tests/DictationTests/MenuTitleTests.swift
git commit -m "Подменю последних диктовок: клик копирует полный текст"
```

---

### Задача 3: Удаление фиксированного получателя

Соответствует разделу 4 спеки. Задача вычитающая: ни одной новой возможности, только удаление понятия, которое после смены правила ничего не определяет. Компилятор проведёт по всем местам сам.

**Files:**
- Delete: `Features/Dictation/TargetApp.swift`, `Tests/DictationTests/TextInserterTests.swift`
- Modify: `Features/Dictation/DictationMachine.swift`, `Features/Dictation/PanelState.swift`, `Features/Dictation/TextInserter.swift`, `Features/Dictation/DictationCoordinator.swift`, `App/PanelView.swift`, `Tests/DictationTests/DictationMachineTests.swift`

**Interfaces:**
- Produces: `PanelState` без ассоциированных значений получателя — `.recording(latched: Bool)`, `.transcribing`, `.cleaning`, `.inserting(cleanupSkipped: String?)`, `.failure(String)`. `DictationMachine.Event.fnDown(at: Date)`. `DictationMachine.Effect.insert(text: String, cleaned: Bool)`. `TextInserter.insert(_ text: String) async throws`.

- [ ] **Шаг 1: Убрать получателя из состояний панели**

`Features/Dictation/PanelState.swift` — заменить перечисление целиком:

```swift
import Foundation

/// What the panel is showing. Structure only — no wording: the interface speaks Russian and
/// that belongs to the `App` target, while everything here has to stay testable on its own.
///
/// Carries no target application. The text goes wherever focus is when it is pasted, so the
/// panel shows the live frontmost application, which the `App` target tracks itself — see the
/// decisions log for 2026-09-03.
public enum PanelState: Equatable, Sendable {
    case recording(latched: Bool)
    case transcribing
    case cleaning
    /// `cleanupSkipped` carries the reason cleanup did not happen, or nil when it did.
    case inserting(cleanupSkipped: String?)
    case failure(String)
}
```

- [ ] **Шаг 2: Убрать получателя из автомата**

`Features/Dictation/DictationMachine.swift` — четыре группы правок.

Состояния теряют получателя:

```swift
        case recording(mode: Mode, since: Date, announced: Bool)
        case stopping
        case transcribing
        case cleaning(raw: String)
        case inserting(cleanupSkipped: String?)
```

Событие теряет получателя:

```swift
        case fnDown(at: Date)
```

Эффект теряет цель:

```swift
        case insert(text: String, cleaned: Bool)
```

Приватный помощник теряет параметр:

```swift
    private mutating func stopRecording() -> [Effect] {
        state = .stopping
        return [.stopRecording, .swallow(space: false, escape: true), .show(.transcribing)]
    }
```

Дальше компилятор укажет на каждую ветку `handle`: из образцов уходит связывание `let target`, из вызовов `stopRecording(target:)` — аргумент, из `.show(...)` и `.insert(...)` — метка получателя. Ни одна ветка не меняет поведения: удаляется только переносимое значение.

- [ ] **Шаг 3: Убрать активацию из вставки**

`Features/Dictation/TextInserter.swift`:

- Удалить вложенное перечисление `ActivationPlan` целиком.
- Удалить случаи `targetNotRunning` и `targetDidNotComeForward` из `InsertionError` вместе с их строками в `errorDescription`.
- Удалить метод `bringToFront(_:)` и константу `activationTimeout`.
- Заменить сигнатуру и убрать вызов активации:

```swift
    /// Pastes into whatever has focus right now.
    ///
    /// There is no target to bring forward: the text goes where the owner is looking at the
    /// moment it lands, which is the rule as of 2026-09-03. Everything else about the paste is
    /// unchanged — the clipboard is borrowed and given back.
    public func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        copy(text)
        let written = pasteboard.changeCount

        // The text reaches the pasteboard before the permission is checked, and stays there if
        // the check fails. Without the permission nothing can be pasted anyway, and throwing
        // first would lose the dictation outright.
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityDenied }

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
```

Удалить `Tests/DictationTests/TextInserterTests.swift` — он весь про `ActivationPlan`.

- [ ] **Шаг 4: Поправить координатор**

`Features/Dictation/DictationCoordinator.swift`:

```swift
        case .fnDown:
            apply(.fnDown(at: now))
```

```swift
        case .insert(let text, _):
            run { [inserter] in
                do {
                    try await inserter.insert(text)
                    return .inserted
                } catch {
                    return .insertionFailed(error.localizedDescription)
                }
            }
```

Удалить статический метод `frontmostApp()` целиком и импорт `AppKit`, если после этого он больше ничем не нужен в файле.

- [ ] **Шаг 5: Поправить панель**

`App/PanelView.swift` — удаляются вычисляемое свойство `target`, метод `icon(for:)` и весь блок, рисующий иконку и имя приложения. **Временно, до задачи 4, приложение в панели не показывается вовсе** — живое активное приложение приходит следующей задачей.

Свойство `caption` теряет получателя из образцов:

```swift
    private var caption: String {
        switch model.state {
        case .transcribing: return "распознаю"
        case .cleaning: return "чищу"
        case .inserting(let skipped):
            guard let skipped else { return "вставляю" }
            return "вставляю без чистки: \(skipped)"
        case .failure(let message): return message
        case .recording, nil: return ""
        }
    }
```

Ветка с уровнем звука подстраивается под новую форму состояния:

```swift
            if case .recording(let latched) = model.state {
                Levels(values: model.levels)
                if latched {
                    Text("фиксация")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
```

Красная строка отказа и `isFailure` остаются как есть.

- [ ] **Шаг 6: Привести тесты автомата к новой форме**

`Tests/DictationTests/DictationMachineTests.swift`: удалить `private let target = TargetApp(...)`, из каждого `.fnDown(at:target:)` убрать аргумент, из каждого ожидаемого `.show(...)` и `.insert(...)` убрать метку получателя.

Компилятор перечислит все места до единого. **Ни одно утверждение не ослабляется**: каждый тест по-прежнему сравнивает список эффектов целиком через `==`, из списков уходит только переносимое значение.

- [ ] **Шаг 7: Сборка и весь набор тестов**

Run: `swift build && swift test && swift build -c release --product NoHandsApp`
Expected: PASS. Число тестов уменьшится на четыре — столько было в удалённом `TextInserterTests`.

- [ ] **Шаг 8: Коммит**

```bash
git add Features/Dictation App/PanelView.swift Tests/DictationTests
git commit -m "Получатель определяется в момент вставки: TargetApp и активация удалены"
```

---

### Задача 4: Панель всегда над доком, активное приложение живьём

Соответствует разделам 5 и 4 спеки. Панель перестаёт исчезать и начинает показывать то приложение, которое активно сейчас, — а не то, которого больше нет в модели.

**Files:**
- Modify: `App/DictationPanel.swift`, `App/PanelModel.swift`, `App/PanelView.swift`, `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `PanelState` без получателя (задача 3).
- Produces: `DictationPanel.setFrontmost(name: String?, icon: NSImage?)`. `PanelModel` получает `@Published var frontmostName: String?` и `@Published var frontmostIcon: NSImage?`.

- [ ] **Шаг 1: Модель узнаёт про активное приложение**

`App/PanelModel.swift` — два новых свойства:

```swift
    /// The application that will receive the text, tracked live rather than captured: the
    /// paste goes wherever focus is when it lands, so anything captured earlier would be a
    /// guess the panel presented as fact.
    @Published var frontmostName: String?
    @Published var frontmostIcon: NSImage?
```

- [ ] **Шаг 2: Панель перестаёт исчезать**

`App/DictationPanel.swift`.

В конце `init`, после `panel.contentView = ...`:

```swift
        // Shown from launch and never ordered out again: the collapsed strip above the Dock is
        // how the owner knows the application is running at all. Nothing there means nothing is
        // listening.
        position()
        panel.orderFrontRegardless()
```

`hide(after:)` больше не убирает окно, а сворачивает содержимое:

```swift
    /// Collapses the panel back to its resting strip. The window itself stays on screen — see
    /// `init`.
    func hide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.state = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
```

Новый метод рядом с `setLevel`:

```swift
    func setFrontmost(name: String?, icon: NSImage?) {
        model.frontmostName = name
        model.frontmostIcon = icon
    }
```

- [ ] **Шаг 3: Свёрнутый вид**

`App/PanelView.swift` — тело представления начинается с развилки:

```swift
    var body: some View {
        Group {
            if model.state == nil {
                resting
            } else {
                active
            }
        }
    }

    /// The resting strip: just enough to say the application is alive.
    private var resting: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
```

Существующий `HStack` переезжает в `private var active: some View` без изменений, кроме одного: имя и иконка приложения берутся из модели, а не из состояния.

```swift
            if let name = model.frontmostName {
                icon
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
```

```swift
    private var icon: some View {
        Group {
            if let image = model.frontmostIcon {
                Image(nsImage: image).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
        }
    }
```

- [ ] **Шаг 4: Подписка на смену активного приложения**

`App/AppDelegate.swift` — в `applicationDidFinishLaunching`, до сборки координатора:

```swift
        // The frontmost application is read live rather than captured, so the panel can never
        // name a receiver that stopped being one. `NSWorkspace` posts on its own notification
        // centre, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [panel] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                panel.setFrontmost(name: app?.localizedName, icon: app?.icon)
            }
        }
        let current = NSWorkspace.shared.frontmostApplication
        panel.setFrontmost(name: current?.localizedName, icon: current?.icon)
```

**Разрешённая правка.** Если Swift 6 не примет `MainActor.assumeIsolated` внутри блока наблюдателя из-за захвата `notification`, вытащите нужные значения до входа в блок изоляции — так же, как в `FnKeyMonitor` вытаскивается `event.flags` перед взятием замка. Скажите об этом в отчёте.

- [ ] **Шаг 5: Сборка и тесты**

Run: `swift build && swift test && swift build -c release --product NoHandsApp`
Expected: PASS, предупреждений не прибавилось

- [ ] **Шаг 6: Проверка глазами**

Run: `./Scripts/make-app.sh && open build/NoHands.app`

Expected по пунктам:
- Сразу после запуска внизу по центру появилась узкая плашка с микрофоном и не исчезает.
- Переключение между приложениями плашку не трогает — она свёрнута.
- Во время диктовки панель разворачивается, имя и иконка приложения меняются **вслед за переключением окна**, пока идёт запись.
- После вставки панель сворачивается обратно в плашку, а не исчезает.
- Плашка не перехватывает клики: по тому, что под ней, можно кликнуть.

- [ ] **Шаг 7: Коммит**

```bash
git add App
git commit -m "Панель всегда над доком, активное приложение показывается живьём"
```

---

### Задача 5: Предупреждение об узкой полосе

Соответствует разделу 6 спеки. `DESIGN.md` обещает эту проверку в таблице рисков; в CLI она есть с фазы 0, в приложении её нет. Поймано на живой диктовке через AirPods Pro: 24 кГц при пороге 32 кГц.

**Files:**
- Modify: `Core/Audio/AudioInputDevice.swift`, `Features/Dictation/DictationCoordinator.swift`, `App/PanelModel.swift`, `App/PanelView.swift`, `App/DictationPanel.swift`, `App/AppDelegate.swift`, `CLI/NoHands.swift`
- Test: `Tests/CoreTests/AudioInputDeviceTests.swift`

**Interfaces:**
- Produces: `AudioInputDevice.narrowbandThreshold: Double` и `AudioInputDevice.isNarrowband: Bool`. `DictationCoordinator.init` получает параметр `onNarrowbandInput: @escaping (Double?) -> Void`. `DictationPanel.setInputWarning(hz: Double?)`.

- [ ] **Шаг 1: Написать падающий тест**

Дописать в `Tests/CoreTests/AudioInputDeviceTests.swift`:

```swift
// The threshold is the one the CLI has used since phase 0. Below it macOS has put the input
// into its narrowband mode — which is what a Bluetooth headset's microphone does to the whole
// device — and DESIGN.md calls that the worst input this application can have.
@Test func theNarrowbandThresholdIsThirtyTwoKilohertz() {
    #expect(AudioInputDevice.narrowbandThreshold == 32000)
}

@Test func aBluetoothRateIsNarrowband() {
    let device = AudioInputDevice(name: "AirPods", sampleRate: 24000, channelCount: 1)
    #expect(device.isNarrowband)
}

@Test func aFullRateDeviceIsNot() {
    let device = AudioInputDevice(name: "USB", sampleRate: 48000, channelCount: 1)
    #expect(!device.isNarrowband)
}

// Exactly at the threshold counts as fine: the boundary belongs to the good side, the same way
// the CLI has always treated it.
@Test func exactlyAtTheThresholdIsNotNarrowband() {
    let device = AudioInputDevice(name: "порог", sampleRate: 32000, channelCount: 1)
    #expect(!device.isNarrowband)
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Run: `swift test --filter AudioInputDevice`
Expected: FAIL — `type 'AudioInputDevice' has no member 'narrowbandThreshold'`

- [ ] **Шаг 3: Реализовать порог**

`Core/Audio/AudioInputDevice.swift` — дописать в структуру:

```swift
    /// Below this rate macOS has switched the input into its narrowband mode. A Bluetooth
    /// headset does that to the whole audio device the moment its microphone is used, and
    /// `DESIGN.md` names that the worst input this application can have: the top of the
    /// spectrum is gone, and the top is where similar consonants differ.
    public static let narrowbandThreshold: Double = 32000

    public var isNarrowband: Bool {
        sampleRate < Self.narrowbandThreshold
    }
```

- [ ] **Шаг 4: Тест проходит**

Run: `swift test --filter AudioInputDevice`
Expected: PASS

- [ ] **Шаг 5: Координатор сообщает частоту**

`Features/Dictation/DictationCoordinator.swift` — новое поле, новый параметр `init` рядом с `onLevel`, и вызов в `startRecording()`.

```swift
    /// The input's sample rate when it is below the narrowband threshold, and nil when the band
    /// is fine. Reported once, at the start of each recording. A fact rather than a sentence:
    /// interface wording belongs to the `App` target.
    private let onNarrowbandInput: (Double?) -> Void
```

В самом начале `startRecording()`, до создания временного файла:

```swift
        onNarrowbandInput(
            AudioInputDevice.current().flatMap { $0.isNarrowband ? $0.sampleRate : nil }
        )
```

- [ ] **Шаг 6: Панель показывает предупреждение**

`App/PanelModel.swift`:

```swift
    /// Sample rate of the input when it is narrowband, nil otherwise.
    @Published var narrowbandHz: Double?
```

`App/DictationPanel.swift` — новый метод рядом с `setFrontmost`, и та строка в `hide(after:)`, которую задача 4 просила отложить:

```swift
    func setInputWarning(hz: Double?) {
        model.narrowbandHz = hz
    }
```

```swift
            self?.model.narrowbandHz = nil
```

`App/PanelView.swift` — в `active`, сразу после имени приложения:

```swift
            if let hz = model.narrowbandHz {
                Text("узкая полоса, \(Int(hz / 1000)) кГц")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
```

`App/AppDelegate.swift` — в вызов `DictationCoordinator(...)`:

```swift
                onNarrowbandInput: { [panel] hz in panel.setInputWarning(hz: hz) },
```

- [ ] **Шаг 7: CLI пользуется общим порогом**

`CLI/NoHands.swift` — в `narrowbandWarning(sampleRate:)` заменить литерал на константу:

```swift
    guard sampleRate < AudioInputDevice.narrowbandThreshold else { return nil }
```

Текст предупреждения не трогать: у CLI своя формулировка, длинная, и она остаётся.

- [ ] **Шаг 8: Сборка и весь набор тестов**

Run: `swift build && swift test && swift build -c release --product NoHandsApp`
Expected: PASS, предупреждений не прибавилось

- [ ] **Шаг 9: Проверка глазами**

Run: `./Scripts/make-app.sh && open build/NoHands.app`

Expected: с USB-микрофоном или встроенным входом на 48 кГц панель во время записи выглядит как раньше. С надетой Bluetooth-гарнитурой рядом с именем приложения появляется оранжевое «узкая полоса, 24 кГц», а запись при этом идёт как обычно — ничего не блокируется. Требует гарнитуры, поэтому шаг за владельцем.

- [ ] **Шаг 10: Коммит**

```bash
git add Core/Audio App CLI Features/Dictation/DictationCoordinator.swift Tests/CoreTests/AudioInputDeviceTests.swift
git commit -m "Предупреждение об узкополосном входе в панели"
```

---

## Приёмка

- [ ] Продиктовать пять раз подряд, открыть меню — в «Последних диктовках» пять строк, новейшая сверху, клик по каждой кладёт полный текст в буфер
- [ ] Отключить сеть, продиктовать — строка в меню помечена «· без чистки»
- [ ] «Перечитать конфиг» — история на месте, диктовка работает
- [ ] Начать диктовку, переключиться в другое окно, отпустить fn — текст пришёл в то окно, где фокус сейчас
- [ ] Плашка над доком видна всё время, пока приложение запущено, и исчезает после «Выход»
- [ ] `ls "$TMPDIR"nohands-dictation-*.wav | wc -l` после десяти диктовок — ровно один файл
