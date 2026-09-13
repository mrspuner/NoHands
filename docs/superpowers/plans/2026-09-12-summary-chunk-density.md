# Плотность встречи и размер куска конспекта

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** размер куска конспекта становится свойством встречи — кусок закрывается, набрав бюджет смен говорящего, — а решения и задачи собирает код, оставляя модели только сведение саммари.

**Architecture:** третий предел нарезки рядом с минутами и символами; питон из конвейера превращается в исполнителя списка промптов с ответом через файл; оркестровка переезжает в Swift и делается двумя запусками — куски, затем сведение; потолок в десять кусков заменяется стражем размера собранного промпта сведения.

**Tech Stack:** Swift 6, SwiftPM, MLX через `uv` (Qwen3 8B, 4 бита), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-12-summary-chunk-density-design.md`

## Global Constraints

- Идентификаторы, комментарии в коде и сообщения об ошибках — **по-английски**; всё, что читает владелец (файл встречи, вывод CLI, панель) — по-русски; коммиты по-русски.
- Новых зависимостей SwiftPM не добавляем. Версия `mlx-lm` пинуется в коде рядом со скриптом.
- TDD: тест раньше кода, каждая задача кончается коммитом.
- Не логировать содержимое транскриптов. Печать по явной команде CLI логированием не считается — прецедент `nohands meeting levels`.
- `enable_thinking=False` и `temp=0.0` в скрипте — не настройки, а условия работы. Тест на их наличие уже есть, он должен остаться зелёным.
- Ветка растёт от `phase-2g-diarization`, а не от `main`: код компилируется против меток с именами.
- Коммиты заканчиваются двумя строками:

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018DSH9V2XNYto5KUUivLhdg
```

---

### Task 1: Третий предел нарезки — бюджет смен говорящего

**Files:**
- Modify: `Core/Summary/TranscriptChunks.swift`
- Modify: `Features/Meetings/MeetingsConfig.swift` (ключ `summaryChunkTurns`)
- Modify: `Features/Meetings/MeetingSummarizer.swift:110-114` (передать новый предел)
- Test: `Tests/CoreTests/TranscriptChunksTests.swift`
- Test: `Tests/MeetingsTests/MeetingsConfigTests.swift`

**Interfaces:**
- Consumes: `TranscriptIndex.Line` (поля `timecode`, `speaker`, `text`)
- Produces: `TranscriptChunks.Chunk(text:seconds:turns:)`, `TranscriptChunks.split(_:maxSeconds:maxCharacters:maxTurns:) -> [Chunk]`, `MeetingsConfig.summaryChunkTurns`

- [ ] **Step 1: Write the failing tests**

```swift
// добавить в Tests/CoreTests/TranscriptChunksTests.swift
private func index(_ lines: [(Double, String, String)]) -> TranscriptIndex {
    TranscriptIndex.parse(
        ([TranscriptIndex.heading]
            + lines.map { "[\(MeetingMarkdown.timestamp($0.0))] \($0.1): \($0.2)" })
            .joined(separator: "\n")
    )
}

// The property no other limit has: a chunk closed by the turn budget ends where one person
// stopped and another started, never inside somebody's speech.
@Test func theTurnBudgetCutsOnASpeakerBoundary() {
    let transcript = index([
        (0, "Я", "раз"), (1, "Настя", "два"), (2, "Я", "три"), (3, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 2)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.contains("Я: раз"))
    #expect(chunks[0].text.contains("Настя: два"))
    #expect(!chunks[0].text.contains("три"))
    #expect(chunks[1].text.contains("Я: три"))
}

// Consecutive lines by one speaker are one turn, however many there are.
@Test func linesOfOneSpeakerInARowAreOneTurn() {
    let transcript = index([
        (0, "Я", "раз"), (1, "Я", "два"), (2, "Я", "три"), (3, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 2)
    #expect(chunks.count == 1)
}

// A monologue has no turns to spend, so the clock is what cuts it — the same behaviour as before
// this task, which is the point: the budget is a ceiling for dense stretches, not a replacement.
@Test func aMonologueIsCutByTheClockRatherThanTheBudget() {
    let transcript = index((0..<20).map { (Double($0) * 60, "Я", "слово\($0)") })
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 300, maxCharacters: 100_000, maxTurns: 25)
    #expect(chunks.count == 4)
}

@Test func everyLineLandsInExactlyOneChunkInOrder() {
    let transcript = index((0..<40).map { (Double($0) * 3, $0 % 2 == 0 ? "Я" : "Настя", "слово\($0)") })
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 7)
    let rejoined = chunks.map(\.text).joined(separator: "\n").components(separatedBy: "\n")
    #expect(rejoined.count == 40)
    for number in 0..<40 {
        #expect(rejoined[number].contains("слово\(number)"))
    }
}

// Three limits, and whichever comes first wins.
@Test func theFirstLimitToTripIsTheOneThatCuts() {
    let dense = index((0..<40).map { (Double($0), $0 % 2 == 0 ? "Я" : "Настя", "слово\($0)") })
    // Turns trip first: 40 lines alternate, so the budget of 5 is reached long before 900 seconds.
    #expect(TranscriptChunks.split(dense, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 5).count == 8)
    // Characters trip first: a budget nothing else can reach.
    #expect(TranscriptChunks.split(dense, maxSeconds: 900, maxCharacters: 60, maxTurns: 100).count > 8)
}

// The numbers the owner needs to turn the budget come out of the cut itself rather than being
// recomputed from its text, where a second implementation could disagree with the first.
@Test func aChunkReportsItsLengthAndItsTurns() {
    let transcript = index([
        (0, "Я", "раз"), (10, "Настя", "два"), (20, "Я", "три"), (200, "Настя", "четыре"),
    ])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 3)
    #expect(chunks.count == 2)
    #expect(chunks[0].turns == 3)
    #expect(chunks[0].seconds == 20)
    #expect(chunks[1].turns == 1)
    #expect(chunks[1].seconds == 0)
}

@Test func aTurnBudgetOfOneGivesOneChunkPerSpeakerStretch() {
    let transcript = index([(0, "Я", "раз"), (1, "Я", "два"), (2, "Настя", "три")])
    let chunks = TranscriptChunks.split(transcript, maxSeconds: 900, maxCharacters: 100_000, maxTurns: 1)
    #expect(chunks.count == 2)
    #expect(chunks[0].text.contains("раз") && chunks[0].text.contains("два"))
    #expect(chunks[1].text.contains("три"))
}
```

```swift
// добавить в Tests/MeetingsTests/MeetingsConfigTests.swift
@Test func theTurnBudgetHasAMeasuredDefault() {
    #expect(MeetingsConfig.default.summaryChunkTurns == 25)
}

@Test func aFileWithoutTheTurnBudgetStillReads() throws {
    let config = try MeetingsConfig.decode(Data(#"{"summaryChunkSeconds": 600}"#.utf8))
    #expect(config.summaryChunkSeconds == 600)
    #expect(config.summaryChunkTurns == 25)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'TranscriptChunksTests|MeetingsConfigTests'`
Expected: FAIL — `extra argument 'maxTurns' in call`

- [ ] **Step 3: Add the limit**

В `Core/Summary/TranscriptChunks.swift` заменить сигнатуру и тело цикла:

```swift
    /// - Parameter maxTurns: how many speaker turns one chunk may hold. A **turn** is a line whose
    ///   speaker differs from the previous line's *within the same chunk*; the chunk's first line
    ///   opens the first turn. The chunk closes before the line that would open turn `maxTurns + 1`,
    ///   which gives this limit a property the other two lack: a chunk closed by the budget always
    ///   ends on a boundary between speakers rather than inside somebody's speech.
    ///
    ///   Measured on 2026-09-11, and it is the reason this parameter exists: a sixteen-minute
    ///   meeting cut at fifteen minutes put 59 turns in one chunk and produced 1 point out of 13,
    ///   while five-minute chunks — 22, 13 and 25 turns — produced 5. The chunks that worked
    ///   elsewhere in the archive carry 12–29. Density cannot be measured in lines or words: lines
    ///   per minute is a property of whoever transcribed the meeting, and the failing meeting was
    ///   *slower* in words per minute than one where fifteen minutes worked.
    ///
    ///   Files written before phase 2г, and other people's transcripts, are cut by the same rule
    ///   on whatever labels they carry. Their turns are undercounted — every interlocutor is one
    ///   «Собеседник» — so their chunks come out larger, but never longer than `maxSeconds`, which
    ///   is what they get today.
    /// One chunk, with the two numbers the cut was made on. They travel with the text because
    /// `nohands meeting summarize` prints them for tuning, and recomputing them from the rendered
    /// lines would be a second implementation that could disagree with the one that cut.
    public struct Chunk: Equatable, Sendable {
        public var text: String
        /// From the first line's timecode to the last's. Zero for a chunk of one line.
        public var seconds: TimeInterval
        public var turns: Int

        public init(text: String, seconds: TimeInterval, turns: Int) {
            self.text = text
            self.seconds = seconds
            self.turns = turns
        }
    }

    public static func split(
        _ index: TranscriptIndex,
        maxSeconds: TimeInterval,
        maxCharacters: Int,
        maxTurns: Int
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [String] = []
        var currentCharacters = 0
        var chunkStart: TimeInterval = 0
        var chunkEnd: TimeInterval = 0
        var turns = 0
        var lastSpeaker: String?

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(
                Chunk(
                    text: current.joined(separator: "\n"),
                    seconds: chunkEnd - chunkStart,
                    turns: turns
                )
            )
            current = []
            currentCharacters = 0
            turns = 0
            lastSpeaker = nil
        }

        for line in index.lines {
            let rendered = "[\(MeetingMarkdown.timestamp(line.timecode))] \(line.speaker): \(line.text)"
            if current.isEmpty {
                chunkStart = line.timecode
                turns = 1
                lastSpeaker = line.speaker
            } else {
                let opensTurn = line.speaker != lastSpeaker
                let turnsWouldExceed = opensTurn && turns + 1 > maxTurns
                let spanWouldExceed = line.timecode - chunkStart >= maxSeconds
                let sizeWouldExceed = currentCharacters + rendered.count > maxCharacters
                if turnsWouldExceed || spanWouldExceed || sizeWouldExceed {
                    flush()
                    chunkStart = line.timecode
                    turns = 1
                    lastSpeaker = line.speaker
                } else if opensTurn {
                    turns += 1
                    lastSpeaker = line.speaker
                }
            }
            current.append(rendered)
            chunkEnd = line.timecode
            // Newline included, so the sum matches what `joined(separator:)` will produce.
            currentCharacters += rendered.count + 1
        }
        flush()
        return chunks
    }
```

В `MeetingSummarizer.summarize` взять `.map(\.text)` перед вызовом раннера: раннеру нужны только тексты.

Обновить доккомментарий типа: пятнадцать минут перестали быть единственным правилом, теперь это потолок для спокойных участков.

В `MeetingsConfig` добавить ключ по образцу соседних — свойство, значение в `default`, параметр `init` с умолчанием, разбор в `init(from:)`:

```swift
    /// How many speaker turns one chunk of the transcript may hold before it is closed.
    ///
    /// The size of a chunk is a property of the meeting, not one number for all of them.
    /// Measured on 2026-09-11: a sixteen-minute meeting whose single chunk held 59 turns produced
    /// one point out of thirteen, while the same meeting in three chunks of 22, 13 and 25 turns
    /// produced five. Chunks that worked elsewhere in the archive hold 12–29.
    ///
    /// The number is deliberately on the safe side: until phase 2г every interlocutor was one
    /// «Собеседник», so turns in the archive are undercounted and the real budget is likely
    /// larger. Calibrating it needs meetings with the voices told apart.
    public var summaryChunkTurns: Int
```

значение в `default`: `summaryChunkTurns: 25`.

В `MeetingSummarizer.summarize` передать его в `TranscriptChunks.split(… maxTurns: config.summaryChunkTurns)`.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter 'TranscriptChunksTests|MeetingsConfigTests'`
Expected: PASS

- [ ] **Step 5: Run the whole suite and commit**

```bash
swift test
git add Core Features Tests
git commit -m "Кусок конспекта закрывается по бюджету смен говорящего"
```

---

### Task 2: Скрипт становится исполнителем списка промптов

**Files:**
- Modify: `Core/LLM/SummaryScript.swift` (весь питон)
- Modify: `Core/LLM/MLXSummaryRunner.swift` (`Request`, `encodedRequest`, `run`, `blockingRun`)
- Test: `Tests/CoreTests/MLXSummaryRunnerTests.swift`

**Interfaces:**
- Produces: `Request(model:answersPath:prompts:)` с `Request.Prompt(system:user:maxTokens:)`, `MLXSummaryRunner.encodedRequest(prompts:answersPath:) -> Data`, `run(uv:prompts:) async throws -> [String]`

- [ ] **Step 1: Write the failing test**

```swift
// заменить в Tests/CoreTests/MLXSummaryRunnerTests.swift тест, читающий запрос обратно,
// и добавить рядом
@Test func theRequestCarriesOnePromptPerChunkAndAPathForTheAnswers() throws {
    let runner = MLXSummaryRunner(
        uvPath: "/nowhere/uv", model: "модель", timeout: 60, contextTokens: 28_000
    )
    let data = try runner.encodedRequest(
        prompts: [
            .init(system: "инструкция", user: "первый", maxTokens: 2500),
            .init(system: "инструкция", user: "второй", maxTokens: 2500),
        ],
        answersPath: "/tmp/ответы.json"
    )
    let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(request?["model"] as? String == "модель")
    #expect(request?["answersPath"] as? String == "/tmp/ответы.json")
    let prompts = request?["prompts"] as? [[String: Any]]
    #expect(prompts?.count == 2)
    #expect(prompts?[0]["user"] as? String == "первый")
    #expect(prompts?[0]["maxTokens"] as? Int == 2500)
    // The merge is Swift's job now: nothing in the request tells the script about it.
    #expect(request?["mergeSystem"] == nil)
    #expect(request?["chunks"] == nil)
}

// The script is what the subprocess runs; two lines of it are conditions of the work rather
// than preferences, and one is the new contract.
@Test func theScriptKeepsItsConditionsAndWritesAnswersToAFile() {
    #expect(SummaryScript.source.contains("enable_thinking=False"))
    #expect(SummaryScript.source.contains("temp=0.0"))
    #expect(SummaryScript.source.contains("request[\"answersPath\"]"))
    #expect(SummaryScript.source.contains("json.dump"))
    // The merge and the JSON check moved to Swift; leaving either here would be a second
    // implementation nobody tests.
    #expect(!SummaryScript.source.contains("mergeSystem"))
    #expect(!SummaryScript.source.contains("def is_json"))
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter MLXSummaryRunnerTests`
Expected: FAIL — `extra argument 'answersPath'`

- [ ] **Step 3: Rewrite the script**

В `Core/LLM/SummaryScript.swift` заменить всё после `import` на исполнителя. Докстрока переписывается — она описывает конвейер, которого больше нет:

```python
"""Runs Qwen3 8B over a list of prompts and writes the answers to a file.

Launched as a subprocess by MLXSummaryRunner: request as a JSON file whose path is the first
argument, answers as a JSON array of strings written to the path the request names, diagnostics
on stderr. Both travel as files because a transcript, and a whole meeting's worth of partial
summaries, are larger than a pipe's buffer.

The model is loaded once and reused for every prompt: loading costs fifteen seconds cold, and a
five-prompt meeting would otherwise pay it five times.

This script decides nothing. Which prompts to send, in what order, what to do with an answer that
does not parse, and whether a merge is needed at all are Swift's, where tests can see them.

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

    answers = [
        answer(model, tokenizer, prompt["system"], prompt["user"], prompt["maxTokens"])
        for prompt in request["prompts"]
    ]

    with open(request["answersPath"], "w", encoding="utf-8") as answers_file:
        json.dump(answers, answers_file, ensure_ascii=False)


main()
```

- [ ] **Step 4: Rewrite the request and the run**

В `MLXSummaryRunner`:

```swift
    struct Request: Encodable {
        struct Prompt: Encodable {
            var system: String
            var user: String
            var maxTokens: Int
        }

        var model: String
        /// Where the child writes its answers. A file rather than stdout: one pass returns every
        /// chunk's partial summary at once, which on a long meeting is hundreds of kilobytes —
        /// far past Darwin's 64 KB pipe buffer, where the child would block on the write and the
        /// run would surface as a timeout. The request already travels this road.
        var answersPath: String
        var prompts: [Prompt]
    }

    /// Everything the subprocess is told, built apart from running it so a test can read it back.
    func encodedRequest(prompts: [Request.Prompt], answersPath: String) throws -> Data {
        try JSONEncoder().encode(
            Request(model: model, answersPath: answersPath, prompts: prompts)
        )
    }
```

`run` и `blockingRun` меняют возвращаемый тип с `String` на `[String]`:

- `blockingRun(uv:request:)` получает второй временный путь рядом с файлом запроса — `nohands-summary-answers-<uuid>.json` — и удаляет его тем же `defer`;
- путь передаётся внутрь через `encodedRequest`, поэтому запрос собирается уже в `blockingRun`, а не до него: подпись становится `blockingRun(uv:prompts:)`, и то же самое у `run`;
- stdout остаётся трубой, но больше не несёт ответа: он читается и выбрасывается, как и раньше делали с пустым выводом. Комментарий про 64 КБ у stdout заменить — ограничение переехало на файл, и трубе больше нечего переполнять;
- после успешного завершения процесса файл ответов читается и декодируется как `[String]`. Пустой или непарсящийся файл — `Failure.runnerFailed("the summary runner wrote no readable answers")`. Число ответов сверяется с числом промптов там, где вызывают.

Всё остальное в `blockingRun` — таймаут, эскалация до `SIGKILL`, диагностика в файл, `lastLine` — остаётся как есть.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MLXSummaryRunnerTests`
Expected: PASS. `summarize` пока не собирается — её переписывает задача 3; чтобы ветка компилировалась между задачами, временно соберите в `summarize` один запуск со всеми кусками и разберите первый ответ. Задача 3 заменит это целиком.

- [ ] **Step 6: Run the whole suite and commit**

```bash
swift test
git add Core Tests
git commit -m "Скрипт конспекта исполняет список промптов и пишет ответы в файл"
```

---

### Task 3: Оркестровка в Swift — два запуска и сборка пунктов кодом

**Files:**
- Modify: `Core/LLM/MLXSummaryRunner.swift` (`summarize`)
- Modify: `Core/LLM/SummaryPrompt.swift` (промпт сведения и сборка его сообщения)
- Test: `Tests/CoreTests/SummaryPromptTests.swift` (создать, если нет)
- Test: `Tests/CoreTests/SummaryAssemblyTests.swift`

**Interfaces:**
- Consumes: `Request.Prompt`, `run(uv:prompts:)` из задачи 2; `SummaryResponse.parse`
- Produces: `SummaryPrompt.mergeUser(summaries:) -> String`, `SummaryAssembly.combine(partials:refusals:merged:) -> MeetingSummary`

- [ ] **Step 1: Write the failing tests**

Сборка — чистая функция, поэтому она и тестируется, а не приватная кухня раннера:

```swift
// Tests/CoreTests/SummaryAssemblyTests.swift
import Foundation
import Testing
@testable import Core

private func partial(_ title: String, _ summary: [String], decisions: [String] = [], tasks: [String] = [], issues: [String] = []) -> MeetingSummary {
    MeetingSummary(
        title: title,
        summary: summary,
        decisions: decisions.map { MeetingSummary.Decision(text: $0, quote: "цитата \($0)") },
        tasks: tasks.map { MeetingSummary.Task(text: $0, owner: "", due: "", quote: "цитата \($0)") },
        openIssues: issues
    )
}

// Points are the code's job now: concatenated in meeting order, with nothing rewritten.
@Test func pointsAreConcatenatedInChunkOrder() {
    let combined = SummaryAssembly.combine(
        partials: [
            partial("первый", ["о первом"], decisions: ["решение A"], tasks: ["задача A"], issues: ["вопрос A"]),
            partial("второй", ["о втором"], decisions: ["решение Б"], tasks: ["задача Б"], issues: ["вопрос Б"]),
        ],
        refusals: [],
        merged: partial("вся встреча", ["итог"])
    )
    #expect(combined.decisions.map(\.text) == ["решение A", "решение Б"])
    #expect(combined.tasks.map(\.text) == ["задача A", "задача Б"])
    #expect(combined.openIssues == ["вопрос A", "вопрос Б"])
    #expect(combined.decisions.map(\.quote) == ["цитата решение A", "цитата решение Б"])
}

// The merge decides only the title and the summary — that is the whole reason it never sees a
// decision or a quote and therefore cannot damage one.
@Test func theMergeDecidesOnlyTheTitleAndTheSummary() {
    let combined = SummaryAssembly.combine(
        partials: [partial("первый", ["о первом"], decisions: ["решение A"]), partial("второй", ["о втором"])],
        refusals: [],
        merged: partial("вся встреча", ["итог"], decisions: ["решение, которого не было"])
    )
    #expect(combined.title == "вся встреча")
    #expect(combined.summary == ["итог"])
    #expect(combined.decisions.map(\.text) == ["решение A"])
}

@Test func aSingleChunkNeedsNoMergeAndKeepsItsOwnTitle() {
    let combined = SummaryAssembly.combine(
        partials: [partial("одна часть", ["о ней"], decisions: ["решение A"])],
        refusals: [],
        merged: nil
    )
    #expect(combined.title == "одна часть")
    #expect(combined.summary == ["о ней"])
    #expect(combined.decisions.count == 1)
}

// A chunk whose answer did not parse is named in the file rather than passed over in silence:
// the reader must be able to tell "nothing was said here" from "we could not read it".
@Test func aRefusedChunkIsNamedInTheSummary() {
    let combined = SummaryAssembly.combine(
        partials: [partial("одна часть", ["о ней"])],
        refusals: ["Кусок 2: ответ модели не разобран"],
        merged: nil
    )
    #expect(combined.summary == ["о ней", "Кусок 2: ответ модели не разобран"])
}

// A failed merge costs the title and the summary, never the points: losing a whole meeting's
// decisions over a headline is the trade this project refuses, the same way a failed cleanup
// still inserts the dictated text.
@Test func aFailedMergeKeepsThePointsAndNamesTheReason() {
    let combined = SummaryAssembly.combine(
        partials: [partial("первый", ["о первом"], decisions: ["решение A"]), partial("второй", ["о втором"], tasks: ["задача Б"])],
        refusals: ["Сведение не удалось: ответ модели не разобран"],
        merged: nil
    )
    #expect(combined.title.isEmpty)
    #expect(combined.summary == ["Сведение не удалось: ответ модели не разобран"])
    #expect(combined.decisions.map(\.text) == ["решение A"])
    #expect(combined.tasks.map(\.text) == ["задача Б"])
}
```

```swift
// Tests/CoreTests/SummaryPromptTests.swift
import Foundation
import Testing
@testable import Core

@Test func theMergeMessageCarriesOnlySummaries() {
    let message = SummaryPrompt.mergeUser(summaries: [["о первом", "и ещё"], ["о втором"]])
    #expect(message.hasPrefix(SummaryPrompt.mergePrefix))
    #expect(message.contains("Часть 1:"))
    #expect(message.contains("Часть 2:"))
    #expect(message.contains("о первом"))
    #expect(message.contains("о втором"))
    #expect(message.contains(TranscriptEnvelope.openingMarker))
}

// The merge prompt asks for two fields now. Asking for the others would invite the model to
// rewrite points the code already assembled — and its answer for them would be discarded, which
// is worse than not asking: a silently ignored instruction teaches the next reader nothing.
@Test func theMergePromptAsksOnlyForTheTitleAndTheSummary() {
    #expect(SummaryPrompt.merge.contains("title"))
    #expect(SummaryPrompt.merge.contains("summary"))
    #expect(!SummaryPrompt.merge.contains("decisions"))
    #expect(!SummaryPrompt.merge.contains("tasks"))
    #expect(!SummaryPrompt.merge.contains("openIssues"))
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter 'SummaryAssemblyTests|SummaryPromptTests'`
Expected: FAIL — `cannot find 'SummaryAssembly' in scope`

- [ ] **Step 3: Write the assembly**

```swift
// Core/Summary/SummaryAssembly.swift
import Foundation

/// Builds one meeting summary out of the chunks' partial ones.
///
/// The points — decisions, tasks, open issues — are concatenated here, by code, in meeting order,
/// with neither text nor quote touched. Only the title and the summary come from the model's
/// merge pass, and only when there is more than one partial to merge. That split is what makes a
/// merge unable to damage a quote: it never sees one.
///
/// The cost is named rather than hidden: an agreement voiced in two parts of the meeting now
/// appears twice, and a question raised early and closed late stays in the open issues. Nothing
/// collapses repeats any more. That is a visible nuisance; a merge silently rewriting a quote
/// would be an invisible falsehood.
public enum SummaryAssembly {
    /// - Parameters:
    ///   - partials: the chunks that parsed, in meeting order. Never empty — a run where nothing
    ///     parsed is a failure, not a summary.
    ///   - refusals: sentences naming what could not be read — a chunk whose answer did not
    ///     parse, or a merge that failed. They go into the summary because that is where the
    ///     owner reads what the file knows about itself.
    ///   - merged: the merge pass's answer, or `nil` when there was one partial or the merge
    ///     failed. Only its `title` and `summary` are used.
    public static func combine(
        partials: [MeetingSummary],
        refusals: [String],
        merged: MeetingSummary?
    ) -> MeetingSummary {
        let title: String
        let summary: [String]
        if let merged {
            title = merged.title
            summary = merged.summary + refusals
        } else if partials.count == 1, refusals.isEmpty {
            title = partials[0].title
            summary = partials[0].summary
        } else if partials.count == 1 {
            title = partials[0].title
            summary = partials[0].summary + refusals
        } else {
            // Several partials and no merge: the merge is what would have chosen a title, so
            // there is none to give. An invented one — the first chunk's, say — would name the
            // whole meeting after its opening minutes.
            title = ""
            summary = refusals
        }
        return MeetingSummary(
            title: title,
            summary: summary,
            decisions: partials.flatMap(\.decisions),
            tasks: partials.flatMap(\.tasks),
            openIssues: partials.flatMap(\.openIssues)
        )
    }
}
```

- [ ] **Step 4: Rewrite the merge prompt and its message**

В `Core/LLM/SummaryPrompt.swift` заменить `merge` и добавить `mergeUser`:

```swift
    /// The second pass, and now it decides two fields out of five.
    ///
    /// It never sees the transcript, and since this branch it never sees a decision, a task or a
    /// quote either — those are concatenated by `SummaryAssembly`. What is left is the one job a
    /// model is needed for: reading several partial summaries of one meeting and saying what the
    /// meeting was about.
    public static let merge = """
        Вы сводите частичные саммари одной и той же встречи в одно. Каждая часть — несколько \
        строк о том, что обсуждали в своём куске встречи, по порядку.

        Правила:
        - Объедините повторяющееся в один пункт.
        - Не добавляйте ничего, чего нет в частях.
        - Дайте встрече одно название по всему её содержанию, до 60 символов.
        - Оставьте не больше десяти пунктов, самых существенных.

        Отвечайте строго одним объектом JSON без пояснений и без markdown-ограды, с полями:
        title — название встречи;
        summary — массив строк.
        """

    /// The merge message, assembled here rather than in the subprocess: the partials now exist in
    /// Swift, and a second copy of this shape in Python is the drift this project spends its
    /// comments avoiding.
    ///
    /// Each part travels in the same envelope a chunk does. These are the model's own words
    /// rather than the transcript's, but they are still a user turn being handed to a model that
    /// has just been told what to do — and an unmarked one reads as a request.
    public static func mergeUser(summaries: [[String]]) -> String {
        var message = [mergePrefix]
        for (number, summary) in summaries.enumerated() {
            let body = summary.map { "- \($0)" }.joined(separator: "\n")
            message.append("Часть \(number + 1):\n" + TranscriptEnvelope.wrapped(body))
        }
        return message.joined(separator: "\n\n")
    }
```

`mergePrefix` остаётся, его текст — «Частичные конспекты встречи по порядку:» — меняется на «Частичные саммари встречи по порядку:».

- [ ] **Step 5: Rewrite `summarize`**

```swift
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
        let executable = URL(fileURLWithPath: uv)

        // Pass A: one prompt per chunk.
        let answers = try await run(
            uv: executable,
            prompts: chunks.map {
                Request.Prompt(
                    system: SummaryPrompt.system,
                    user: SummaryPrompt.user(chunk: $0),
                    maxTokens: Self.maxTokens
                )
            }
        )
        guard answers.count == chunks.count else {
            throw Failure.runnerFailed(
                "the summary runner answered \(answers.count) of \(chunks.count) prompts"
            )
        }

        var partials: [MeetingSummary] = []
        var refusals: [String] = []
        for (number, raw) in answers.enumerated() {
            // A chunk whose answer does not parse is skipped and named. Failing the whole meeting
            // would be worse and pointless: generation runs at temperature 0, so the retry
            // produces the same unreadable answer for ever.
            if let partial = try? SummaryResponse.parse(raw) {
                partials.append(partial)
            } else {
                refusals.append("Кусок \(number + 1) из \(chunks.count): ответ модели не разобран")
            }
        }
        // Nothing parsed at all: there is no summary to write, and the reason belongs in the file
        // as a permanent failure rather than as a file full of refusal lines.
        guard !partials.isEmpty else { throw SummaryResponse.Failure.notJSON }

        guard partials.count > 1 else {
            return SummaryAssembly.combine(partials: partials, refusals: refusals, merged: nil)
        }

        let mergeUser = SummaryPrompt.mergeUser(summaries: partials.map(\.summary))
        try checkMergeFits(mergeUser)

        // Pass B: one prompt, and it sees only the summaries.
        let mergeAnswer = try await run(
            uv: executable,
            prompts: [
                Request.Prompt(
                    system: SummaryPrompt.merge, user: mergeUser, maxTokens: Self.mergeMaxTokens
                )
            ]
        )
        guard let raw = mergeAnswer.first, let merged = try? SummaryResponse.parse(raw) else {
            // The points survive a failed merge; only the headline is lost. Same shape as a
            // refused cleanup inserting the raw dictation with the reason named.
            return SummaryAssembly.combine(
                partials: partials,
                refusals: refusals + ["Сведение не удалось: ответ модели не разобран"],
                merged: nil
            )
        }
        return SummaryAssembly.combine(partials: partials, refusals: refusals, merged: merged)
    }
```

`checkMergeFits` пишется в задаче 4 — пока пусть будет `private func checkMergeFits(_ message: String) throws {}` с пометкой, что тело добавляет следующая задача.

- [ ] **Step 6: Run everything and commit**

```bash
swift test
git add Core Tests
git commit -m "Пункты собирает код, модель сводит только саммари"
```

---

### Task 4: Страж размера сведения вместо потолка в десять кусков

**Files:**
- Modify: `Core/LLM/MLXSummaryRunner.swift` (`Failure`, `checkMergeFits`)
- Modify: `Features/Meetings/MeetingsConfig.swift` (комментарий у `summaryTimeoutSeconds` и `summaryContextTokens` — они ссылаются на снятый потолок)
- Test: `Tests/CoreTests/MLXSummaryRunnerTests.swift`

**Interfaces:**
- Produces: `MLXSummaryRunner.Failure.mergeTooLong(estimated:limit:)`, `checkMergeFits(_:) throws`
- Removes: `MLXSummaryRunner.Failure.tooManyChunks`

- [ ] **Step 1: Write the failing tests**

```swift
// добавить в Tests/CoreTests/MLXSummaryRunnerTests.swift; удалить старый тест
// theSupportedMeetingLengthIsWhateverTheMergeGuardAllows вместе с tooManyChunks
private func runner(contextTokens: Int) -> MLXSummaryRunner {
    MLXSummaryRunner(uvPath: "/nowhere/uv", model: "модель", timeout: 60, contextTokens: contextTokens)
}

// The guard is arithmetic done before the subprocess starts, because a merge that does not fit
// comes back truncated rather than refused — and truncated JSON reads to the owner as "the model
// could not read your meeting", which is a different and untrue statement.
@Test func aMergeTooLargeForTheWindowIsRefusedWithNumbers() {
    // 4000 − 3000 = 1000 tokens, i.e. 2500 characters at 2.5 per token.
    #expect(throws: MLXSummaryRunner.Failure.self) {
        try runner(contextTokens: 4000).checkMergeFits(String(repeating: "я", count: 3000))
    }
}

@Test func aMergeThatFitsIsNotRefused() throws {
    try runner(contextTokens: 4000).checkMergeFits(String(repeating: "я", count: 2000))
}

// What the removed ten-chunk ceiling used to bound, measured against what the merge actually
// carries now: a chunk's summary is a few lines, so a hundred of them still fit. A four-hour
// dense meeting yields around forty.
@Test func aHundredChunkSummariesStillFitTheMerge() throws {
    let summaries = Array(
        repeating: ["первый пункт куска", "второй пункт куска", "третий пункт куска"],
        count: 100
    )
    try runner(contextTokens: 28_000).checkMergeFits(SummaryPrompt.mergeUser(summaries: summaries))
}

@Test func theMergeRefusalIsPermanent() {
    #expect(MLXSummaryRunner.Failure.mergeTooLong(estimated: 30_000, limit: 25_000).isPermanent)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter MLXSummaryRunnerTests`
Expected: FAIL — `type 'MLXSummaryRunner.Failure' has no member 'mergeTooLong'`

- [ ] **Step 3: Replace the ceiling with the guard**

В `Failure` убрать `tooManyChunks` вместе с его `errorDescription` и строкой в `isPermanent`, добавить:

```swift
        /// The assembled merge message does not fit the window. Permanent for the same reason
        /// `tooLong` is: the meeting's length fixes how many chunks it has, so a retry produces
        /// the same message.
        case mergeTooLong(estimated: Int, limit: Int)
```

с описанием `"The merge of \(estimated) tokens does not fit the \(limit) the window leaves for it"` и `isPermanent = true`.

Тело стража:

```swift
    /// The merge call has to fit what the window leaves after the answer is reserved.
    ///
    /// This replaces the ten-chunk ceiling, which was arithmetic on the worst case: every partial
    /// summary could have filled `maxTokens`, so ten of them plus the prefix was as much as the
    /// window could hold. The merge no longer carries partial summaries — it carries their
    /// `summary` arrays, a few lines each — so the size is known exactly before the call, and
    /// bounding it by a count of chunks would refuse meetings that fit comfortably.
    ///
    /// The practical ceiling moves far out: at a couple of hundred tokens per chunk summary the
    /// window holds more than a hundred chunks, and a four-hour dense meeting yields around
    /// forty. What limits a long meeting now is time, not this.
    func checkMergeFits(_ message: String) throws {
        let estimated = Int(Double(message.count) / Self.charactersPerToken)
        let limit = contextTokens - Self.mergeMaxTokens
        guard estimated <= limit else {
            throw Failure.mergeTooLong(estimated: estimated, limit: limit)
        }
    }
```

В `MeetingsConfig` поправить два доккомментария, которые ссылаются на снятый потолок: у `summaryTimeoutSeconds` («самая длинная встреча, которую примет ветка — 150 минут») и у `summaryContextTokens` («та же арифметика живёт в `theSupportedMeetingLengthIsWhateverTheMergeGuardAllows`»). Оба должны говорить то, что верно теперь: длину встречи ограничивает время счёта и предел записи в четыре часа, а окно проверяется на кусок и на сведение по отдельности.

- [ ] **Step 4: Run everything and commit**

```bash
swift test
git add Core Features Tests
git commit -m "Потолок в десять кусков заменён стражем размера сведения"
```

---

### Task 5: CLI показывает нарезку

**Files:**
- Modify: `CLI/MeetingCommands.swift` (`runMeetingSummarize`)

**Interfaces:**
- Consumes: `TranscriptChunks.Chunk` из задачи 1

- [ ] **Step 1: Print the cut**

В `runMeetingSummarize`, сразу после нарезки и до вызова модели:

```swift
    note("бюджет смен: \(config.summaryChunkTurns), кусков: \(chunks.count)")
    for (number, chunk) in chunks.enumerated() {
        note(
            String(
                format: "  кусок %d: %.1f мин, смен %d, символов %d",
                number + 1, chunk.seconds / 60, chunk.turns, chunk.text.count
            )
        )
    }
```

и к существующей строке про правку порога добавить, что там же правится `summaryChunkTurns`. Причина, по которой это печатается вообще: `loadOrCreate` дописывает секцию `meetings` целиком и только когда её нет, а у владельца она есть — значит новый ключ работает из умолчания и в файле его не видно. Настройку, которую нельзя увидеть, нельзя и повернуть.

- [ ] **Step 2: Run everything and commit**

Печать команды тестами не покрывается — у тел команд нет тестового таргета, `Tests/CLITests` проверяет только разбор аргументов. Прогоните команду руками по копии файла из `~/Meetings/.bench/` и приложите вывод к отчёту.

```bash
swift test
git add CLI
git commit -m "Команда summarize показывает нарезку и бюджет смен"
```

---

### Task 6: Калибровка и живая проверка

Тестов здесь нет: проверяется то, чего тесты не видят, — качество конспекта на настоящих встречах.

Материал уже спасён в `~/Meetings/.bench/`: три встречи от 7 сентября вместе с аудио и прежними расшифровками. Это сделано до истечения недельного окна — 14 сентября папки в очереди удалятся, и мерить будет нечем. Обход архива не рекурсивный и берёт только `.md` в корне, поэтому подпапку приложение не видит.

- [ ] **Step 1: Собрать и прогнать**

```bash
swift build && swift test
```

- [ ] **Step 2: Прогон по копиям, до и после**

Для каждой встречи `.bench` прогнать `nohands meeting summarize` по копии файла и записать: число кусков, минуты и смены каждого, время счёта, число решений и задач, число повторов.

```bash
./.build/debug/nohands meeting summarize ~/Meetings/.bench/2026-09-07-1009-telemost.md
```

Сравнить с тем, что лежит в файле сейчас: 68-минутная встреча на пятнадцатиминутных кусках дала 7 решений и 10 задач. Ожидание спеки — не хуже, плюс повторы, которых раньше не было.

- [ ] **Step 3: Полнота на измеренном материале**

Единственная измеренная полнота — чужая расшифровка шестнадцатиминутной встречи от 11 сентября против списка из тринадцати пунктов. Ни расшифровки, ни списка в `~/Meetings/.bench/` нет; спросить у владельца и положить туда. Ожидание: не хуже пятиминутного прогона, то есть минимум 5 пунктов чисто.

- [ ] **Step 4: Память на самой длинной**

81-минутная встреча меняет нарезку сильнее всего. Снять пик памяти **системным монитором**, а не `ps`: буферы Metal в резидентную память не входят и занижают пик втрое — измерено 8 сентября.

- [ ] **Step 5: Записать итоги**

Дописать в `docs/DECISIONS.md` запись с числами: как порезалось, сколько повторов, что стало с полнотой, какой бюджет выбран в итоге. Правки `docs/` коммитятся и пушатся отдельно и сразу.
