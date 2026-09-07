# Конспект по кускам — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** конспект считается по кускам в пятнадцать минут и сводится в один, поэтому пик памяти не зависит от длины встречи, а часовой созвон получает такой же осмысленный конспект, как четырнадцатиминутный.

**Architecture:** расшифровка режется по репликам на куски; подпроцесс поднимает модель один раз, прогоняет куски по очереди и сводит частичные конспекты вторым проходом; сверка цитат идёт по полной расшифровке, как раньше; в файл встречи пишутся четыре раздела вместо двух.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, Qwen3 8B через `uv run --with 'mlx-lm==0.31.3'`.

**Spec:** `docs/superpowers/specs/2026-09-07-summary-chunking-design.md`

## Global Constraints

- Swift 6, SwiftPM. **Новых зависимостей SPM не добавлять.**
- Тесты — swift-testing (`import Testing`, `@Test func …`, `#expect(…)`). XCTest в проекте не используется.
- Идентификаторы, комментарии в коде и в тестах, тексты ошибок — по-английски. Строки, которые видит владелец (панель, CLI, разделы файла встречи), — по-русски. Коммиты и документация — по-русски.
- TDD: сначала падающий тест, потом код. Полный прогон — `swift test` (464 теста до начала работы).
- Модель ни в одном тесте не запускается. Живые прогоны — только задача 7, и только контроллером.
- Содержимое расшифровок никуда не логируется. Записи в файл встречи атомарные.
- Предел куска двойной: пятнадцать минут по таймкодам и объём по `summaryContextTokens`, срабатывает первый.
- Порог сверки `quoteMatchRatio` остаётся 0,4, и цитата ищется в полной расшифровке, а не в своём куске.

## Карта файлов

| Файл | Ответственность |
|---|---|
| `Core/Summary/TranscriptChunks.swift` | нарезка расшифровки на куски по репликам |
| `Core/Summary/MeetingSummary.swift` | значения: добавляются задачи и открытые вопросы |
| `Core/Summary/SummaryResponse.swift` | разбор новой схемы ответа |
| `Core/Summary/QuoteMatch.swift` | сверка задач наравне с решениями |
| `Core/LLM/SummaryPrompt.swift` | промпт аналитика и промпт сведения |
| `Core/LLM/SummaryScript.swift` | питон: одна загрузка модели, цикл по кускам, сведение |
| `Core/LLM/MLXSummaryRunner.swift` | запрос с кусками, предел на кусок |
| `Core/Summary/SummaryInsertion.swift` | четыре раздела в файле встречи |
| `Features/Meetings/MeetingSummarizer.swift` | нарезка перед вызовом бегунка |
| `CLI/MeetingCommands.swift` | печать задач, предупреждение о втором экземпляре |

---

### Task 1: Нарезка расшифровки на куски

**Files:**
- Create: `Core/Summary/TranscriptChunks.swift`
- Test: `Tests/CoreTests/TranscriptChunksTests.swift`

**Interfaces:**
- Consumes: `TranscriptIndex` с полями `lines: [TranscriptIndex.Line]` (`timecode: TimeInterval`, `speaker: String`, `text: String`), `MeetingMarkdown.timestamp(_:)`
- Produces: `TranscriptChunks.split(_ index: TranscriptIndex, maxSeconds: TimeInterval, maxCharacters: Int) -> [String]`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CoreTests/TranscriptChunksTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

private func index(_ lines: [(TimeInterval, String)]) -> TranscriptIndex {
    let body = lines.map { "[\(MeetingMarkdown.timestamp($0.0))] Я: \($0.1)" }.joined(separator: "\n")
    return TranscriptIndex.parse("## Транскрипт\n\n" + body)
}

@Test func aShortMeetingIsOneChunk() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (60, "два"), (120, "три")]),
        maxSeconds: 900, maxCharacters: 100_000
    )
    #expect(chunks.count == 1)
    #expect(chunks[0].contains("[00:00:00] Я: раз"))
    #expect(chunks[0].contains("[00:02:00] Я: три"))
}

// The span is measured from the chunk's own first reply, not from the meeting's start:
// otherwise every chunk after the first would be cut immediately.
@Test func aChunkEndsWhenItsOwnSpanReachesTheLimit() {
    let chunks = TranscriptChunks.split(
        index([(0, "раз"), (800, "два"), (1000, "три"), (1900, "четыре")]),
        maxSeconds: 900, maxCharacters: 100_000
    )
    #expect(chunks.count == 3)
    #expect(chunks[0].contains("раз") && chunks[0].contains("два"))
    #expect(chunks[1].contains("три"))
    #expect(chunks[2].contains("четыре"))
}

@Test func aReplyIsNeverCutInHalf() {
    let long = String(repeating: "слово ", count: 50)
    let chunks = TranscriptChunks.split(
        index([(0, long), (10, long)]), maxSeconds: 900, maxCharacters: 200
    )
    #expect(chunks.count == 2)
    for chunk in chunks {
        #expect(chunk.hasPrefix("["))
        #expect(chunk.components(separatedBy: "\n").count == 1)
    }
}

// Dense speech hits the character budget before the fifteen minutes are up. Both limits are
// live at once and the first one to trip wins.
@Test func theCharacterBudgetCutsBeforeTheClockOnDenseSpeech() {
    let line = String(repeating: "а", count: 90)
    let chunks = TranscriptChunks.split(
        index([(0, line), (1, line), (2, line)]), maxSeconds: 900, maxCharacters: 220
    )
    #expect(chunks.count == 2)
}

@Test func aReplyLongerThanTheBudgetTravelsAlone() {
    let huge = String(repeating: "б", count: 500)
    let chunks = TranscriptChunks.split(
        index([(0, "коротко"), (5, huge), (10, "снова коротко")]),
        maxSeconds: 900, maxCharacters: 200
    )
    #expect(chunks.count == 3)
    #expect(chunks[1].contains(huge))
}

@Test func aTranscriptWithNoLinesGivesNoChunks() {
    #expect(TranscriptChunks.split(TranscriptIndex.parse("нет заголовка"), maxSeconds: 900, maxCharacters: 100).isEmpty)
}

// Every reply of the meeting has to end up in exactly one chunk: a summary of a meeting with a
// silently dropped middle is worse than no summary, because nothing about it looks wrong.
@Test func everyReplyEndsUpInExactlyOneChunk() {
    let source = index((0..<40).map { (TimeInterval($0) * 120, "реплика \($0)") })
    let chunks = TranscriptChunks.split(source, maxSeconds: 900, maxCharacters: 100_000)
    let rejoined = chunks.joined(separator: "\n")
    #expect(rejoined == source.body)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter TranscriptChunks`
Expected: FAIL — `cannot find 'TranscriptChunks' in scope`

- [ ] **Step 3: Написать нарезку**

Создать `Core/Summary/TranscriptChunks.swift`:

```swift
import Foundation

/// Cuts a transcript into pieces small enough for the model to hold at once.
///
/// Fifteen minutes is not a calculation. It is the length of the meeting that ran on the owner's
/// machine on 2026-09-07 and produced the best summary of that day — names, a condition and a
/// deadline — while the sixty-eight-minute meeting on the same prompt produced a table of
/// contents and, on the second attempt, was killed by the system for taking ten gigabytes.
///
/// Two limits are live at once and the first to trip wins: the span in seconds, and the number of
/// characters. The clock is what makes a chunk a coherent stretch of conversation; the character
/// budget is the guard for dense speech, where fifteen minutes can still overflow the model's
/// window.
public enum TranscriptChunks {
    /// - Returns: chunks in meeting order, each one whole reply lines joined by newlines, in the
    ///   same form they have in the meeting file. Concatenating them with newlines reproduces
    ///   `index.body` exactly — that is the property that guarantees nothing was dropped.
    public static func split(
        _ index: TranscriptIndex,
        maxSeconds: TimeInterval,
        maxCharacters: Int
    ) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentCharacters = 0
        var chunkStart: TimeInterval = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(current.joined(separator: "\n"))
            current = []
            currentCharacters = 0
        }

        for line in index.lines {
            let rendered = "[\(MeetingMarkdown.timestamp(line.timecode))] \(line.speaker): \(line.text)"
            if current.isEmpty {
                chunkStart = line.timecode
            } else {
                let spanWouldExceed = line.timecode - chunkStart > maxSeconds
                let sizeWouldExceed = currentCharacters + rendered.count > maxCharacters
                if spanWouldExceed || sizeWouldExceed {
                    flush()
                    chunkStart = line.timecode
                }
            }
            current.append(rendered)
            // Newline included, so the sum matches what `joined(separator:)` will produce.
            currentCharacters += rendered.count + 1
        }
        flush()
        return chunks
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter TranscriptChunks`
Expected: PASS, семь тестов

- [ ] **Step 5: Коммит**

```bash
git add Core/Summary/TranscriptChunks.swift Tests/CoreTests/TranscriptChunksTests.swift
git commit -m "Нарезка расшифровки на куски по репликам"
```

---

### Task 2: Задачи и открытые вопросы в схеме ответа

**Files:**
- Modify: `Core/Summary/MeetingSummary.swift`
- Modify: `Core/Summary/SummaryResponse.swift`
- Modify: `Core/Summary/QuoteMatch.swift`
- Test: `Tests/CoreTests/SummaryResponseTests.swift`, `Tests/CoreTests/QuoteMatchTests.swift`

**Interfaces:**
- Consumes: `MeetingSummary`, `CheckedDecision`, `QuoteMatch.find(quote:in:)`, `TranscriptIndex`
- Produces: `MeetingSummary.Task(text:owner:due:quote:)`; `MeetingSummary.tasks: [Task]`; `MeetingSummary.openIssues: [String]`; `CheckedTask(text:owner:due:ratio:timecode:)`; `QuoteMatch.check(tasks:against:threshold:) -> [CheckedTask]`

- [ ] **Step 1: Написать падающие тесты**

Дописать в `Tests/CoreTests/SummaryResponseTests.swift`:

```swift
@Test func tasksAndOpenIssuesAreRead() throws {
    let raw = """
        {"title": "Синк", "summary": ["обсудили"],
         "decisions": [],
         "tasks": [{"text": "собрать визуализацию", "owner": "Настя", "due": "до 9-10 числа",
                    "quote": "Настя, соберёшь визуализацию"}],
         "openIssues": ["чем красить график"]}
        """
    let summary = try SummaryResponse.parse(raw)
    #expect(summary.tasks == [
        MeetingSummary.Task(
            text: "собрать визуализацию", owner: "Настя", due: "до 9-10 числа",
            quote: "Настя, соберёшь визуализацию"
        )
    ])
    #expect(summary.openIssues == ["чем красить график"])
}

// The transcript knows only «Я» and «Собеседник» until phase 2г, so a task whose owner was never
// said out loud is the common case, not the exception.
@Test func aTaskWithoutAnOwnerOrDueStillParses() throws {
    let raw = """
        {"title": "Т", "summary": ["раз"], "decisions": [],
         "tasks": [{"text": "прогнать тест", "quote": "давай прогоним тест"}]}
        """
    let task = try #require(try SummaryResponse.parse(raw).tasks.first)
    #expect(task.owner.isEmpty)
    #expect(task.due.isEmpty)
}

// Same rule the decisions already follow: the check rests on the quote, and a task that arrived
// without one cannot be told from one that failed the check.
@Test func aTaskWithoutAQuoteIsDropped() throws {
    let raw = """
        {"title": "Т", "summary": ["раз"], "decisions": [],
         "tasks": [{"text": "без цитаты", "quote": ""}, {"text": "с цитатой", "quote": "было сказано"}]}
        """
    #expect(try SummaryResponse.parse(raw).tasks.map(\.text) == ["с цитатой"])
}

@Test func aResponseWithoutTasksIsStillValid() throws {
    let summary = try SummaryResponse.parse("{\"title\": \"Т\", \"summary\": [\"раз\"], \"decisions\": []}")
    #expect(summary.tasks.isEmpty)
    #expect(summary.openIssues.isEmpty)
}
```

Дописать в `Tests/CoreTests/QuoteMatchTests.swift`:

```swift
@Test func tasksAreCheckedTheSameWayDecisionsAre() {
    let tasks = [
        MeetingSummary.Task(
            text: "настоящая", owner: "Настя", due: "до среды", quote: "они тратят время и ресурсы"
        ),
        MeetingSummary.Task(
            text: "выдуманная", owner: "", due: "", quote: "переозвучить видеоролик и водность"
        ),
    ]
    let checked = QuoteMatch.check(tasks: tasks, against: index, threshold: 0.4)
    #expect(checked[0].timecode == 2472)
    #expect(checked[0].owner == "Настя")
    #expect(checked[0].due == "до среды")
    #expect(checked[1].timecode == nil)
    #expect(checked[1].ratio > 0)
}
```

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `swift test --filter "SummaryResponse|QuoteMatch"`
Expected: FAIL — `value of type 'MeetingSummary' has no member 'tasks'`

- [ ] **Step 3: Расширить значения**

В `Core/Summary/MeetingSummary.swift` добавить внутрь `MeetingSummary` рядом с `Decision`:

```swift
    /// Something somebody took on. `owner` and `due` carry what was actually said out loud and
    /// are empty when it was not: until phase 2г the transcript knows only «Я» and «Собеседник»,
    /// so a name appears here only when a participant used one.
    public struct Task: Equatable, Sendable {
        public var text: String
        public var owner: String
        public var due: String
        public var quote: String

        public init(text: String, owner: String, due: String, quote: String) {
            self.text = text
            self.owner = owner
            self.due = due
            self.quote = quote
        }
    }
```

и два поля с обновлённым инициализатором (у новых параметров умолчания, чтобы существующие места сборки продолжали компилироваться):

```swift
    public var title: String
    public var summary: [String]
    public var decisions: [Decision]
    public var tasks: [Task]
    public var openIssues: [String]

    public init(
        title: String,
        summary: [String],
        decisions: [Decision],
        tasks: [Task] = [],
        openIssues: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.tasks = tasks
        self.openIssues = openIssues
    }
```

В том же файле, рядом с `CheckedDecision`:

```swift
/// A task after the transcript has been asked about its quote. Mirrors `CheckedDecision` and
/// carries the two fields a decision does not have.
public struct CheckedTask: Equatable, Sendable {
    public var text: String
    public var owner: String
    public var due: String
    public var ratio: Double
    public var timecode: TimeInterval?

    public init(text: String, owner: String, due: String, ratio: Double, timecode: TimeInterval?) {
        self.text = text
        self.owner = owner
        self.due = due
        self.ratio = ratio
        self.timecode = timecode
    }
}
```

- [ ] **Step 4: Расширить разбор**

В `Core/Summary/SummaryResponse.swift`, в `Payload`:

```swift
        struct Task: Decodable {
            var text: String
            var owner: String?
            var due: String?
            var quote: String
        }

        var title: String?
        var summary: [String]?
        var decisions: [Decision]?
        var tasks: [Task]?
        var openIssues: [String]?
```

и в `parse`, перед `return`:

```swift
        let tasks = (payload.tasks ?? []).compactMap { task -> MeetingSummary.Task? in
            let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = task.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !quote.isEmpty else { return nil }
            return MeetingSummary.Task(
                text: text,
                owner: (task.owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                due: (task.due ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                quote: quote
            )
        }
        let openIssues = (payload.openIssues ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
```

и передать их в `MeetingSummary(title:summary:decisions:tasks:openIssues:)`.

- [ ] **Step 5: Добавить сверку задач**

В `Core/Summary/QuoteMatch.swift`, рядом с существующим `check`:

```swift
    /// The same check the decisions get. Kept as a second method rather than a generic one: the
    /// two results carry different fields, and a protocol to unify them would cost more than the
    /// six lines it saves.
    public static func check(
        tasks: [MeetingSummary.Task],
        against index: TranscriptIndex,
        threshold: Double
    ) -> [CheckedTask] {
        tasks.map { task in
            let result = find(quote: task.quote, in: index)
            let passed = result.ratio >= threshold
            return CheckedTask(
                text: task.text,
                owner: task.owner,
                due: task.due,
                ratio: result.ratio,
                timecode: passed ? result.line.map { index.lines[$0].timecode } : nil
            )
        }
    }
```

- [ ] **Step 6: Прогнать тесты**

Run: `swift test --filter "SummaryResponse|QuoteMatch"`
Expected: PASS

- [ ] **Step 7: Коммит**

```bash
git add Core/Summary Tests/CoreTests
git commit -m "Схема ответа: задачи с ответственным и сроком, открытые вопросы"
```

---

### Task 3: Промпт аналитика и промпт сведения

**Files:**
- Modify: `Core/LLM/SummaryPrompt.swift`
- Test: `Tests/CoreTests/MLXSummaryRunnerTests.swift`

**Interfaces:**
- Consumes: `TranscriptEnvelope.wrapped(_:)`
- Produces: `SummaryPrompt.system: String`, `SummaryPrompt.merge: String`, `SummaryPrompt.user(chunk: String) -> String`, `SummaryPrompt.mergeUser(partials: [String]) -> String`

- [ ] **Step 1: Написать падающие тесты**

Дописать в `Tests/CoreTests/MLXSummaryRunnerTests.swift`:

```swift
// The prompt is what the owner asked for, and these are the three properties that survive from
// the old one: JSON only, no invention, a quote under every claim.
@Test func theAnalystPromptDemandsJSONQuotesAndNothingInvented() {
    #expect(SummaryPrompt.system.contains("JSON"))
    #expect(SummaryPrompt.system.contains("цитат"))
    #expect(SummaryPrompt.system.contains("добавляйте ничего"))
    #expect(SummaryPrompt.system.contains("tasks"))
    #expect(SummaryPrompt.system.contains("openIssues"))
}

// The five-item ceiling is what turned an hour of talk into a table of contents. It must not
// come back into the per-chunk prompt.
@Test func theAnalystPromptDoesNotCapTheNumberOfPoints() {
    #expect(!SummaryPrompt.system.contains("до пяти"))
    #expect(!SummaryPrompt.system.contains("пяти пунктов"))
}

// The merge pass never sees the transcript — only the partial summaries. That is what makes it
// cheap in both memory and time.
@Test func theMergePromptTakesPartialsAndKeepsQuotesAsTheyAre() {
    #expect(SummaryPrompt.merge.contains("частичн"))
    #expect(SummaryPrompt.merge.contains("цитаты"))
    #expect(SummaryPrompt.merge.contains("добавляйте ничего"))
    let user = SummaryPrompt.mergeUser(partials: ["{\"a\": 1}", "{\"b\": 2}"])
    #expect(user.contains("{\"a\": 1}"))
    #expect(user.contains("{\"b\": 2}"))
}

@Test func aChunkTravelsInsideTheMarker() {
    let wrapped = SummaryPrompt.user(chunk: "[00:00:01] Я: раз")
    #expect(wrapped.contains("<расшифровка>"))
    #expect(wrapped.hasSuffix("</расшифровка>"))
}
```

Удалить старый тест `theTranscriptGoesToTheModelInsideTheMarker`, если он вызывает `SummaryPrompt.user(transcript:)` — метод переименован; тест выше его заменяет. Тест `aClosingMarkerInsideTheSpeechStaysInsideTheEnvelope` сохранить, поменяв вызов на `SummaryPrompt.user(chunk:)`.

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `swift test --filter MLXSummaryRunner`
Expected: FAIL — `type 'SummaryPrompt' has no member 'merge'`

- [ ] **Step 3: Написать промпты**

Заменить содержимое `Core/LLM/SummaryPrompt.swift`:

```swift
import Foundation

/// What the model is told, on both passes.
///
/// The analyst wording is the owner's own, with three changes. Its `<User Input>` block, which
/// told the model to answer «Пожалуйста, вставьте расшифровку» and wait, is gone: in a batch
/// pipeline the transcript arrives in the same call and that instruction would replace the
/// summary with that sentence. Its six markdown sections became JSON fields, because the quote
/// check — the thing that told a real decision from an invented one on 2026-09-07 — needs
/// structure. And its ceiling on the number of points is gone: on a fifteen-minute chunk the
/// ceiling is what turned an hour of conversation into a table of contents.
///
/// Lives in code rather than in the config for the same reason the envelope does: a prompt kept
/// in the owner's `config.json` cannot be fixed for an installation that already has one.
public enum SummaryPrompt {
    public static let system = """
        Вы — внимательный к деталям аналитик встреч. Вы получаете кусок расшифровки рабочей встречи \
        и превращаете его в структурированный разбор для занятого человека: только то, что \
        действительно сказано, без воды и без пересказа отступлений.

        Правила:
        - Опирайтесь только на сказанное. Не добавляйте ничего, чего нет в расшифровке.
        - Пишите утверждениями по существу, а не названиями тем. «Определены сроки» — плохо; \
        «сдать изменения до 9-10 числа» — хорошо. Сохраняйте имена, числа, сроки и названия так, \
        как они прозвучали.
        - Под каждым решением и каждой задачей приводите дословную цитату из расшифровки на 5-15 \
        слов, скопированную без изменений. Пункт без цитаты не пишите вовсе.
        - У задачи указывайте ответственного и срок, если они названы вслух; если не названы, \
        оставляйте поле пустым. Не додумывайте их.
        - Пропускайте приветствия, технические заминки и разговоры не по делу.

        Отвечайте строго одним объектом JSON без пояснений и без markdown-ограды, с полями:
        title — краткое название встречи, до 60 символов;
        summary — массив строк: что обсудили и к чему пришли;
        decisions — массив объектов с полями text и quote;
        tasks — массив объектов с полями text, owner, due, quote;
        openIssues — массив строк: вопросы, оставшиеся нерешёнными.
        Пустые массивы допустимы.
        """

    /// The second pass. It never sees the transcript — only the partial summaries — which is what
    /// makes it cheap in memory and in time.
    public static let merge = """
        Вы сводите частичные конспекты одной и той же встречи в один. Каждый частичный конспект — \
        объект JSON той же формы, что и ваш ответ.

        Правила:
        - Объедините повторяющиеся пункты в один. Одна и та же договорённость, встретившаяся в \
        двух частях, должна остаться в единственном экземпляре.
        - Не добавляйте ничего, чего нет в частичных конспектах.
        - Цитаты переносите дословно, как есть. Не сокращайте и не переписывайте их.
        - Дайте встрече одно название по всему её содержанию.
        - В summary оставьте не больше десяти пунктов, самых существенных.

        Отвечайте строго одним объектом JSON без пояснений и без markdown-ограды, с теми же \
        полями: title, summary, decisions, tasks, openIssues.
        """

    public static func user(chunk: String) -> String {
        "Кусок расшифровки встречи:\n\n" + TranscriptEnvelope.wrapped(chunk)
    }

    public static func mergeUser(partials: [String]) -> String {
        "Частичные конспекты встречи по порядку:\n\n"
            + partials.enumerated()
            .map { "Часть \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter MLXSummaryRunner`
Expected: PASS

- [ ] **Step 5: Коммит**

```bash
git add Core/LLM/SummaryPrompt.swift Tests/CoreTests/MLXSummaryRunnerTests.swift
git commit -m "Промпт аналитика встреч и промпт сведения"
```

---

### Task 4: Скрипт и бегунок работают с кусками

**Files:**
- Modify: `Core/LLM/SummaryScript.swift`
- Modify: `Core/LLM/MLXSummaryRunner.swift`
- Test: `Tests/CoreTests/MLXSummaryRunnerTests.swift`

**Interfaces:**
- Consumes: `SummaryPrompt.system`, `SummaryPrompt.merge`, `SummaryPrompt.user(chunk:)`, `SummaryPrompt.mergeUser(partials:)`, `SummaryResponse.parse(_:)`
- Produces: `SummaryRunning.summarize(chunks: [String]) async throws -> MeetingSummary` (протокол меняет метод), `MLXSummaryRunner.Failure.tooLong(estimated:limit:)` теперь про кусок

- [ ] **Step 1: Написать падающие тесты**

Заменить в `Tests/CoreTests/MLXSummaryRunnerTests.swift` тест про длину и добавить два:

```swift
// The limit is per chunk now: a long meeting is many chunks, and none of them is too long unless
// the speech inside it is abnormally dense.
@Test func aChunkLongerThanTheWindowIsRefusedBeforeAnythingIsLaunched() async {
    let chunk = String(repeating: "слово ", count: 20_000)
    await #expect(throws: MLXSummaryRunner.Failure.tooLong(estimated: 48_000, limit: 100)) {
        try await runner(context: 100).summarize(chunks: [chunk])
    }
}

@Test func anEmptyChunkListIsARefusalRatherThanAnEmptyRun() async {
    await #expect(throws: MLXSummaryRunner.Failure.self) {
        try await runner().summarize(chunks: [])
    }
}

@Test func theScriptLoadsTheModelOnceAndMergesOnlyWhenThereIsMoreThanOneChunk() {
    #expect(SummaryScript.source.contains("for chunk in request[\"chunks\"]"))
    #expect(SummaryScript.source.contains("if len(partials) == 1"))
    #expect(SummaryScript.source.contains("load(request[\"model\"])"))
    // One load call in the whole script — the model must not be reloaded per chunk.
    #expect(SummaryScript.source.components(separatedBy: "load(request[\"model\"])").count == 2)
}
```

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `swift test --filter MLXSummaryRunner`
Expected: FAIL — `incorrect argument label in call (have 'transcript:', expected 'chunks:')`

- [ ] **Step 3: Переписать скрипт**

В `Core/LLM/SummaryScript.swift` заменить питон между `#"""` и `"""#`:

```python
"""Runs Qwen3 8B over one meeting, chunk by chunk, and prints the merged summary.

Launched as a subprocess by MLXSummaryRunner: request as a JSON file whose path is the first
argument, answer on stdout, diagnostics on stderr. The request travels as a file rather than on
stdin because a transcript is large enough to exceed a pipe's buffer.

The model is loaded once and reused for every chunk: loading costs fifteen seconds cold, and a
five-chunk meeting would otherwise pay it five times. Chunking exists because a whole
sixty-eight-minute meeting took about ten gigabytes and was killed by the system on a 16 GB
machine; a fifteen-minute chunk takes a fraction of that, and the peak no longer depends on how
long the meeting was.

enable_thinking=False is not optional: Qwen3 is a reasoning model and without it half a minute of
deliberation lands in the meeting file. temp=0.0 for the same reason a transcript is not creative
writing.
"""

import json
import sys

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


def answer(model, tokenizer, system, user, max_tokens):
    prompt = tokenizer.apply_chat_template(
        [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        add_generation_prompt=True,
        tokenize=False,
        enable_thinking=False,
    )
    return generate(
        model,
        tokenizer,
        prompt=prompt,
        max_tokens=max_tokens,
        sampler=make_sampler(temp=0.0),
        verbose=False,
    )


def main():
    with open(sys.argv[1], encoding="utf-8") as request_file:
        request = json.load(request_file)
    model, tokenizer = load(request["model"])

    partials = []
    for chunk in request["chunks"]:
        partials.append(
            answer(model, tokenizer, request["system"], chunk, request["maxTokens"])
        )

    if len(partials) == 1:
        sys.stdout.write(partials[0])
        return

    merged = answer(
        model,
        tokenizer,
        request["mergeSystem"],
        request["mergePrefix"] + "\n\n" + "\n\n".join(
            "Часть %d:\n%s" % (number, text) for number, text in enumerate(partials, 1)
        ),
        request["mergeMaxTokens"],
    )
    sys.stdout.write(merged)


main()
```

- [ ] **Step 4: Переписать бегунок**

В `Core/LLM/SummaryRunning.swift` поменять метод протокола:

```swift
public protocol SummaryRunning: Sendable {
    /// - Parameter chunks: the meeting cut into pieces the model can hold at once, in order.
    ///   One chunk is summarised directly; several are summarised apart and then merged.
    func summarize(chunks: [String]) async throws -> MeetingSummary
}
```

В `Core/LLM/MLXSummaryRunner.swift` заменить `Request` и `summarize`:

```swift
    private struct Request: Encodable {
        var model: String
        var system: String
        var mergeSystem: String
        var mergePrefix: String
        var chunks: [String]
        var maxTokens: Int
        var mergeMaxTokens: Int
    }

    public func summarize(chunks: [String]) async throws -> MeetingSummary {
        guard !chunks.isEmpty else {
            throw Failure.runnerFailed("the meeting has no transcript to summarise")
        }
        // Per chunk, not per meeting: the whole point of chunking is that a long meeting is many
        // ordinary requests rather than one impossible one.
        for chunk in chunks {
            let estimated = Int(Double(chunk.count) / Self.charactersPerToken)
            guard estimated <= contextTokens else {
                throw Failure.tooLong(estimated: estimated, limit: contextTokens)
            }
        }

        let uv = (uvPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: uv) else {
            throw Failure.uvMissing(uvPath)
        }

        let request = try JSONEncoder().encode(
            Request(
                model: model,
                system: SummaryPrompt.system,
                mergeSystem: SummaryPrompt.merge,
                mergePrefix: "Частичные конспекты встречи по порядку:",
                chunks: chunks.map { SummaryPrompt.user(chunk: $0) },
                maxTokens: Self.maxTokens,
                mergeMaxTokens: Self.mergeMaxTokens
            )
        )
        let answer = try await run(uv: URL(fileURLWithPath: uv), request: request)
        return try SummaryResponse.parse(answer)
    }
```

и рядом с `maxTokens` добавить:

```swift
    /// The merge pass answers about a whole meeting rather than a chunk of one, so it gets more
    /// room than a single chunk's summary needs.
    static let mergeMaxTokens = 2000
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter MLXSummaryRunner`
Expected: PASS

Сборка остальных таргетов на этом шаге ещё падает: `MeetingSummarizer` и CLI зовут `summarize(transcript:)`. Это чинит задача 6 — не трогайте их здесь, но убедитесь, что падает именно это: `swift build 2>&1 | grep summarize | head`.

- [ ] **Step 6: Коммит**

```bash
git add Core/LLM Tests/CoreTests/MLXSummaryRunnerTests.swift
git commit -m "Подпроцесс считает куски по очереди и сводит их вторым проходом"
```

---

### Task 5: Четыре раздела в файле встречи

**Files:**
- Modify: `Core/Summary/SummaryInsertion.swift`
- Test: `Tests/CoreTests/SummaryInsertionTests.swift`

**Interfaces:**
- Consumes: `MeetingSummary`, `CheckedDecision`, `CheckedTask`, `MeetingMarkdown.timestamp(_:)`
- Produces: `SummaryInsertion.apply(summary:decisions:tasks:to:named:mode:)`; `SummaryInsertion.tasksHeading`, `.openIssuesHeading`, `.noOwnerNote`, `.noDueNote`

- [ ] **Step 1: Написать падающие тесты**

Дописать в `Tests/CoreTests/SummaryInsertionTests.swift`:

```swift
@Test func tasksAndOpenIssuesGetTheirOwnSections() throws {
    let summary = MeetingSummary(
        title: "Синк", summary: ["обсудили"], decisions: [],
        tasks: [], openIssues: ["чем красить график"]
    )
    let tasks = [
        CheckedTask(text: "собрать визуализацию", owner: "Настя", due: "до 9-10 числа",
                    ratio: 0.9, timecode: 49),
        CheckedTask(text: "прогнать тест", owner: "", due: "", ratio: 0.1, timecode: nil),
    ]
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], tasks: tasks, to: file, named: "тест.md", mode: .insert
    )
    #expect(result.contains("## Задачи"))
    #expect(result.contains("- собрать визуализацию — Настя — до 9-10 числа — [00:00:49]"))
    #expect(result.contains("- прогнать тест — не назначено — срок не назван — основание не найдено"))
    #expect(result.contains("## Открытые вопросы"))
    #expect(result.contains("- чем красить график"))
}

@Test func theFourSectionsComeInOrderAboveTheTranscript() throws {
    let summary = MeetingSummary(
        title: "Синк", summary: ["обсудили"],
        decisions: [], tasks: [], openIssues: ["вопрос"]
    )
    let result = try SummaryInsertion.apply(
        summary: summary,
        decisions: [CheckedDecision(text: "решение", ratio: 0.9, timecode: 10)],
        tasks: [CheckedTask(text: "задача", owner: "", due: "", ratio: 0.9, timecode: 20)],
        to: file, named: "тест.md", mode: .insert
    )
    let order = ["## Саммари", "## Решения", "## Задачи", "## Открытые вопросы", "## Транскрипт"]
    var position = result.startIndex
    for heading in order {
        let found = try #require(result.range(of: heading, range: position..<result.endIndex))
        position = found.upperBound
    }
}

@Test func emptySectionsAreNotWritten() throws {
    let result = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т", summary: ["раз"], decisions: [], tasks: [], openIssues: []),
        decisions: [], tasks: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(!result.contains("## Задачи"))
    #expect(!result.contains("## Открытые вопросы"))
    #expect(!result.contains("## Решения"))
}

// Replacement stays scoped: all four of our headings go, anything the owner wrote stays.
@Test func replacingRemovesAllFourSectionsAndKeepsAHandWrittenOne() throws {
    let once = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т", summary: ["раз"], decisions: [], tasks: [],
                                openIssues: ["вопрос"]),
        decisions: [],
        tasks: [CheckedTask(text: "задача", owner: "", due: "", ratio: 0.9, timecode: 20)],
        to: file, named: "тест.md", mode: .insert
    )
    let withNote = once.replacingOccurrences(
        of: "## Транскрипт", with: "## Моя заметка\n\n- не трогать\n\n## Транскрипт"
    )
    let twice = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т2", summary: ["два"], decisions: [], tasks: [], openIssues: []),
        decisions: [], tasks: [], to: withNote, named: "тест.md", mode: .replace
    )
    #expect(twice.contains("## Моя заметка"))
    #expect(twice.contains("- не трогать"))
    #expect(!twice.contains("## Задачи"))
    #expect(!twice.contains("## Открытые вопросы"))
    #expect(twice.components(separatedBy: "## Саммари").count == 2)
}
```

Существующие тесты этого файла вызывают `apply(summary:decisions:to:named:mode:)` — добавьте им `tasks: []`.

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `swift test --filter SummaryInsertion`
Expected: FAIL — `incorrect argument labels in call`

- [ ] **Step 3: Расширить вставку**

В `Core/Summary/SummaryInsertion.swift` добавить константы рядом с существующими:

```swift
    public static let tasksHeading = "## Задачи"
    public static let openIssuesHeading = "## Открытые вопросы"
    /// Written in full rather than left blank: an empty column in an archive reads as an
    /// oversight, while these two say plainly that nobody named an owner or a date out loud.
    public static let noOwnerNote = "не назначено"
    public static let noDueNote = "срок не назван"
```

Поменять сигнатуру `apply`, добавив параметр `tasks: [CheckedTask]` после `decisions`, и передать его в `sections`. Заменить `sections` целиком:

```swift
    private static func sections(
        _ summary: MeetingSummary,
        _ decisions: [CheckedDecision],
        _ tasks: [CheckedTask]
    ) -> [String] {
        var out = [summaryHeading, ""]
        out.append(contentsOf: summary.summary.map { "- \($0)" })
        out.append("")

        if !decisions.isEmpty {
            out.append(decisionsHeading)
            out.append("")
            for decision in decisions {
                out.append("- \(decision.text) — \(mark(decision.timecode))")
            }
            out.append("")
        }

        if !tasks.isEmpty {
            out.append(tasksHeading)
            out.append("")
            for task in tasks {
                let owner = task.owner.isEmpty ? noOwnerNote : task.owner
                let due = task.due.isEmpty ? noDueNote : task.due
                out.append("- \(task.text) — \(owner) — \(due) — \(mark(task.timecode))")
            }
            out.append("")
        }

        if !summary.openIssues.isEmpty {
            out.append(openIssuesHeading)
            out.append("")
            out.append(contentsOf: summary.openIssues.map { "- \($0)" })
            out.append("")
        }

        return out
    }

    private static func mark(_ timecode: TimeInterval?) -> String {
        guard let timecode else { return unfoundedNote }
        return "[\(MeetingMarkdown.timestamp(timecode))]"
    }
```

В `withoutSummarySections` расширить условие удаления на все четыре заголовка:

```swift
            if trimmed == summaryHeading || trimmed == decisionsHeading
                || trimmed == tasksHeading || trimmed == openIssuesHeading {
                dropping = true
                continue
            }
```

В `refusal(_:to:named:)` передать `tasks: []` в вызов `apply`.

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter SummaryInsertion`
Expected: PASS

- [ ] **Step 5: Коммит**

```bash
git add Core/Summary/SummaryInsertion.swift Tests/CoreTests/SummaryInsertionTests.swift
git commit -m "Файл встречи: четыре раздела вместо двух"
```

---

### Task 6: Проводка нарезки в обход архива и в CLI

**Files:**
- Modify: `Features/Meetings/MeetingSummarizer.swift`
- Modify: `CLI/MeetingCommands.swift`
- Modify: `CLI/NoHands.swift` (текст `usage`)
- Test: `Tests/MeetingsTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Consumes: `TranscriptChunks.split(_:maxSeconds:maxCharacters:)`, `SummaryRunning.summarize(chunks:)`, `QuoteMatch.check(tasks:against:threshold:)`, `SummaryInsertion.apply(summary:decisions:tasks:to:named:mode:)`, `MeetingsConfig.summaryContextTokens`, `MLXSummaryRunner.charactersPerToken`
- Produces: ничего для последующих задач

- [ ] **Step 1: Написать падающие тесты**

В `Tests/MeetingsTests/MeetingSummarizerTests.swift` поменять фейк на новый метод протокола и добавить тест:

```swift
private struct FakeRunner: SummaryRunning {
    let answer: MeetingSummary?
    let failure: (@Sendable () -> any Error)?
    let calls: Counter
    var slow: Bool = false
    /// Chunk counts of every call, so a test can prove the meeting arrived cut up rather than whole.
    let chunkCounts: Counts

    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func record(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func summarize(chunks: [String]) async throws -> MeetingSummary {
        calls.bump()
        chunkCounts.record(chunks.count)
        if slow { try? await Task.sleep(for: .milliseconds(100)) }
        if let failure { throw failure() }
        return answer!
    }
}

// A meeting longer than the chunk limit must reach the runner cut into pieces: that is the whole
// point of the change, and nothing else in the pass would reveal it.
@Test func aLongMeetingReachesTheRunnerInChunks() async throws {
    var lines: [String] = []
    for minute in 0..<40 {
        lines.append("[\(MeetingMarkdown.timestamp(TimeInterval(minute) * 60))] Я: реплика \(minute)")
    }
    let long = """
        ---
        date: 2026-09-07
        ---

        ## Транскрипт

        \(lines.joined(separator: "\n"))

        """
    let directory = try archive(files: ["long.md": long])
    let counts = FakeRunner.Counts()
    let summarizer = MeetingSummarizer(
        archive: directory, config: .default,
        makeRunner: {
            FakeRunner(answer: summary, failure: nil, calls: FakeRunner.Counter(), chunkCounts: counts)
        },
        report: { _ in }
    )
    await summarizer.scanArchive()
    #expect(counts.all == [3])
}
```

Остальные тесты этого файла собирают `FakeRunner` — добавьте им `chunkCounts: FakeRunner.Counts()`.

- [ ] **Step 2: Прогнать тесты и убедиться, что они падают**

Run: `swift test --filter MeetingSummarizer`
Expected: FAIL — `type 'FakeRunner' does not conform to protocol 'SummaryRunning'`

- [ ] **Step 3: Завести ключ размера куска в конфиге**

В `Features/Meetings/MeetingsConfig.swift` рядом с `summaryContextTokens`:

```swift
    /// Length of one chunk in seconds. Fifteen minutes is the length of the meeting that ran on
    /// this machine on 2026-09-07 and produced the best summary of that day, while the
    /// sixty-eight-minute one took ten gigabytes and was killed by the system.
    public var summaryChunkSeconds: Double
```

умолчание `summaryChunkSeconds: 900` в `.default`, параметр `summaryChunkSeconds: Double = 900` в `public init`, и строка в `init(from decoder:)`:

```swift
        summaryChunkSeconds = try container.decodeIfPresent(Double.self, forKey: .summaryChunkSeconds)
            ?? fallback.summaryChunkSeconds
```

- [ ] **Step 4: Нарезать перед вызовом бегунка**

В `Features/Meetings/MeetingSummarizer.swift`, в методе `summarize(_:text:)`, заменить вызов бегунка:

```swift
            // Cut here rather than inside the runner: the summarizer is where the config lives,
            // and the runner should not have to know what a meeting is.
            let chunks = TranscriptChunks.split(
                index,
                maxSeconds: config.summaryChunkSeconds,
                maxCharacters: Int(Double(config.summaryContextTokens) * MLXSummaryRunner.charactersPerToken)
            )
            let summary = try await makeRunner().summarize(chunks: chunks)
            let decisions = QuoteMatch.check(
                summary.decisions, against: index, threshold: config.quoteMatchRatio
            )
            let tasks = QuoteMatch.check(
                tasks: summary.tasks, against: index, threshold: config.quoteMatchRatio
            )
            let updated = try SummaryInsertion.apply(
                summary: summary,
                decisions: decisions,
                tasks: tasks,
                to: text,
                named: file.lastPathComponent,
                mode: .insert
            )
```

`MLXSummaryRunner.charactersPerToken` объявлен `static let` без модификатора доступа — сделайте его `public static let`, чтобы модуль `Meetings` его видел.

- [ ] **Step 5: Починить команду CLI**

В `CLI/MeetingCommands.swift`, в `runMeetingSummarize`, заменить вызов и печать:

```swift
    note("Не запускайте эту команду, пока работает приложение: две модели по 4,3 ГБ не помещаются в память вместе.")

    let chunks = TranscriptChunks.split(
        index,
        maxSeconds: config.summaryChunkSeconds,
        maxCharacters: Int(Double(config.summaryContextTokens) * MLXSummaryRunner.charactersPerToken)
    )
    note("кусков: \(chunks.count)")
    let started = Date()
    let summary = try await runner.summarize(chunks: chunks)
    note("ответ за \(Int(Date().timeIntervalSince(started))) с")

    let checked = QuoteMatch.check(
        summary.decisions, against: index, threshold: config.quoteMatchRatio
    )
    let checkedTasks = QuoteMatch.check(
        tasks: summary.tasks, against: index, threshold: config.quoteMatchRatio
    )
    note("название: \(summary.title)")
    for decision in checked {
        let stamp = decision.timecode.map { "[\(MeetingMarkdown.timestamp($0))]" } ?? "нет"
        let mark = decision.timecode == nil ? "×" : " "
        note(String(format: "%@ %.2f %@ решение: %@", mark, decision.ratio, stamp, decision.text))
    }
    for task in checkedTasks {
        let stamp = task.timecode.map { "[\(MeetingMarkdown.timestamp($0))]" } ?? "нет"
        let mark = task.timecode == nil ? "×" : " "
        note(String(format: "%@ %.2f %@ задача: %@", mark, task.ratio, stamp, task.text))
    }
    if checked.contains(where: { $0.timecode == nil }) || checkedTasks.contains(where: { $0.timecode == nil }) {
        note("порог quoteMatchRatio правится в \(MeetingsConfig.configFileURL.path), секция meetings")
    }

    let updated = try SummaryInsertion.apply(
        summary: summary,
        decisions: checked,
        tasks: checkedTasks,
        to: text,
        named: file.lastPathComponent,
        mode: .replace
    )
```

В `CLI/NoHands.swift` в описании `meeting summarize` дописать строку:

```
    Не запускать одновременно с приложением: две модели в память не поместятся.
```

- [ ] **Step 6: Прогнать всё**

Run: `swift build && swift test`
Expected: PASS, весь набор

- [ ] **Step 7: Коммит**

```bash
git add Features/Meetings CLI Tests/MeetingsTests
git commit -m "Обход архива и команда режут встречу на куски"
```

---

### Task 7: Живые прогоны с замером памяти

**Эту задачу субагентам не поручать.** Она запускает модель на машине владельца, а сегодня фоновый замер уже отобрал у него машину посреди работы. Контроллер выполняет её сам, по одному прогону, каждый — с явного слова владельца.

**Files:** ничего не меняется; результат — числа для журнала решений.

- [ ] **Step 1: Убедиться, что приложение не считает конспект**

```bash
pgrep -fl "nohands-summarize" || echo "свободно"
```
Если процесс есть — ждать его завершения, не убивать: это работа приложения над настоящей встречей.

- [ ] **Step 2: Прогон на четырёхминутной встрече**

```bash
cp ~/Meetings/2026-09-04-1053-telemost.md /tmp/probe-4min.md
/usr/bin/time -l swift run nohands meeting summarize /tmp/probe-4min.md 2>&1 | tail -25
```
Записать: число кусков (ожидается 1), время ответа, пик памяти (`maximum resident set size`), доли у решений и задач.

- [ ] **Step 3: Прогон на четырнадцатиминутной встрече**

```bash
cp ~/Meetings/2026-09-07-1437-telemost.md /tmp/probe-14min.md
/usr/bin/time -l swift run nohands meeting summarize /tmp/probe-14min.md 2>&1 | tail -25
```
Ожидается один кусок. Сравнить содержание с тем, что дал старый промпт на этой же встрече: имена, сроки и условия должны остаться.

- [ ] **Step 4: Прогон на 68-минутной встрече — тот, ради которого всё делалось**

```bash
cp ~/Meetings/2026-09-07-1009-telemost.md /tmp/probe-68min.md
/usr/bin/time -l swift run nohands meeting summarize /tmp/probe-68min.md 2>&1 | tail -30
```
Ожидается пять кусков плюс сведение. Записать пик памяти — он должен быть заметно ниже десяти гигабайт, иначе вся работа не достигла цели.

- [ ] **Step 5: Вернуть конспект в приложении**

Если прогоны прошли, вернуть `summaryEnabled: true` в `~/Library/Application Support/NoHands/config.json` и перезапустить приложение. Спросить владельца перед перезапуском.

- [ ] **Step 6: Записать итоги в журнал решений**

Дописать в `docs/DECISIONS.md` запись с датой, числами трёх прогонов, пиками памяти и тем, изменилось ли качество на длинной встрече. Отдельным коммитом, сразу в origin.

---

## Что остаётся за планом

Вторая машина для счёта (§11 спеки) — отложена сознательно. Нарезка нужна в любом случае: она чинит и качество, а не только память.
