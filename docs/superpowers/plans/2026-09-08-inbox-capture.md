# Лоток входящих — захват. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fn+C кладёт выделенный текст из любого приложения в папку `~/Inbox` вместе с источником и временем, перетаскивание файла на панель добавляет вложение, а скилл разбирает накопленное в задачи Todoist.

**Architecture:** Новый таргет `Inbox` (`Features/Inbox`) поверх `Core` держит всю работу с папкой, файлом и панелью входящих; он не знает ни про клавиатуру, ни про Todoist. Клавиша живёт там же, где остальные клавиши приложения: `KeyEventReader` учится распознавать fn+C, `DictationMachine` получает событие `.captureDown` и эффект `.capture`, а `DictationCoordinator` исполняет эффект вызовом закрытия, которое `AppDelegate` направляет в `InboxCoordinator`. Разбор входящих кодом не пишется вовсе — он скилл.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 15, AppKit, SwiftUI, swift-testing (`@Test`/`#expect`). Новых внешних зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-09-07-inbox-capture-design.md`

## Global Constraints

- Новых зависимостей SPM не добавляем. Всё делается на системных фреймворках.
- Идентификаторы, комментарии в коде и сообщения об ошибках — по-английски. Тексты на панели, коммиты и документация — по-русски.
- Содержимое захваченного текста никогда не логируется и не печатается. Ни в `print`, ни в сообщении об ошибке, ни в тесте, который что-то выводит.
- Ключи API только в Keychain. Токен Todoist читает скилл через `security`, в Swift-коде его нет.
- Тест раньше кода. Каждая задача кончается зелёным `swift test` и коммитом.
- Базовая линия перед началом: **495 тестов, 0 падений** (`swift test`, exit 0).
- Платформа пакета — `.macOS(.v15)`, менять её нельзя.
- Пустая папка входящего не создаётся никогда: неудачный захват не оставляет следов.
- `~/Inbox` в гит не попадает, как и `~/Meetings`. Ни один тест не пишет в настоящий `~/Inbox` и ни один тест не трогает `NSPasteboard.general`.

---

### Task 1: Экранирование фронтматтера переезжает в свой файл

Правило экранирования значения фронтматтера написано внутри `MeetingMarkdown` и там же спрятано (`internal`). Входящее пишет такой же фронтматтер с таким же именем приложения из `NSRunningApplication`. Одно правило на один архив — значит его надо достать наружу до того, как появится второй его экземпляр.

**Files:**
- Create: `Core/Transcript/Frontmatter.swift`
- Modify: `Core/Transcript/MeetingMarkdown.swift` (удалить `quoted`, вызвать `Frontmatter.quoted` в строке 27)
- Modify: `Core/Summary/SummaryInsertion.swift:72` (`MeetingMarkdown.quoted` → `Frontmatter.quoted`)
- Test: `Tests/CoreTests/FrontmatterTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces: `public enum Frontmatter { public static func quoted(_ value: String) -> String }` в модуле `Core`.

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CoreTests/FrontmatterTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

@Test func aPlainValueIsQuoted() {
    #expect(Frontmatter.quoted("Telegram") == "\"Telegram\"")
}

// Настоящее имя приложения ничем не ограничено: `Яндекс Телемост` приехало в архив фазы 2б
// именно так, с пробелом.
@Test func aNameWithASpaceStaysOneValue() {
    #expect(Frontmatter.quoted("Яндекс Телемост") == "\"Яндекс Телемост\"")
}

@Test func quotesAndBackslashesAreEscaped() {
    #expect(Frontmatter.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

// Перевод строки внутри значения разорвал бы блок `---` для Obsidian и для всего, что этот
// файл потом перечитывает.
@Test func controlCharactersAreDropped() {
    #expect(Frontmatter.quoted("a\nb\tc") == "\"abc\"")
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter FrontmatterTests`
Expected: сборка не проходит — `cannot find 'Frontmatter' in scope`.

- [ ] **Step 3: Написать реализацию**

Создать `Core/Transcript/Frontmatter.swift`:

```swift
import Foundation

/// Escaping for one value inside a YAML front matter line.
///
/// Written first for the display name of whatever application held the audio devices, and
/// pulled out here because the inbox writes the same kind of value into the same kind of block:
/// a name straight from `NSRunningApplication`, an address straight from a browser. One archive,
/// one escaping rule.
public enum Frontmatter {
    /// A colon or a newline in the value would break the `---` block for Obsidian and for
    /// anything that re-reads the file. Quoted and escaped rather than trusted — the archive
    /// outlives every assumption about what applications are called.
    public static func quoted(_ value: String) -> String {
        var cleaned = ""
        for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            cleaned.append(Character(scalar))
        }
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
```

- [ ] **Step 4: Перевести оба места вызова на новое имя**

В `Core/Transcript/MeetingMarkdown.swift` заменить строку

```swift
        if let appName { lines.append("app: \(quoted(appName))") }
```

на

```swift
        if let appName { lines.append("app: \(Frontmatter.quoted(appName))") }
```

и удалить весь метод `static func quoted(_ value: String) -> String` вместе с его докблоком (строки 39–58 исходного файла): правило переехало целиком, копия в двух местах — ровно то, ради чего эта задача делается.

В `Core/Summary/SummaryInsertion.swift` заменить

```swift
            front.insert("title: \(MeetingMarkdown.quoted(summary.title))", at: front.count - 1)
```

на

```swift
            front.insert("title: \(Frontmatter.quoted(summary.title))", at: front.count - 1)
```

- [ ] **Step 5: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 499 тестов (было 495, добавлено 4). Существующие `MeetingMarkdownTests` и `SummaryInsertionTests` зелёные — они проверяют то же поведение через `render` и через вставку.

- [ ] **Step 6: Коммит**

```bash
git add Core/Transcript/Frontmatter.swift Core/Transcript/MeetingMarkdown.swift Core/Summary/SummaryInsertion.swift Tests/CoreTests/FrontmatterTests.swift
git commit -m "Экранирование фронтматтера вынесено в Frontmatter"
```

---

### Task 2: `PasteboardSnapshot` переезжает в `Core`

Захват заимствует буфер обмена ровно так же, как вставка: снимок, своё содержимое, возврат чужого. Снимок лежит в таргете `Dictation`, а нужен он будет таргету `Inbox`. Зависимость одной фичи от другой была бы неправильным ответом — это утилита уровня `Core`.

**Files:**
- Move: `Features/Dictation/PasteboardSnapshot.swift` → `Core/Input/PasteboardSnapshot.swift`
- Move: `Tests/DictationTests/PasteboardSnapshotTests.swift` → `Tests/CoreTests/PasteboardSnapshotTests.swift`
- Modify: `Features/Dictation/TextInserter.swift` (добавить `import Core`)

**Interfaces:**
- Consumes: ничего.
- Produces: `PasteboardSnapshot` в модуле `Core` — API не меняется: `capture(_:)`, `restore(to:)`, `shouldRestore(writtenChangeCount:currentChangeCount:)`.

- [ ] **Step 1: Убедиться, что снимком пользуется только вставка**

Run: `grep -rn "PasteboardSnapshot" Core Features App CLI Tests`
Expected: `Features/Dictation/PasteboardSnapshot.swift`, `Features/Dictation/TextInserter.swift`, `Tests/DictationTests/PasteboardSnapshotTests.swift` — и больше ничего. Если найдётся что-то ещё, этому месту тоже понадобится `import Core`.

- [ ] **Step 2: Перенести файлы**

```bash
mkdir -p Core/Input
git mv Features/Dictation/PasteboardSnapshot.swift Core/Input/PasteboardSnapshot.swift
git mv Tests/DictationTests/PasteboardSnapshotTests.swift Tests/CoreTests/PasteboardSnapshotTests.swift
```

- [ ] **Step 3: Починить импорты**

В `Tests/CoreTests/PasteboardSnapshotTests.swift` заменить

```swift
@testable import Dictation
```

на

```swift
@testable import Core
```

В `Features/Dictation/TextInserter.swift` добавить `import Core` в список импортов (первым, порядок в файле алфавитный: `AppKit`, `ApplicationServices`, `Core`, `CoreGraphics`, `Foundation`).

- [ ] **Step 4: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 499 тестов. Число не меняется — тесты переехали, а не добавились.

- [ ] **Step 5: Коммит**

```bash
git add -A
git commit -m "PasteboardSnapshot переезжает в Core"
```

---

### Task 3: Таргет `Inbox` и папка одного входящего

Первый кусок самого лотка: как называется папка и как она создаётся. Форма имени повторяет `MeetingFolder` — тот же `yyyy-MM-dd-HHmm-слаг` по местному времени, тот же суффикс при столкновении. Два архива с двумя правилами именования были бы лишним, что надо помнить.

**Files:**
- Create: `Features/Inbox/InboxFolder.swift`
- Create: `Tests/InboxTests/InboxFolderTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public enum InboxFolder`
  - `public static var rootURL: URL` — `~/Inbox`
  - `public static func slug(forBundleID bundleID: String) -> String`
  - `public static func baseName(capturedAt: Date, slug: String) -> String`
  - `public static func create(in root: URL, capturedAt: Date, slug: String, fileManager: FileManager = .default) throws -> URL`

- [ ] **Step 1: Завести таргет в манифесте**

В `Package.swift`:

в `products` после строки с `Dictation` добавить

```swift
        .library(name: "Inbox", targets: ["Inbox"]),
```

в `targets` после таргета `Dictation` добавить

```swift
        .target(
            name: "Inbox",
            dependencies: ["Core"],
            path: "Features/Inbox"
        ),
```

в тест-таргеты после `DictationTests` добавить

```swift
        .testTarget(
            name: "InboxTests",
            dependencies: ["Inbox"],
            path: "Tests/InboxTests"
        ),
```

и в зависимости исполняемого таргета `App` добавить `"Inbox"`, то есть

```swift
            dependencies: ["Core", "Dictation", "Inbox", "Meetings"],
```

CLI трогать не нужно: у лотка нет команд.

- [ ] **Step 2: Написать падающий тест**

Создать `Tests/InboxTests/InboxFolderTests.swift`:

```swift
import Foundation
import Testing
@testable import Inbox

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func theSlugIsTheLastComponentOfTheBundleIdentifier() {
    #expect(InboxFolder.slug(forBundleID: "ru.keepcoder.Telegram") == "telegram")
    #expect(InboxFolder.slug(forBundleID: "com.apple.Safari") == "safari")
}

// `NSRunningApplication.bundleIdentifier` is optional, and a folder whose name ends in a dash
// would be the visible shape of that fact.
@Test func anApplicationWithoutAnIdentifierStillGetsASlug() {
    #expect(InboxFolder.slug(forBundleID: "") == "app")
}

@Test func theFolderIsNamedByDateTimeAndSlug() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    #expect(folder.lastPathComponent.hasSuffix("-telegram"))
    #expect(folder.lastPathComponent == InboxFolder.baseName(capturedAt: noon, slug: "telegram"))
    #expect(FileManager.default.fileExists(atPath: folder.path))
}

// Two captures out of the same chat inside one minute is the ordinary case, not the exotic one.
@Test func aSecondCaptureInTheSameMinuteGetsASuffix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let second = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    #expect(second.lastPathComponent == first.lastPathComponent + "-2")
    #expect(FileManager.default.fileExists(atPath: second.path))
}

@Test func theRootIsInboxInTheHomeDirectory() {
    #expect(InboxFolder.rootURL.lastPathComponent == "Inbox")
    #expect(InboxFolder.rootURL.deletingLastPathComponent().path
        == FileManager.default.homeDirectoryForCurrentUser.path)
}
```

- [ ] **Step 3: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxFolderTests`
Expected: сборка не проходит — `no such module 'Inbox'` или `cannot find 'InboxFolder' in scope`.

- [ ] **Step 4: Написать реализацию**

Создать `Features/Inbox/InboxFolder.swift`:

```swift
import Foundation

/// Names and creates the folder of one captured item.
///
/// Shaped after `MeetingFolder` deliberately: the same `yyyy-MM-dd-HHmm-slug` in local time and
/// the same numeric suffix when two of them land in the same minute. Two archives on one disk
/// with two naming rules would be one more thing to remember for no gain — and the reason for
/// local time is the same one: the archive is read by a human who remembers when it happened.
///
/// Unlike a meeting there is no draft state and no dot prefix. A capture is written in one go
/// and nothing downstream waits for it, so there is nothing for an atomic hand-off to protect.
public enum InboxFolder {
    public static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Inbox")
    }

    /// The last component of a bundle identifier, lower-cased: `ru.keepcoder.Telegram` becomes
    /// `telegram`. Same rule `MeetingsConfig.TriggerApp.resolvedSlug` falls back to.
    ///
    /// `NSRunningApplication` hands back an optional identifier, so the empty case is reachable
    /// rather than defensive — and a folder named `2026-09-08-1732-` would be the shape of it.
    public static func slug(forBundleID bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return last.isEmpty ? "app" : last
    }

    public static func baseName(capturedAt: Date, slug: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(formatter.string(from: capturedAt))-\(slug)"
    }

    public static func create(
        in root: URL,
        capturedAt: Date,
        slug: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = baseName(capturedAt: capturedAt, slug: slug)
        var candidate = base
        var suffix = 1
        while fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        let folder = root.appendingPathComponent(candidate)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
```

- [ ] **Step 5: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 504 теста.

- [ ] **Step 6: Коммит**

```bash
git add Package.swift Features/Inbox Tests/InboxTests
git commit -m "Таргет Inbox и папка одного входящего"
```

---

### Task 4: Вложение копируется в папку входящего

**Files:**
- Modify: `Features/Inbox/InboxFolder.swift`
- Modify: `Tests/InboxTests/InboxFolderTests.swift`

**Interfaces:**
- Consumes: `InboxFolder.create` из задачи 3.
- Produces: `public static func copyAttachment(_ source: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL`

- [ ] **Step 1: Написать падающий тест**

Дописать в конец `Tests/InboxTests/InboxFolderTests.swift`:

```swift
private func temporaryFile(named name: String, contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(name)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}

// Copied, never moved: the source is somebody else's folder — the Telegram cache, Downloads —
// and taking a file out of it is not this application's business.
@Test func anAttachmentIsCopiedAndTheSourceStaysWhereItWas() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let source = try temporaryFile(named: "лендинг.html", contents: "<html>")
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

    let copy = try InboxFolder.copyAttachment(source, into: folder)

    #expect(copy.lastPathComponent == "лендинг.html")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "<html>")
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func aSecondAttachmentWithTheSameNameGetsASuffixAndKeepsItsExtension() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let first = try temporaryFile(named: "отчёт.pdf", contents: "один")
    let second = try temporaryFile(named: "отчёт.pdf", contents: "два")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    _ = try InboxFolder.copyAttachment(first, into: folder)
    let copy = try InboxFolder.copyAttachment(second, into: folder)

    #expect(copy.lastPathComponent == "отчёт-2.pdf")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "два")
}

@Test func aFileWithoutAnExtensionAlsoGetsASuffix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let first = try temporaryFile(named: "README", contents: "один")
    let second = try temporaryFile(named: "README", contents: "два")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    _ = try InboxFolder.copyAttachment(first, into: folder)
    #expect(try InboxFolder.copyAttachment(second, into: folder).lastPathComponent == "README-2")
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxFolderTests`
Expected: FAIL — `type 'InboxFolder' has no member 'copyAttachment'`.

- [ ] **Step 3: Написать реализацию**

Дописать в `Features/Inbox/InboxFolder.swift`, внутрь `enum InboxFolder`:

```swift
    /// Copies a dropped file into the capture's folder.
    ///
    /// Copied, never moved: the source is somebody else's folder — the Telegram cache, the
    /// Downloads folder — and carrying a file out of it is not this application's business.
    /// A name that is already taken gets the same numeric suffix a folder does, with the
    /// extension kept where it belongs so the file still opens by double-click.
    @discardableResult
    public static func copyAttachment(
        _ source: URL,
        into folder: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = source.lastPathComponent
        let ext = source.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var candidate = name
        var suffix = 1
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
        }
        let destination = folder.appendingPathComponent(candidate)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
```

- [ ] **Step 4: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 507 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Features/Inbox/InboxFolder.swift Tests/InboxTests/InboxFolderTests.swift
git commit -m "Вложение копируется в папку входящего"
```

---

### Task 5: `note.md` — фронтматтер и текст байт в байт

**Files:**
- Create: `Features/Inbox/InboxNote.swift`
- Create: `Tests/InboxTests/InboxNoteTests.swift`

**Interfaces:**
- Consumes: `Frontmatter.quoted` из задачи 1.
- Produces:
  - `public enum InboxNote`
  - `public static let fileName = "note.md"`
  - `public static func render(capturedAt: Date, appName: String?, bundleID: String?, url: String?, text: String) -> String`
  - `public static func lineCount(_ text: String) -> Int`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/InboxTests/InboxNoteTests.swift`:

```swift
import Foundation
import Testing
@testable import Inbox

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func theFrontMatterNamesTheTimeTheAppAndTheBundle() {
    let note = InboxNote.render(
        capturedAt: noon,
        appName: "Telegram",
        bundleID: "ru.keepcoder.Telegram",
        url: nil,
        text: "> Натали:\nтекст"
    )
    let lines = note.components(separatedBy: "\n")
    #expect(lines[0] == "---")
    #expect(lines[1].hasPrefix("captured: "))
    #expect(lines[2] == "app: \"Telegram\"")
    #expect(lines[3] == "bundle: ru.keepcoder.Telegram")
    #expect(lines[4] == "---")
    #expect(lines[5] == "")
}

@Test func theAddressIsWrittenOnlyWhenThereIsOne() {
    let withURL = InboxNote.render(
        capturedAt: noon,
        appName: "Safari",
        bundleID: "com.apple.Safari",
        url: "https://tracker.yandex.ru/PULSE-42",
        text: "задача"
    )
    #expect(withURL.contains("url: \"https://tracker.yandex.ru/PULSE-42\""))

    let withoutURL = InboxNote.render(
        capturedAt: noon, appName: "Telegram", bundleID: "ru.keepcoder.Telegram",
        url: nil, text: "задача"
    )
    #expect(!withoutURL.contains("url:"))
}

// The whole point of the file: whatever a model says about this text later has to stay checkable
// against what was actually copied. Nothing is cleaned, normalised or re-wrapped.
@Test func theBodyIsTheClipboardTextUnchanged() {
    let text = "> Натали:\n---\nэто не фронтматтер\n\n> Натали:\nвторое"
    let note = InboxNote.render(
        capturedAt: noon, appName: nil, bundleID: nil, url: nil, text: text
    )
    #expect(note.hasSuffix(text + "\n"))
}

@Test func aTextThatAlreadyEndsWithANewlineIsNotGivenAnother() {
    let note = InboxNote.render(
        capturedAt: noon, appName: nil, bundleID: nil, url: nil, text: "строка\n"
    )
    #expect(note.hasSuffix("строка\n"))
    #expect(!note.hasSuffix("строка\n\n"))
}

@Test func anApplicationNameWithASpaceStaysOneValue() {
    let note = InboxNote.render(
        capturedAt: noon, appName: "Яндекс Мессенджер", bundleID: "ru.yandex.messenger",
        url: nil, text: "текст"
    )
    #expect(note.contains("app: \"Яндекс Мессенджер\""))
}

// What the panel says out loud, so it is worth being a fact rather than an estimate: blank
// lines separate messages in every one of the four sources and are not lines of content.
@Test func theLineCountIgnoresBlankLines() {
    #expect(InboxNote.lineCount("> Натали:\nтекст\n\n> Натали:\nещё") == 4)
    #expect(InboxNote.lineCount("") == 0)
    #expect(InboxNote.lineCount("   \n\n") == 0)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxNoteTests`
Expected: сборка не проходит — `cannot find 'InboxNote' in scope`.

- [ ] **Step 3: Написать реализацию**

Создать `Features/Inbox/InboxNote.swift`:

```swift
import Core
import Foundation

/// The `note.md` of one captured item: front matter and the clipboard text.
///
/// The body is written byte for byte. Nothing is cleaned, normalised or parsed — the four
/// sources format their clipboard differently and will keep doing so, and a parser per source
/// would break on the first update of somebody else's application while buying nothing. What a
/// model says about this text at review time has to stay checkable against what was copied.
public enum InboxNote {
    public static let fileName = "note.md"

    public static func render(
        capturedAt: Date,
        appName: String?,
        bundleID: String?,
        url: String?,
        text: String
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("captured: \(format(capturedAt))")
        if let appName { lines.append("app: \(Frontmatter.quoted(appName))") }
        // Unquoted on purpose: a bundle identifier is issued by the system and cannot hold a
        // space, a colon or a newline. The display name right above it can hold all three.
        if let bundleID { lines.append("bundle: \(bundleID)") }
        if let url { lines.append("url: \(Frontmatter.quoted(url))") }
        lines.append("---")
        lines.append("")
        var out = lines.joined(separator: "\n") + "\n"
        out += text
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Lines of content, blank ones not counted: every one of the four sources separates
    /// messages with a blank line, so counting those would report the shape of the paste rather
    /// than how much was captured.
    public static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// Local time, matching `InboxFolder.baseName` and the meeting archive: read by a human who
    /// remembers when it happened.
    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 513 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Features/Inbox/InboxNote.swift Tests/InboxTests/InboxNoteTests.swift
git commit -m "note.md: фронтматтер и текст буфера без изменений"
```

---

### Task 6: Кто был впереди и на какой странице

Имя и идентификатор фронтового приложения берутся у `NSWorkspace`. Адрес открытой вкладки — у браузера по AppleScript, и это четвёртое системное разрешение проекта; отказ в нём означает отсутствие строки `url` и ничего больше.

**Files:**
- Create: `Features/Inbox/InboxSource.swift`
- Create: `Tests/InboxTests/InboxSourceTests.swift`
- Modify: `App/Info.plist`

**Interfaces:**
- Consumes: `InboxFolder.slug` из задачи 3.
- Produces:
  - `public struct InboxSource: Equatable, Sendable { public var appName: String?; public var bundleID: String?; public var url: String?; public var slug: String }`
  - `@MainActor public enum FrontmostSource { public static func read() -> InboxSource }`
  - `static let browsers: [String: String]` (internal, для теста)

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/InboxTests/InboxSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import Inbox

@Test func theSlugComesFromTheBundleIdentifier() {
    let source = InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil)
    #expect(source.slug == "telegram")
}

@Test func anApplicationWithoutAnIdentifierStillHasASlug() {
    #expect(InboxSource(appName: "Что-то", bundleID: nil, url: nil).slug == "app")
}

// Asking an application for its front document raises the automation consent dialog, so the
// list of who is worth asking is a closed one — and everything outside it is not a refusal,
// it is simply an application with no address to give.
@Test func onlyBrowsersAreAskedForAnAddress() {
    #expect(FrontmostSource.browsers["com.apple.Safari"] != nil)
    #expect(FrontmostSource.browsers["ru.keepcoder.Telegram"] == nil)
    #expect(FrontmostSource.browsers["ru.yandex.desktop.telemost"] == nil)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxSourceTests`
Expected: сборка не проходит — `cannot find 'InboxSource' in scope`.

- [ ] **Step 3: Написать реализацию**

Создать `Features/Inbox/InboxSource.swift`:

```swift
import AppKit
import Foundation

/// Who was in front when the hotkey fired, and — when that was a browser — what page they were
/// looking at.
public struct InboxSource: Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var url: String?

    public init(appName: String?, bundleID: String?, url: String?) {
        self.appName = appName
        self.bundleID = bundleID
        self.url = url
    }

    public var slug: String {
        InboxFolder.slug(forBundleID: bundleID ?? "")
    }
}

/// Reads the frontmost application, and its address when it has one.
@MainActor
public enum FrontmostSource {
    /// Bundle identifiers worth asking for an address, and the script that asks each one.
    ///
    /// A closed list rather than an attempt on everything: every ask raises the automation
    /// consent dialog for that application the first time, and an application that has no
    /// notion of a front document would collect a dialog for nothing.
    static let browsers: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
        "com.google.Chrome":
            "tell application \"Google Chrome\" to return URL of active tab of front window",
    ]

    public static func read() -> InboxSource {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        return InboxSource(
            appName: app?.localizedName,
            bundleID: bundleID,
            url: bundleID.flatMap(address(ofBundleID:))
        )
    }

    /// nil rather than an error on every refusal, and that is the whole permission story of this
    /// feature: the first ask raises "NoHands wants to control Safari", and a denied one has to
    /// cost the capture nothing — the note simply has no `url` line. Unlike the microphone, the
    /// screen and accessibility, this permission is not required for the feature to work.
    static func address(ofBundleID bundleID: String) -> String? {
        guard let script = browsers[bundleID] else { return nil }
        var error: NSDictionary?
        let value = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil, let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
```

- [ ] **Step 4: Объявить разрешение в бандле**

В `App/Info.plist`, после `NSScreenCaptureUsageDescription`, добавить:

```xml
    <key>NSAppleEventsUsageDescription</key>
    <string>NoHands спрашивает у браузера адрес открытой страницы, чтобы записать его во входящее.</string>
```

Без этого ключа запрос к браузеру не поднимает диалог, а роняет приложение.

- [ ] **Step 5: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 516 тестов.

- [ ] **Step 6: Коммит**

```bash
git add Features/Inbox/InboxSource.swift Tests/InboxTests/InboxSourceTests.swift App/Info.plist
git commit -m "Источник входящего: фронтовое приложение и адрес страницы"
```

---

### Task 7: Захват выделения — Cmd+C за владельца

**Files:**
- Create: `Features/Inbox/InboxCapture.swift`
- Create: `Tests/InboxTests/InboxCaptureTests.swift`

**Interfaces:**
- Consumes: `PasteboardSnapshot` из `Core` (задача 2).
- Produces:
  - `@MainActor public struct InboxCapture`
  - `public enum Failure: Error, Equatable, LocalizedError { case accessibilityDenied, eventSourceUnavailable, nothingCopied }`
  - `public init(postCopy: @escaping @MainActor () throws -> Void = InboxCapture.pressCommandC)`
  - `public func selection(from pasteboard: NSPasteboard = .general) async throws -> String`
  - `public static func pressCommandC() throws`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/InboxTests/InboxCaptureTests.swift`:

```swift
import AppKit
import Foundation
import Testing
@testable import Inbox

// Never `NSPasteboard.general`: a test suite that borrows the owner's clipboard is a test suite
// that loses it. The seam that makes this reachable at all is `postCopy` — the real one presses
// Cmd+C, and no test may do that to whatever window happens to have focus.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("nohands-inbox-test-\(UUID().uuidString)"))
}

@MainActor
@Test func theCopiedTextComesBackAndTheClipboardIsPutBack() async throws {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        pasteboard.setString("> Натали:\nвыделенное", forType: .string)
    }

    #expect(try await capture.selection(from: pasteboard) == "> Натали:\nвыделенное")
    #expect(pasteboard.string(forType: .string) == "что было")
}

// The exact race the wait exists for: `clearContents()` bumps the change counter on its own, and
// the application under us writes the data a moment later. A capture that stopped at the counter
// would come back empty whenever the poll landed inside that gap.
@MainActor
@Test func theTextIsWaitedForEvenWhenTheCounterMovesFirst() async throws {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            pasteboard.setString("догнало", forType: .string)
        }
    }

    #expect(try await capture.selection(from: pasteboard) == "догнало")
    #expect(pasteboard.string(forType: .string) == "что было")
}

// Nothing selected, or an application that does not answer Cmd+C. Named refusal, and — checked
// by the coordinator's own tests — no folder: an empty folder looks exactly like a capture that
// happened, and this one did not.
@MainActor
@Test func aCopyThatChangesNothingIsARefusal() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {}

    await #expect(throws: InboxCapture.Failure.nothingCopied) {
        try await capture.selection(from: pasteboard)
    }
    #expect(pasteboard.string(forType: .string) == "что было")
}

@MainActor
@Test func copyingNothingButWhitespaceIsAlsoARefusalAndTheClipboardComesBack() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        pasteboard.setString("   \n  ", forType: .string)
    }

    await #expect(throws: InboxCapture.Failure.nothingCopied) {
        try await capture.selection(from: pasteboard)
    }
    #expect(pasteboard.string(forType: .string) == "что было")
}

@MainActor
@Test func aFailureToPressTheKeysIsReportedAsItself() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    let capture = InboxCapture { throw InboxCapture.Failure.eventSourceUnavailable }

    await #expect(throws: InboxCapture.Failure.eventSourceUnavailable) {
        try await capture.selection(from: pasteboard)
    }
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxCaptureTests`
Expected: сборка не проходит — `cannot find 'InboxCapture' in scope`.

- [ ] **Step 3: Написать реализацию**

Создать `Features/Inbox/InboxCapture.swift`:

```swift
import AppKit
import ApplicationServices
import Core
import CoreGraphics
import Foundation

/// Reads the current selection the only way the sources allow: by pressing Cmd+C for the owner.
///
/// The spike of 7 September established there is no cheaper path. Telegram selects *messages*,
/// not text inside a field, so the system Services — which work on a text selection — never see
/// anything to act on. The clipboard is borrowed and given back exactly the way `TextInserter`
/// borrows it to paste.
@MainActor
public struct InboxCapture {
    public enum Failure: Error, Equatable, LocalizedError {
        case accessibilityDenied
        case eventSourceUnavailable
        case nothingCopied

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is not granted, so the selection cannot be copied"
            case .eventSourceUnavailable:
                return "Could not synthesize the copy keystroke"
            case .nothingCopied:
                return "Nothing was selected, or the application did not answer Cmd+C"
            }
        }
    }

    /// How often the clipboard is asked whether it has changed, and how long that goes on.
    /// The application under us reads the selection and writes it asynchronously, so there is
    /// nothing to wait on except the change counter itself.
    private static let pollInterval = Duration.milliseconds(10)
    private static let limit = Duration.milliseconds(400)

    private let postCopy: @MainActor () throws -> Void

    /// The keystroke is injected rather than called directly so the whole rule above it — wait,
    /// read, put the clipboard back, refuse when nothing arrived — is testable without pressing
    /// Cmd+C into whatever window happens to have focus.
    public init(postCopy: @escaping @MainActor () throws -> Void = InboxCapture.pressCommandC) {
        self.postCopy = postCopy
    }

    public func selection(from pasteboard: NSPasteboard = .general) async throws -> String {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        try postCopy()

        // Polled on the text, not on the counter. `clearContents()` bumps the change counter by
        // itself and the application under us writes the data a moment afterwards, so a wait
        // that stopped at the counter would come back empty roughly whenever the ten-millisecond
        // tick landed inside that gap. Checked before the first sleep, so the ordinary case
        // costs nothing.
        var waited = Duration.zero
        var copied: String?
        while waited < Self.limit {
            if pasteboard.changeCount != before,
               let text = pasteboard.string(forType: .string),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copied = text
                break
            }
            try? await Task.sleep(for: Self.pollInterval)
            waited += Self.pollInterval
        }

        // Nothing was written at all, so there is nothing to put back either: the clipboard was
        // never touched. Refusing here rather than returning an empty string is the rule the
        // rest of the project lives by — a named failure instead of a silent fallback.
        guard pasteboard.changeCount != before else { throw Failure.nothingCopied }

        // Unguarded, unlike the paste: `TextInserter` waits 300 ms for the receiving application
        // to read the pasteboard, and `shouldRestore` is what keeps it from overwriting a copy
        // the owner made inside that window. Here the read and the restore are two statements
        // with no suspension between them, so there is no window to guard.
        snapshot.restore(to: pasteboard)

        guard let copied else { throw Failure.nothingCopied }
        return copied
    }

    public static func pressCommandC() throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
        /// `kVK_ANSI_C`
        let cKeyCode: CGKeyCode = 8
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else {
            throw Failure.eventSourceUnavailable
        }
        // Assigned, never merged — and here that is not the same caution `TextInserter` takes
        // against a stray Shift. fn is *physically held* at this instant: it is what produced
        // the hotkey. An event carrying it would reach the application underneath as fn+Cmd+C,
        // which is a different command or none at all.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
```

- [ ] **Step 4: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 521 тест. Два теста ждут по 400 мс, один — 50 мс: это сам предел ожидания, а не медленный код.

- [ ] **Step 5: Коммит**

```bash
git add Features/Inbox/InboxCapture.swift Tests/InboxTests/InboxCaptureTests.swift
git commit -m "Захват выделения: Cmd+C, ожидание буфера, возврат буфера"
```

---

### Task 8: Состояние панели и координатор лотка

**Files:**
- Create: `Features/Inbox/InboxPanelState.swift`
- Create: `Features/Inbox/InboxCoordinator.swift`
- Create: `Tests/InboxTests/InboxCoordinatorTests.swift`

**Interfaces:**
- Consumes: `InboxFolder.create`, `InboxFolder.copyAttachment`, `InboxNote.render`, `InboxNote.lineCount`, `InboxSource`.
- Produces:
  - `public enum InboxPanelState: Equatable, Sendable { case captured(app: String?, lines: Int, attachments: Int); case failure(String); public var acceptsDrop: Bool }`
  - `@MainActor public final class InboxCoordinator`
  - `public enum InboxCoordinator.Sound: Equatable, Sendable { case done, error }`
  - `public init(root:capture:readSource:now:dropWindow:showPanel:hidePanel:play:)`
  - `public func captureRequested()`
  - `@discardableResult public func drop(_ urls: [URL]) -> Bool`
  - `public static let dropWindow: TimeInterval`, `public static let failureDwell: TimeInterval`
  - `func settle() async` — internal, для тестов

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/InboxTests/InboxCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import Inbox

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

/// Everything the coordinator can reach that a test cannot: the keystroke, the frontmost
/// application, the panel and the clock. Nothing else is faked — the folder and the file are the
/// real ones, in a temporary directory.
@MainActor
private final class Harness {
    let root: URL
    var text: Result<String, Error> = .success("> Натали:\nтекст")
    var source = InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil)
    private(set) var shown: [InboxPanelState] = []
    private(set) var hidden: [TimeInterval] = []
    private(set) var sounds: [InboxCoordinator.Sound] = []
    /// Implicitly unwrapped so the closures below may capture `self`: every other stored
    /// property has a default, so `self` is fully initialised by the time they are built.
    var coordinator: InboxCoordinator!

    init(root: URL, dropWindow: TimeInterval = 120) {
        self.root = root
        coordinator = InboxCoordinator(
            root: root,
            capture: { [weak self] in
                guard let self else { throw InboxCapture.Failure.nothingCopied }
                return try self.text.get()
            },
            readSource: { [weak self] in
                self?.source ?? InboxSource(appName: nil, bundleID: nil, url: nil)
            },
            now: { noon },
            dropWindow: dropWindow,
            showPanel: { [weak self] in self?.shown.append($0) },
            hidePanel: { [weak self] in self?.hidden.append($0) },
            play: { [weak self] in self?.sounds.append($0) }
        )
    }

    /// The capture runs in a task of its own — same shape as every other coordinator here.
    func capture() async {
        coordinator.captureRequested()
        await coordinator.settle()
    }

    var folders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }
}

@MainActor
@Test func aCaptureWritesOneFolderWithANoteAndSaysSo() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)

    await harness.capture()

    // The exact name depends on the machine's time zone — `MeetingFolderTests` checks the shape
    // for the same reason and in the same way.
    #expect(harness.folders.count == 1)
    #expect(harness.folders[0].hasSuffix("-telegram"))
    let note = root.appendingPathComponent(harness.folders[0]).appendingPathComponent("note.md")
    let contents = try String(contentsOf: note, encoding: .utf8)
    #expect(contents.contains("app: \"Telegram\""))
    #expect(contents.hasSuffix("> Натали:\nтекст\n"))
    #expect(harness.shown == [.captured(app: "Telegram", lines: 2, attachments: 0)])
    #expect(harness.sounds == [.done])
}

// An empty folder looks exactly like a capture that happened. This one did not.
@MainActor
@Test func aRefusedCaptureLeavesNothingOnDisk() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    harness.text = .failure(InboxCapture.Failure.nothingCopied)

    await harness.capture()

    #expect(harness.folders.isEmpty)
    #expect(harness.sounds == [.error])
    if case .failure = harness.shown.first {} else {
        Issue.record("панель должна назвать причину: \(harness.shown)")
    }
}

@MainActor
@Test func aDroppedFileLandsInTheFolderOfTheLastCapture() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()

    // Somewhere else on disk, the way a real drag comes from somebody else's folder.
    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let file = elsewhere.appendingPathComponent("источник.txt")
    try "данные".write(to: file, atomically: true, encoding: .utf8)

    #expect(harness.coordinator.drop([file]))

    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("источник.txt").path))
    #expect(harness.shown.last == .captured(app: "Telegram", lines: 2, attachments: 1))
}

// The target closes by itself. A file dropped after it has is refused rather than landing in a
// folder the owner has long forgotten about.
@MainActor
@Test func aDropAfterTheTargetClosedIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root, dropWindow: 0.05)
    await harness.capture()
    try await Task.sleep(for: .milliseconds(150))

    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let file = elsewhere.appendingPathComponent("поздно.txt")
    try "данные".write(to: file, atomically: true, encoding: .utf8)

    #expect(!harness.coordinator.drop([file]))
    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("поздно.txt").path))
}

@MainActor
@Test func theTargetStaysOpenForTheWholeWindowAndTheDwellIsToldToThePanel() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()
    #expect(harness.hidden == [120])
}

@MainActor
@Test func twoCapturesInTheSameMinuteMakeTwoFolders() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()
    await harness.capture()
    #expect(harness.folders.count == 2)
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter InboxCoordinatorTests`
Expected: сборка не проходит — `cannot find 'InboxCoordinator' in scope`.

- [ ] **Step 3: Написать состояние панели**

Создать `Features/Inbox/InboxPanelState.swift`:

```swift
import Foundation

/// What the panel shows about the inbox. Structure only — no wording: the interface speaks
/// Russian and that belongs to the `App` target, while everything here stays testable on its own.
/// Same split, and the same reason, as `PanelState` and `MeetingPanelState`.
public enum InboxPanelState: Equatable, Sendable {
    /// A capture landed, and for as long as this is on screen the strip is a target for files.
    /// `attachments` counts what has already been copied into the folder.
    case captured(app: String?, lines: Int, attachments: Int)
    case failure(String)

    /// The strip takes the mouse only while something can be dropped on it — the same rule, and
    /// the same reason, as `MeetingPanelState.acceptsClicks`: a click the panel accepts is a
    /// click the window underneath does not get.
    public var acceptsDrop: Bool {
        switch self {
        case .captured: true
        case .failure: false
        }
    }
}
```

- [ ] **Step 4: Написать координатор**

Создать `Features/Inbox/InboxCoordinator.swift`:

```swift
import Foundation

/// Performs one capture and holds its folder open for attachments.
///
/// Everything system-facing arrives as a closure — the keystroke, the frontmost application, the
/// panel, the clock — for the same reason `DictationCoordinator` takes the panel that way: the
/// rules are worth testing and the system calls are not reachable from a test.
@MainActor
public final class InboxCoordinator {
    public enum Sound: Equatable, Sendable {
        case done
        case error
    }

    /// How long the strip stays a target after a capture. Two minutes: long enough to find the
    /// file in Telegram, wait for it to download and drag it over; short enough that the strip
    /// is not taking the mouse over a full-screen call for the rest of the day.
    public static let dropWindow: TimeInterval = 120
    /// A refusal is read, not answered.
    public static let failureDwell: TimeInterval = 5

    private let root: URL
    private let capture: @MainActor () async throws -> String
    private let readSource: @MainActor () -> InboxSource
    private let now: () -> Date
    private let dropWindow: TimeInterval
    private let showPanel: (InboxPanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let play: (Sound) -> Void

    /// The folder of the last capture, for as long as files may still be dropped on it, plus
    /// what the panel is currently saying about it. Cleared by `expiry` rather than by the panel
    /// collapsing: the two clocks are the same length, but only one of them belongs here.
    private var target: URL?
    private var attachments = 0
    private var lines = 0
    private var appName: String?
    private var expiry: DispatchWorkItem?
    private var work: Task<Void, Never>?

    public init(
        root: URL = InboxFolder.rootURL,
        capture: @escaping @MainActor () async throws -> String
            = { try await InboxCapture().selection() },
        readSource: @escaping @MainActor () -> InboxSource = { FrontmostSource.read() },
        now: @escaping () -> Date = Date.init,
        dropWindow: TimeInterval = InboxCoordinator.dropWindow,
        showPanel: @escaping (InboxPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        play: @escaping (Sound) -> Void
    ) {
        self.root = root
        self.capture = capture
        self.readSource = readSource
        self.now = now
        self.dropWindow = dropWindow
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.play = play
    }

    /// fn+C. The previous capture's task is cancelled rather than queued behind: two hotkeys in
    /// a row mean the owner wants the second selection, and the first is already history.
    public func captureRequested() {
        work?.cancel()
        work = Task { [weak self] in await self?.perform() }
    }

    /// Waits for the capture in flight. Internal rather than public: it exists for the tests,
    /// which have to see the folder after the task that writes it, and `@testable` is enough.
    func settle() async {
        await work?.value
    }

    private func perform() async {
        let source = readSource()
        let at = now()
        do {
            let text = try await capture()
            let folder = try InboxFolder.create(in: root, capturedAt: at, slug: source.slug)
            let note = InboxNote.render(
                capturedAt: at,
                appName: source.appName,
                bundleID: source.bundleID,
                url: source.url,
                text: text
            )
            try note.write(
                to: folder.appendingPathComponent(InboxNote.fileName),
                atomically: true,
                encoding: .utf8
            )
            target = folder
            attachments = 0
            lines = InboxNote.lineCount(text)
            appName = source.appName
            play(.done)
            announce()
        } catch {
            // Nothing is created on the way out. The folder is made only once there is text to
            // put in it, so a refusal cannot leave an empty one — and an empty one would look
            // exactly like a capture that happened.
            play(.error)
            showPanel(.failure(error.localizedDescription))
            hidePanel(Self.failureDwell)
        }
    }

    /// - Returns: false when there is nothing to attach to, so the panel can leave the drag to
    ///   whoever else wants it rather than swallowing it.
    @discardableResult
    public func drop(_ urls: [URL]) -> Bool {
        guard let folder = target, !urls.isEmpty else { return false }
        do {
            for url in urls {
                try InboxFolder.copyAttachment(url, into: folder)
                attachments += 1
            }
            play(.done)
        } catch {
            play(.error)
            showPanel(.failure(error.localizedDescription))
            hidePanel(Self.failureDwell)
            return true
        }
        announce()
        return true
    }

    /// Shows the strip and re-arms both clocks — the panel's and the target's — so a file
    /// dropped at the end of the window buys another one for the next file beside it.
    private func announce() {
        showPanel(.captured(app: appName, lines: lines, attachments: attachments))
        hidePanel(dropWindow)
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.target = nil }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dropWindow, execute: work)
    }
}
```

- [ ] **Step 5: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 527 тестов.

- [ ] **Step 6: Коммит**

```bash
git add Features/Inbox/InboxPanelState.swift Features/Inbox/InboxCoordinator.swift Tests/InboxTests/InboxCoordinatorTests.swift
git commit -m "Координатор лотка: захват, папка, мишень для вложений"
```

---
### Task 9: Панель рисует строку лотка и принимает файлы

**Files:**
- Modify: `App/PanelModel.swift`
- Modify: `App/PanelWindow.swift`
- Modify: `App/PanelView.swift`

**Interfaces:**
- Consumes: `InboxPanelState` из задачи 8.
- Produces:
  - `PanelModel.inbox: InboxPanelState?`, `PanelModel.onInboxDrop: (([URL]) -> Bool)?`
  - `PanelWindow.show(inbox:)`, `PanelWindow.hideInbox(after:)`, `PanelWindow.setInboxDrop(_:)`

- [ ] **Step 1: Добавить слой в модель панели**

В `App/PanelModel.swift` добавить импорт `Inbox` и два свойства:

```swift
import Inbox
```

```swift
    /// The inbox side of the panel. A third layer rather than a state inside `state`: a capture
    /// happens while the owner is reading somebody else's window, and it must not overwrite what
    /// a dictation in flight is saying about itself.
    @Published var inbox: InboxPanelState?
    /// Answers a drag dropped on the strip. Set once the inbox coordinator exists, which is
    /// after the panel does — same shape as `onMeetingAnswer` above.
    var onInboxDrop: (([URL]) -> Bool)?
```

- [ ] **Step 2: Показывать и прятать её из окна**

В `App/PanelWindow.swift` добавить `import Inbox`, четвёртый таймер выдержки и три метода.

Рядом с `pendingNoticeHide`:

```swift
    /// A fourth dwell timer. The inbox target stands for two minutes while a dictation lasts
    /// seconds and a meeting prompt half a minute; one shared timer would let any of them cut
    /// the others short.
    private var pendingInboxHide: DispatchWorkItem?
```

Методы, рядом с `show(meeting:)`:

```swift
    func show(inbox state: InboxPanelState) {
        pendingInboxHide?.cancel()
        pendingInboxHide = nil
        model.inbox = state
        position()
        panel.orderFrontRegardless()
        updateAcceptsClicks()
        resize(forNotice: model.notice != nil)
    }

    func hideInbox(after delay: TimeInterval) {
        pendingInboxHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.inbox = nil
            self?.panel.invalidateShadow()
            self?.updateAcceptsClicks()
            self?.resize(forNotice: self?.model.notice != nil)
        }
        pendingInboxHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setInboxDrop(_ handler: @escaping ([URL]) -> Bool) {
        model.onInboxDrop = handler
    }
```

И расширить `acceptsClicksNow`, единственное место, где решается, глуха ли панель к мыши:

```swift
    /// Whether a click — or a drag — on the panel right now reaches its content.
    ///
    /// The inbox target needs the mouse for the same reason a meeting prompt does, and gets it
    /// on the same terms: never while dictation is on top of it, because then the target is not
    /// what is on screen. It deliberately does not grow the window: see the decisions log for
    /// 2026-09-08 — a 560×96 rectangle taking the mouse for two minutes would sit exactly over
    /// the mute and leave buttons of a full-screen call.
    private var acceptsClicksNow: Bool {
        guard model.state == nil else { return false }
        return (model.meeting?.acceptsClicks ?? false) || (model.inbox?.acceptsDrop ?? false)
    }
```

- [ ] **Step 3: Нарисовать строку и мишень**

В `App/PanelView.swift` добавить `import Inbox` и вставить лоток в порядок слоёв основной строки:

```swift
            Group {
                // Dictation first, and only then the inbox, and only then a meeting: dictation is
                // what the owner is doing this second; the inbox target is what they may be about
                // to do, and it needs to be findable with a mouse; a meeting's timer is the one
                // of the three that can wait, and it comes back by itself.
                if model.state != nil {
                    active
                } else if let inbox = model.inbox {
                    InboxContent(model: model, state: inbox)
                } else if let meeting = model.meeting {
                    MeetingContent(model: model, state: meeting)
                } else {
                    resting
                }
            }
```

И добавить сам вид, после `MeetingContent`:

```swift
/// The inbox side of the panel: one line saying what was filed, and — for as long as it is up —
/// a target for the files that came with it.
///
/// Lit rather than grey, on the same rule the rest of the panel follows: what glows is what is
/// waiting for something from the owner, and this is waiting for a drag.
private struct InboxContent: View {
    /// Held, not observed, exactly as `MeetingContent` holds it: the drop handler is not
    /// published and has to be read at the moment of the drop rather than captured earlier.
    let model: PanelModel
    let state: InboxPanelState
    @State private var targeted = false

    var body: some View {
        switch state {
        case .captured(let app, let lines, let attachments):
            row(caption(app: app, lines: lines, attachments: attachments), failed: false)
                .overlay(
                    RoundedRectangle(cornerRadius: Surface.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(targeted ? 0.5 : 0), lineWidth: 1.5)
                )
                .dropDestination(for: URL.self) { urls, _ in
                    model.onInboxDrop?(urls) ?? false
                } isTargeted: { targeted = $0 }
        case .failure(let message):
            row(message, failed: true)
        }
    }

    private func caption(app: String?, lines: Int, attachments: Int) -> String {
        var parts = ["во входящих"]
        if let app { parts.append(app) }
        parts.append("строк: \(lines)")
        // Никаких «1 файл / 2 файла / 5 файлов»: в панели уже принято писать «N мин», а не
        // склонять, и по той же причине — форма счётного слова не стоит ветки в интерфейсе.
        parts.append(attachments == 0 ? "перетащи файлы сюда" : "файлов: \(attachments)")
        return parts.joined(separator: " · ")
    }

    private func row(_ text: String, failed: Bool) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(failed ? Color.red : Color.secondary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Surface(recording: !failed))
            .frame(maxWidth: 520)
    }
}
```

- [ ] **Step 4: Собрать и прогнать всё**

Run: `swift build && swift test`
Expected: сборка проходит, PASS, 527 тестов (у таргета `App` нет своего тест-таргета — за него отвечают сборка и живая проверка задачи 13).

- [ ] **Step 5: Коммит**

```bash
git add App/PanelModel.swift App/PanelWindow.swift App/PanelView.swift
git commit -m "Панель: строка лотка и мишень для вложений"
```

---

### Task 10: Приложение собирает лоток и мишень

Координатор лотка и панель встречаются в `AppDelegate`. Клавиши на этом шаге ещё нет: fn+C появится следующей задачей, потому что она ломает и чинит исчерпывающие `switch` в трёх файлах разом и обязана быть одним коммитом.

**Files:**
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `InboxCoordinator` из задачи 8, `PanelWindow.show(inbox:)`, `hideInbox(after:)`, `setInboxDrop(_:)` из задачи 9.
- Produces: свойства `AppDelegate.inbox: InboxCoordinator?` и `AppDelegate.sounds: SoundPlayer?`, которыми задача 11 свяжет клавишу с лотком.

- [ ] **Step 1: Завести два свойства**

В `App/AppDelegate.swift` добавить `import Inbox` и, рядом с остальными свойствами:

```swift
    /// Built once at launch and never rebuilt: it holds the folder of the last capture for two
    /// minutes, and a config reload happening inside that window must not throw an open drop
    /// target away. Nothing in it is configurable anyway.
    private var inbox: InboxCoordinator?
    /// The sound player of the current dictation coordinator, kept here so the inbox can use the
    /// same three system sounds without a second copy of the config. Nil until the first build
    /// finishes — and the hotkey does not exist until then either.
    private var sounds: SoundPlayer?
```

- [ ] **Step 2: Собрать координатор и мишень при запуске**

В `applicationDidFinishLaunching`, сразу после `panel.setMeetingAnswer { ... }`:

```swift
        // Built before any coordinator, exactly like the meeting answer above: the drop target
        // has to answer a drag from the moment the panel is on screen, and the closure looks the
        // coordinator up when the drop happens rather than capturing one that may be gone.
        let inbox = InboxCoordinator(
            showPanel: { [panel] state in panel.show(inbox: state) },
            hidePanel: { [panel] delay in panel.hideInbox(after: delay) },
            play: { [weak self] sound in
                self?.sounds?.play(sound == .done ? .done : .error)
            }
        )
        self.inbox = inbox
        panel.setInboxDrop { [weak inbox] urls in inbox?.drop(urls) ?? false }
```

- [ ] **Step 3: Сохранить проигрыватель звуков**

В `buildCoordinator`, там где создаётся `SoundPlayer`, вынести его в переменную и запомнить:

```swift
            let sounds = SoundPlayer(sounds: config.sounds)
            self.sounds = sounds
```

и передать `sounds: sounds` в `DictationCoordinator(...)` вместо `SoundPlayer(sounds: config.sounds)`.

- [ ] **Step 4: Собрать и прогнать всё**

Run: `swift build && swift test`
Expected: сборка проходит, PASS, 527 тестов. Число не меняется: у таргета `App` нет своего тест-таргета, за него отвечают сборка и живая проверка задачи 13.

- [ ] **Step 5: Коммит**

```bash
git add App/AppDelegate.swift
git commit -m "Приложение собирает координатор лотка и мишень для файлов"
```

---

### Task 11: fn+C — клавиша, автомат и вызов лотка

Три файла и одна сборка. Разделить их нельзя, и это стоит понимать до начала: `KeyEventKind` и `DictationMachine.Effect` разбираются в `DictationCoordinator` исчерпывающими `switch` без `default`. Новый вид клавиши ломает `received(_:)` ровно в тот момент, когда его добавили, а новый эффект ломает `perform(_:)`. Значит клавиша, событие, эффект, его исполнение и место вызова обязаны появиться в одном коммите — иначе на любом промежуточном шаге проект не собирается.

Правила все три уже приняты: из покоя — просто захват; из записи — захват вместо записи, потому что fn открыл микрофон только из-за самого жеста; из состояний после записи — названный отказ, потому что вставка держит буфер обмена.

**Files:**
- Modify: `Features/Dictation/KeyEventReader.swift`
- Modify: `Features/Dictation/DictationMachine.swift`
- Modify: `Features/Dictation/PanelState.swift`
- Modify: `Features/Dictation/DictationCoordinator.swift`
- Modify: `App/PanelView.swift` (два исчерпывающих `switch` по `PanelState` компилятор заставит дополнить)
- Modify: `App/AppDelegate.swift`
- Test: `Tests/DictationTests/KeyEventReaderTests.swift`, `Tests/DictationTests/DictationMachineTests.swift`

**Interfaces:**
- Consumes: `InboxCoordinator.captureRequested()` из задачи 8, свойство `inbox` в `AppDelegate` из задачи 10.
- Produces: `KeyEventKind.captureDown`, `KeyEventReader.cKeyCode: Int64 = 8`, `DictationMachine.Event.captureDown`, `DictationMachine.Effect.capture`, `PanelState.captureRefused`, параметр `onCapture` у `DictationCoordinator.init`.

- [ ] **Step 1: Написать падающие тесты клавиши**

Дописать в конец `Tests/DictationTests/KeyEventReaderTests.swift`:

```swift
@Test func fnPlusCIsRecognized() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 8, flags: .maskSecondaryFn) == .captureDown)
}

// The flag is part of what the key *is* here, not a separate condition checked later: without
// it this type would hand the machine every letter C typed on the machine.
@Test func aPlainCIsNotACapture() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 8, flags: []) == nil)
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 8, flags: .maskCommand) == nil)
}

@Test func cIsRecognizedOnlyOnKeyDown() {
    #expect(KeyEventReader.kind(type: .keyUp, keyCode: 8, flags: .maskSecondaryFn) == nil)
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 8, flags: .maskSecondaryFn) == nil)
}

// Always: the only way this kind is produced at all is with fn held, and letting the letter
// through would type a "c" into whatever the owner was reading.
@Test func captureIsAlwaysSwallowed() {
    #expect(KeyEventReader.shouldSwallow(.captureDown, flags: .maskSecondaryFn, space: false, escape: false))
}
```

- [ ] **Step 2: Написать падающие тесты автомата**

Дописать в конец `Tests/DictationTests/DictationMachineTests.swift`:

```swift
@Test func fnPlusCFromRestJustCaptures() {
    var subject = machine()
    #expect(subject.handle(.captureDown) == [.capture])
    #expect(subject.state == .idle)
}

// The refusal to dictate over a meeting leaves the machine idle, and capture never touches the
// microphone — so the rule that blocks dictation does not reach it. In practice the owner hears
// the refusal sound first and then gets the capture, and that is the accepted price of the key
// not falling away for fifteen hours of calls a week.
@Test func captureWorksWhileAMeetingIsBeingRecorded() {
    var subject = machine()
    subject.isBlocked = true
    _ = subject.handle(.fnDown(at: start))
    #expect(subject.handle(.captureDown) == [.capture])
}

// fn was held long enough to start recording before C arrived. The recording is an artefact of
// the gesture, not something the owner asked for.
@Test func fnPlusCDuringARecordingDropsItAndCapturesAnyway() {
    var subject = recording()
    let effects = subject.handle(.captureDown)
    #expect(effects == [
        .discardRecording,
        .hidePanel(after: 0),
        .swallow(space: false, escape: false),
        .capture,
    ])
    #expect(subject.state == .idle)
}

// The same from inside the hold threshold, where nothing has been announced yet: a rule that
// depended on whether the owner pressed the second key within 300 ms would be irreproducible.
@Test func fnPlusCInsideTheHoldThresholdBehavesTheSame() {
    var subject = machine()
    _ = subject.handle(.fnDown(at: start))
    #expect(subject.handle(.captureDown).contains(.capture))
    #expect(subject.state == .idle)
}

// A dictation past the recording stage owns the clipboard: `.inserting` borrows it and puts it
// back, and a capture borrowing it at the same moment leaves the owner's clipboard holding the
// dictated text for good. Named refusal rather than a race nobody could reproduce.
@Test func captureIsRefusedWhileADictationIsInFlight() {
    for state in ["stopping", "transcribing", "cleaning", "inserting"] {
        var subject = recording()
        _ = subject.handle(.fnUp(at: start.addingTimeInterval(1)))
        if state != "stopping" {
            _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
        }
        if state == "cleaning" || state == "inserting" {
            _ = subject.handle(.transcribed("сырой текст"))
        }
        if state == "inserting" {
            _ = subject.handle(.cleaned("чистый текст"))
        }
        let effects = subject.handle(.captureDown)
        #expect(effects == [.play(.error), .show(.captureRefused), .hidePanel(after: 3)],
                "состояние \(state)")
        #expect(!effects.contains(.capture), "состояние \(state)")
    }
}

// The refusal changes nothing about the dictation it refused: it goes on to insert its text.
@Test func aRefusedCaptureDoesNotDisturbTheDictation() {
    var subject = recording()
    _ = subject.handle(.fnUp(at: start.addingTimeInterval(1)))
    _ = subject.handle(.recordingStopped(URL(fileURLWithPath: "/tmp/a.wav")))
    _ = subject.handle(.captureDown)
    #expect(subject.state == .transcribing)
    #expect(subject.handle(.transcribed("текст")) == [.show(.cleaning), .clean("текст")])
}
```

- [ ] **Step 3: Прогнать и убедиться, что падает**

Run: `swift test --filter DictationTests`
Expected: сборка не проходит — `type 'KeyEventKind' has no member 'captureDown'`.

- [ ] **Step 4: Научить `KeyEventReader` различать fn+C**

В `Features/Dictation/KeyEventReader.swift` добавить пятый вид события:

```swift
public enum KeyEventKind: Equatable, Sendable {
    case fnDown
    case fnUp
    case spaceDown
    case escapeDown
    /// fn+C — the inbox hotkey. Not a dictation event at all: it is here because this is where
    /// the application's one keyboard tap lives.
    case captureDown
}
```

код клавиши рядом с остальными:

```swift
    /// `kVK_ANSI_C`
    public static let cKeyCode: Int64 = 8
```

ветку в `kind(type:keyCode:flags:)`, после ветки escape:

```swift
        // The fn flag is part of the identity of this event rather than a condition checked
        // afterwards. Without it every letter C typed on the machine would reach the state
        // machine — and the aliasing this type exists to filter out (arrows, the F row, Home,
        // End, both Page keys) sets the flag on those keys' own events, never on C's.
        case .keyDown where keyCode == cKeyCode && flags.contains(.maskSecondaryFn):
            return .captureDown
```

и ветку в `shouldSwallow`:

```swift
        case .captureDown:
            // Unconditional, because the kind cannot be produced without fn: passing the letter
            // through would type a "c" into whatever the owner is reading.
            return true
```

- [ ] **Step 5: Добавить событие, эффект и состояние панели**

В `Features/Dictation/PanelState.swift` добавить состояние в конец перечисления:

```swift
    /// fn+C arrived while a dictation was past the recording stage. Refused rather than raced:
    /// insertion borrows the clipboard and a capture borrowing it at the same time would lose
    /// what was on it.
    case captureRefused
```

В `Features/Dictation/DictationMachine.swift` — в `Event`:

```swift
        /// fn+C. Not a dictation event: it rides this machine because the application has one
        /// keyboard tap and one place where key events turn into decisions.
        case captureDown
```

в `Effect`:

```swift
        /// Read the selection and file it in the inbox. Performed by whoever the coordinator was
        /// given, which is not this feature — dictation knows nothing about folders.
        case capture
```

и в `handle(_:)`, сразу после ветки `case (.idle, .fnDown(let at)):`, три ветки:

```swift
        // Capture never touches the microphone, so the rule that refuses dictation over a
        // meeting does not reach it: the refusal leaves the machine idle, and this is what idle
        // answers. In practice fn plays the refusal sound and then C files the item — the price
        // of the key not falling away for the fifteen hours of calls in a week.
        case (.idle, .captureDown):
            return [.capture]

        // fn was held past the threshold and a recording is running. It is an artefact of the
        // gesture rather than something the owner asked for, so it goes exactly the way Escape
        // sends it, and the capture happens regardless of how long the key was down — a rule
        // that turned on 300 milliseconds would be irreproducible.
        case (.recording, .captureDown):
            state = .idle
            return [
                .discardRecording,
                .hidePanel(after: 0),
                .swallow(space: false, escape: false),
                .capture,
            ]

        // A dictation past the recording stage owns the clipboard: `.inserting` borrows it and
        // gives it back, and a capture borrowing it at the same moment would leave the owner's
        // clipboard holding the dictated text for good. Two or three seconds of named refusal
        // instead of a race that could only be seen by its consequences.
        case (.stopping, .captureDown), (.transcribing, .captureDown),
             (.cleaning, .captureDown), (.inserting, .captureDown):
            return [.play(.error), .show(.captureRefused), .hidePanel(after: limits.failureDwell)]
```

- [ ] **Step 6: Провести клавишу и эффект через координатор диктовки**

В `Features/Dictation/DictationCoordinator.swift` добавить свойство рядом с остальными закрытиями:

```swift
    /// fn+C. A closure rather than a dependency, for the same reason the panel is one: dictation
    /// knows nothing about folders, and a protocol with one implementation would only hide which
    /// way the dependency runs.
    private let onCapture: () -> Void
```

добавить параметр **последним** в `init` — после `onNarrowbandInput`, потому что порядок аргументов на месте вызова обязан совпадать с порядком объявления:

```swift
        onCapture: @escaping () -> Void
```

присвоение в теле `init`:

```swift
        self.onCapture = onCapture
```

ветку в `received(_:)` — без неё `switch` перестаёт быть исчерпывающим и файл не собирается:

```swift
        case .captureDown:
            apply(.captureDown)
```

и ветку в `perform(_:)`, по той же причине:

```swift
        case .capture:
            onCapture()
```

- [ ] **Step 7: Дополнить панель, куда укажет компилятор**

`App/PanelView.swift` перестанет собираться в двух местах — оба исчерпывающие `switch` по `PanelState`.

В `endsWithoutText` новый случай идёт к тем, после которых никакой текст никуда не вставляется:

```swift
        case .failure, .blocked, .captureRefused: true
```

В `caption` добавить строку рядом с `.blocked`:

```swift
        case .captureRefused: return "диктовка ещё идёт"
```

- [ ] **Step 8: Связать клавишу с лотком в `AppDelegate`**

В `App/AppDelegate.swift`, в вызове `DictationCoordinator(...)`, добавить последним аргументом:

```swift
                onCapture: { [weak self] in self?.inbox?.captureRequested() }
```

Свойство `inbox` уже есть — его завела задача 10.

- [ ] **Step 9: Прогнать все тесты**

Run: `swift test`
Expected: PASS, 537 тестов.

- [ ] **Step 10: Собрать приложение**

Run: `Scripts/make-app.sh`
Expected: `готово: build/NoHands.app`, `codesign --verify` без замечаний.

- [ ] **Step 11: Коммит**

```bash
git add Features/Dictation App/PanelView.swift App/AppDelegate.swift Tests/DictationTests
git commit -m "fn+C: клавиша, событие автомата и вызов лотка"
```

---

### Task 12: Скилл разбора входящих и выгрузка в Todoist

Разбор — разговор, а не программа: формат карточки пока не известен, и писать под него автоматику значит писать под догадку. Скилл лежит в репозитории, потому что он часть проекта и версионируется вместе с ним.

**Files:**
- Create: `.claude/skills/inbox-review/SKILL.md`

**Interfaces:**
- Consumes: папки `~/Inbox/<дата-время-слаг>/note.md`, созданные задачами 3–8.
- Produces: `card.md` рядом с `note.md`; задачу в Todoist.

- [ ] **Step 1: Положить токен Todoist в связку ключей**

Владелец делает это руками один раз, токен берётся в Todoist → Settings → Integrations → Developer:

```bash
security add-generic-password -s nohands-todoist -a api-token -T /usr/bin/security -w
```

Команда спросит пароль в терминале и не оставит его в истории. Флаг `-T` называет доверенным того, кто будет читать, — урок 3 сентября: элемент, созданный без него, поднимает системный диалог при первом чтении из другой идентичности кода.

- [ ] **Step 2: Написать скилл**

Создать `.claude/skills/inbox-review/SKILL.md`:

````markdown
---
name: inbox-review
description: Разбирает папки ~/Inbox, заведённые хоткеем fn+C, в задачи Todoist. Использовать, когда владелец говорит «разбери входящие», «разбор лотка», «что накопилось», или вызывает /inbox-review.
---

# Разбор входящих

Папка `~/Inbox/<дата-время-слаг>/` — одно входящее: `note.md` с фронтматтером и текстом,
рядом могут лежать вложения. Разобранное входящее отличается от неразобранного одним:
наличием `card.md`. Никакого отдельного файла состояния нет — это то же правило, по которому
живёт очередь встреч.

## Порядок

**1. Сначала спросить про факт времени.**

Прочитать `card.md` во всех папках, где есть строка `task:` и нет строки `spent:`. Если такие
есть — перечислить их одной строкой каждую и спросить: «сколько на самом деле ушло?» теми же
вёдрами, что и оценка. Ответ дописать строкой `spent:` в фронтматтер того же `card.md`.

Один вопрос, никакого таймера: таймер со стартом и стопом владелец жать не станет.

Если владелец говорит «потом» — не настаивать и идти дальше.

**2. Найти неразобранное.**

```bash
for d in ~/Inbox/*/; do [ -f "$d/card.md" ] || echo "$d"; done
```

Разбирать по одному, от старых к новым.

**3. По каждому входящему.**

Прочитать `note.md` целиком и перечислить вложения в папке. Затем показать владельцу:

- **формулировку задачи** — одной строкой, глаголом, конкретно: не «лендинг», а «собрать
  замечания по лендингу и отдать Натали»
- **сжатый контекст** — три-четыре строки: кто просил, что именно нужно, к чему привязано,
  что уже известно. Из текста, не из воображения
- **источник** — приложение и время захвата из фронтматтера, адрес страницы если есть
- **вложения** — имена файлов в папке; отдельно назвать имена файлов, которые упомянуты в
  тексте, но в папке отсутствуют: их не перетащили

Спросить три вещи и не додумывать ни одну:

- **размер** вёдрами: `полчаса` / `час-два` / `полдня` / `день и больше`. Ставит владелец,
  не модель: «весь день или нет» — ровно та цифра, ради которой всё затевается, а модель
  оценивает объём работы плохо
- **срок** — если он не назван в тексте прямо
- **это вообще задача?** — если из разговора видно, что нет

**4. Завести задачу.**

```bash
TOKEN=$(security find-generic-password -s nohands-todoist -a api-token -w)
curl -sS -X POST https://api.todoist.com/rest/v2/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @- <<'JSON'
{
  "content": "формулировка",
  "description": "сжатый контекст\n\n~/Inbox/2026-09-08-1732-telegram/",
  "due_string": "10 сентября",
  "labels": ["полдня"],
  "priority": 2
}
JSON
```

Токен нигде не печатается и не попадает в текст ответа. `priority` в REST v2 растёт вверх:
4 — самый срочный, 1 — обычный. Метка размера создаётся сама, если её ещё нет.

В `description` последней строкой всегда путь к папке входящего: полный контекст живёт на
диске, а Todoist держит только то, по чему утром принимается решение.

**5. Записать карточку.**

`card.md` рядом с `note.md`:

```markdown
---
task: 7654321
created: 2026-09-08 17:40
size: полдня
due: 2026-09-10
---

Формулировка задачи

Сжатый контекст, ровно тот, что ушёл в Todoist.
```

Отклонённое входящее получает карточку тоже — иначе оно всплывёт в следующем разборе снова:

```markdown
---
rejected: 2026-09-08 17:40
---

Почему это не задача.
```

Папку не удалять ни в том, ни в другом случае: она стоила один хоткей, а контекст, который
может понадобиться, дороже места на диске.

## Чего не делать

- Не заводить задачу без явного «да» владельца. Десяток ложных задач на одну настоящую
  сломает доверие к списку, которое сейчас не является проблемой
- Не оценивать размер за владельца
- Не переписывать и не чистить `note.md`: это исходник, по которому всё сказанное здесь
  проверяется
- Не печатать токен
````

- [ ] **Step 3: Проверить, что скилл виден**

Run: `ls .claude/skills/inbox-review/SKILL.md`
Expected: файл на месте. Скилл появится в списке после перезапуска сессии Claude Code — проверка живьём идёт задачей 14.

- [ ] **Step 4: Коммит**

```bash
git add .claude/skills/inbox-review/SKILL.md
git commit -m "Скилл разбора входящих и выгрузки в Todoist"
```

---

---

### Task 13: Живая проверка и запись в журнал

Всё, что тестами не ловится. Спека §10 перечисляет это списком; здесь он превращён в порядок действий.

**Files:**
- Modify: `docs/DECISIONS.md`

**Interfaces:**
- Consumes: собранное приложение из задачи 11 и скилл из задачи 12.
- Produces: запись «Итоги куска: лоток входящих» в журнале.

- [ ] **Step 1: Пересобрать и перезапустить приложение**

```bash
Scripts/make-app.sh
open build/NoHands.app
```

Если macOS попросит универсальный доступ заново — выдать. Полоска над доком должна появиться:
её отсутствие означает, что приложение не запустилось.

- [ ] **Step 2: Захват из Телеграма**

Выделить в Телеграме несколько сообщений, нажать fn+C. Ожидается: звук, строка «во входящих ·
Telegram · строк: N · перетащи файлы сюда».

Проверить:

```bash
ls -la ~/Inbox
cat ~/Inbox/*/note.md | head -30
```

Во фронтматтере — `captured`, `app: "Telegram"`, `bundle: ru.keepcoder.Telegram`. В теле —
цитатный блок с авторами, слово в слово как в буфере. Проверить отдельно, что **буфер обмена
владельца вернулся на место**: скопировать что-нибудь заранее и убедиться, что оно там же.

- [ ] **Step 3: Захват из Трекера в Safari**

Выделить текст задачи в Трекере, нажать fn+C. Первый раз macOS спросит разрешение управлять
Safari — согласиться. В `note.md` должна появиться строка `url:` с адресом страницы.

Отдельно проверить отказ: снять разрешение в системных настройках, захватить ещё раз, убедиться,
что входящее создалось **без** строки `url` и без всякой ошибки.

И отдельно — задержку. `FrontmostSource.read()` ждёт ответа браузера на главном акторе, поэтому
медленный Safari — со страницей в модальном диалоге, с крутящимся курсором — задержит и панель,
и обработку клавиш. Если между fn+C и появлением строки на панели чувствуется пауза, это оно:
записать наблюдение, а чинить таймаутом поверх Apple event отдельной работой. Если паузы нет,
записать и это — решение оставить синхронный вызов принято именно с расчётом на наблюдение.

- [ ] **Step 4: Захват из Яндекс Мессенджера**

Ожидается фронтматтер с `bundle` мессенджера и тело, в котором есть дата отдельной строкой и
время у каждой реплики — то, чего Телеграм не даёт.

- [ ] **Step 5: Вложение**

Сразу после захвата из Телеграма перетащить скачанный файл на полоску над доком. Ожидается:
подсветка рамки при наведении, звук, строка меняется на «файлов: 1», файл лежит в папке
входящего, а **в исходной папке остался**.

- [ ] **Step 6: Три отказа**

- fn+C, ничего не выделив → звук ошибки, причина на панели, папки в `~/Inbox` не прибавилось
- fn+C во время записи созвона → сперва звук отказа диктовки, потом входящее создаётся
- продиктовать фразу и нажать fn+C, пока идёт вставка → «диктовка ещё идёт», входящее не
  создаётся, диктовка доходит до конца и текст вставляется

- [ ] **Step 7: Разбор**

Вызвать скилл, разобрать одно настоящее входящее до конца: задача появилась в Todoist, рядом с
`note.md` лежит `card.md` с номером задачи, повторный разбор эту папку не предлагает.

- [ ] **Step 8: Записать итоги в журнал**

Дописать в `docs/DECISIONS.md` запись «2026-09-08 — Итоги куска: лоток входящих» с числами и,
отдельным абзацем, с тем, что живая проверка нашла, а тесты нет. Записывать факты, а не
ожидания: сколько входящих сделано, сколько из них с вложениями, что оказалось неудобным в
жесте, поднялся ли диалог автоматизации там, где ожидался.

- [ ] **Step 9: Коммит и пуш**

```bash
git add docs/DECISIONS.md
git commit -m "Журнал: итоги куска с лотком входящих"
git push
```
