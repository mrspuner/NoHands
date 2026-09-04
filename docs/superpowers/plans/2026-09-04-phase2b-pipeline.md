# Фаза 2б — конвейер расшифровки: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Готовая папка встречи из `~/Meetings/.queue` сама превращается в читаемый markdown в `~/Meetings`, а её WAV — в AAC, который живёт неделю.

**Architecture:** Чистое ядро в `Core` (слова с таймкодами, реплики, слияние дорожек, рендер markdown) плюс актор `MeetingQueue` в `Features/Meetings`, который читает состояние папки по её содержимому и гоняет папки по одной. Очередь берёт собственный экземпляр модели и отпускает его, когда работать не над чем.

**Tech Stack:** Swift 6, swift-testing, FluidAudio 0.14.8 (Parakeet TDT v3), AVFoundation (AVAssetReader/AVAssetWriter для AAC), SwiftUI/AppKit для панели.

**Spec:** `docs/superpowers/specs/2026-09-04-phase2b-pipeline-design.md`

## Global Constraints

- Общение, документация и коммиты — по-русски. Идентификаторы, комментарии в коде и сообщения об ошибках — по-английски.
- Новые зависимости не добавляются. FluidAudio закреплён `.exact("0.14.8")`, менять нельзя.
- Платформа пакета — `.macOS(.v15)`, swift-tools-version 6.0.
- Тесты — swift-testing (`import Testing`, `@Test`, `#expect`), не XCTest.
- Не логировать содержимое транскриптов и распознанного текста. Печать текста по явной команде CLI — не логирование; запись в лог приложения — логирование.
- Не заменять внятную ошибку молчаливым фолбэком.
- Внутри фазы не забегать вперёд: конспект (2в), диаризация (2г) и словарь терминов не реализуются и не абстрагируются.
- Сборка: `swift build`, тесты: `swift test`. Приложение собирается `Scripts/make-app.sh`.
- Коммит после каждой задачи. Правки в `docs/` коммитятся и пушатся отдельно и сразу.

---

### Task 1: `TimedWord` и сборка слов из токенов

Parakeet отдаёт токены, а не слова. `TokenTiming.token` приходит с ведущим пробелом там, где у SentencePiece стоял `▁` (замена делается в `AsrManager.normalizedTimingToken`). Значит правило сборки: токен, начинающийся с пробела, открывает новое слово.

У FluidAudio такая сборка есть (`VocabularyRescorer.buildWordTimings`), но она `internal` и снаружи недоступна.

**Files:**
- Create: `Core/Transcript/TimedWord.swift`
- Create: `Core/Transcription/TokenWordAssembler.swift`
- Test: `Tests/CoreTests/TokenWordAssemblerTests.swift`

**Interfaces:**
- Consumes: `FluidAudio.TokenTiming` (публичный тип с публичным инициализатором)
- Produces: `TimedWord(text:start:end:confidence:)`, `TokenWordAssembler.words(from: [TokenTiming]) -> [TimedWord]`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/TokenWordAssemblerTests.swift
import FluidAudio
import Foundation
import Testing
@testable import Core

private func timing(_ token: String, _ start: Double, _ end: Double, _ confidence: Float = 1) -> TokenTiming {
    TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
}

@Test func leadingSpaceStartsNewWord() {
    let words = TokenWordAssembler.words(from: [
        timing(" при", 0.0, 0.2),
        timing("вет", 0.2, 0.4),
        timing(" мир", 0.5, 0.7),
    ])
    #expect(words.map(\.text) == ["привет", "мир"])
    #expect(words[0].start == 0.0)
    #expect(words[0].end == 0.4)
    #expect(words[1].start == 0.5)
    #expect(words[1].end == 0.7)
}

// The first token usually arrives without a leading space: it starts a word simply by being first.
@Test func firstTokenWithoutSpaceStillStartsAWord() {
    let words = TokenWordAssembler.words(from: [
        timing("да", 1.0, 1.2),
        timing(" нет", 1.4, 1.6),
    ])
    #expect(words.map(\.text) == ["да", "нет"])
}

// The SentencePiece marker is handled the same as a space: `normalizedTimingToken` always
// replaces it, but the library's output shows both forms, and relying on just one would be
// a needless risk.
@Test func sentencePieceMarkerAlsoStartsAWord() {
    let words = TokenWordAssembler.words(from: [
        timing("\u{2581}один", 0.0, 0.3),
        timing("\u{2581}два", 0.4, 0.7),
    ])
    #expect(words.map(\.text) == ["один", "два"])
}

@Test func specialAndEmptyTokensAreSkipped() {
    let words = TokenWordAssembler.words(from: [
        timing("<blank>", 0.0, 0.1),
        timing(" слово", 0.1, 0.4),
        timing("", 0.4, 0.5),
        timing("<pad>", 0.5, 0.6),
    ])
    #expect(words.map(\.text) == ["слово"])
}

@Test func emptyInputGivesNoWords() {
    #expect(TokenWordAssembler.words(from: []).isEmpty)
}

@Test func confidenceIsAveragedOverTheWordsTokens() {
    let words = TokenWordAssembler.words(from: [
        timing(" сло", 0.0, 0.2, 1.0),
        timing("во", 0.2, 0.4, 0.5),
    ])
    #expect(words.count == 1)
    #expect(abs(words[0].confidence - 0.75) < 0.001)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter TokenWordAssemblerTests`
Expected: сборка не проходит — `cannot find 'TokenWordAssembler' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Transcript/TimedWord.swift
import Foundation

/// One recognised word together with the span of audio it came from.
///
/// Parakeet emits subword tokens, not words; this is what they add up to. The span is what
/// everything downstream needs — splitting speech into utterances, measuring how loud a
/// phrase was, and placing two tracks on one timeline all work on times, not on text.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Averaged over the tokens the word was assembled from. Nothing in phase 2б reads it; it
    /// is carried because the decoder hands it over for free and discarding it here would mean
    /// re-running recognition to get it back.
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
```

```swift
// Core/Transcription/TokenWordAssembler.swift
import FluidAudio
import Foundation

/// Turns Parakeet's subword tokens into whole words.
///
/// Lives next to the transcriber rather than with `TimedWord` because this is the one place
/// that knows FluidAudio's token conventions. `TimedWord` itself stays free of the library.
///
/// FluidAudio has the same assembly internally (`VocabularyRescorer.buildWordTimings`) but does
/// not export it, so this is a deliberate twenty-line copy of a rule, not a duplicated
/// implementation of an algorithm.
public enum TokenWordAssembler {
    /// The decoder's own markers. They carry timings like any other token and would otherwise
    /// become words made of angle brackets.
    static let ignoredTokens: Set<String> = ["<blank>", "<pad>"]

    /// SentencePiece's word boundary. `AsrManager.normalizedTimingToken` replaces it with a
    /// plain space before the timing leaves the library, so in practice tokens arrive
    /// space-prefixed — both forms are accepted because relying on that replacement staying in
    /// place costs nothing to avoid.
    static let boundaryMarker = "\u{2581}"

    public static func words(from timings: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidenceSum: Float = 0
        var pieces = 0

        func flush() {
            defer {
                text = ""
                confidenceSum = 0
                pieces = 0
            }
            guard pieces > 0 else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(
                TimedWord(
                    text: trimmed,
                    start: start,
                    end: end,
                    confidence: confidenceSum / Float(pieces)
                )
            )
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || ignoredTokens.contains(token) { continue }
            if token.hasPrefix(" ") || token.hasPrefix(boundaryMarker) { flush() }
            if pieces == 0 { start = timing.startTime }
            text += token.replacingOccurrences(of: boundaryMarker, with: " ")
            end = timing.endTime
            confidenceSum += timing.confidence
            pieces += 1
        }
        flush()
        return words
    }
}
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter TokenWordAssemblerTests`
Expected: PASS, шесть тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Transcript/TimedWord.swift Core/Transcription/TokenWordAssembler.swift Tests/CoreTests/TokenWordAssemblerTests.swift
git commit -m "Слова с таймкодами собираются из токенов Parakeet"
```

---

### Task 2: `transcribeTimed` и сквозной прогон на настоящей записи

Это задача, ради которой она стоит второй: вся фаза держится на предположении, что `tokenTimings` приходят на длинном файле и времена в них сквозные, а не локальные для куска. По исходникам FluidAudio это прослежено — путь идёт через `transcribeDiskBacked` и `ChunkProcessor`, который сортирует токены по общей шкале, — но прослеженное и увиденное не одно и то же. Если предположение не подтвердится, менять придётся весь замысел, и узнать об этом надо здесь, а не на десятой задаче.

**Files:**
- Modify: `Core/Transcription/ParakeetTranscriber.swift`
- Create: `Core/Transcription/TimedTranscriber.swift`
- Test: `Tests/CoreTests/TimedTranscriptionTests.swift`

**Interfaces:**
- Consumes: `TokenWordAssembler.words(from:)`, `TimedWord`
- Produces: `protocol TimedTranscriber { func transcribeTimed(audio url: URL) async throws -> [TimedWord] }`, реализованный `ParakeetTranscriber`

- [ ] **Step 1: Написать падающий тест**

Сквозной тест включается переменной окружения: настоящая запись лежит вне репозитория и через семь дней будет снесена собственной ротацией, поэтому зашивать путь нельзя.

```swift
// Tests/CoreTests/TimedTranscriptionTests.swift
import AVFoundation
import Foundation
import Testing
@testable import Core

private var fixtureURL: URL? {
    guard let path = ProcessInfo.processInfo.environment["NOHANDS_TIMED_FIXTURE"] else { return nil }
    return URL(fileURLWithPath: path)
}

// The only check in the project that needs both the model and a real long file. Skipped when
// the recording is missing: it is about something invisible in clean unit tests — that a long
// file's timestamps run continuously, rather than resetting at every thirty-second chunk.
@Test(.enabled(if: fixtureURL != nil))
func timedTranscriptionOfALongFileHasGlobalTimestamps() async throws {
    let url = try #require(fixtureURL)
    let transcriber = try await ParakeetTranscriber.load(language: "ru")
    let words = try await transcriber.transcribeTimed(audio: url)

    #expect(!words.isEmpty, "no words in the recording")

    // FluidAudio's chunks are thirty seconds long. A word starting later proves that timestamps
    // do not reset at the chunk boundary.
    let latest = words.map(\.start).max() ?? 0
    #expect(latest > 30, "every word fell inside the first 30 s — timestamps look chunk-local")

    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    #expect(latest <= duration + 1, "a word starts past the end of the file")

    for (previous, next) in zip(words, words.dropFirst()) {
        #expect(previous.start <= next.start, "words arrived out of order")
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `NOHANDS_TIMED_FIXTURE="$HOME/Meetings/.queue/2026-09-04-1053-telemost/system.wav" swift test --filter TimedTranscriptionTests`
Expected: сборка не проходит — у `ParakeetTranscriber` нет `transcribeTimed`.

Если папки уже нет на месте, подставьте любую свою запись длиннее минуты. Без переменной тест пропускается, и это не считается «прошло».

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Transcription/TimedTranscriber.swift
import Foundation

/// Turns an audio file into words with the times they were spoken at.
///
/// Separate from `Transcriber` rather than an addition to it: dictation needs a string and
/// nothing else, and `ScribeTranscriber` has no timings to give. A protocol exists here at all
/// — despite the project's rule against abstracting single implementations — because
/// `MeetingQueue` has to be testable without a 470 MB model, exactly as `MeetingCapture` exists
/// so the coordinator can be tested without a screen recording.
public protocol TimedTranscriber: Sendable {
    func transcribeTimed(audio url: URL) async throws -> [TimedWord]
}
```

В `Core/Transcription/ParakeetTranscriber.swift` объявить соответствие и добавить метод рядом с `transcribe(audio:)`:

```swift
public actor ParakeetTranscriber: Transcriber, TimedTranscriber {
```

```swift
    /// Words with their times, for meetings. Deliberately does **not** apply
    /// `TranscriberChecks.nonEmpty`: a track that recorded nothing but silence is a legitimate
    /// outcome of a meeting — the owner may have sat the whole hour muted — and turning that
    /// into an error here would make every such meeting unprocessable. Both tracks coming back
    /// empty is a real failure, and it is caught one level up, where both are in hand.
    public func transcribeTimed(audio url: URL) async throws -> [TimedWord] {
        try await decode(url) { TokenWordAssembler.words(from: $0.tokenTimings ?? []) }
    }
```

Обе публичные функции различаются одной строкой — тем, что берут из результата, — поэтому всё
остальное живёт в одном месте. Иначе новая ветка в разборе `ASRError` появлялась бы в двух
копиях, и ничто не заставило бы их совпасть.

```swift
    /// The decode both public methods run, differing only in what they take from the result.
    ///
    /// Extracted rather than copied: the error mapping below is the part that will grow — a new
    /// `ASRError` case, a new distinction worth making — and two copies of it would drift apart
    /// silently, because nothing fails when only one of them learns something.
    private func decode<T>(
        _ url: URL,
        extract: (ASRResult) throws -> T
    ) async throws -> T {
        try TranscriberChecks.validateReadable(url)

        // `AsrManager.transcribe(_:decoderState:language:)` reads and resamples the file itself
        // through FluidAudio's own `AudioConverter` — the library's docs warn against hand-
        // decoding audio, so this deliberately does not touch the file's bytes beyond the
        // readability check above.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        do {
            let result = try await manager.transcribe(url, decoderState: &decoderState, language: language)
            return try extract(result)
        } catch let error as ASRError {
            if case .invalidAudioData = error {
                throw TranscriptionError.audioTooShort(try Self.duration(of: url))
            }
            // Every other ASRError (not initialized, model load, processing, compilation,
            // unsupported platform, encoder instantiation) is a broken local model, not a bad
            // request — `modelUnavailable` is the case for that.
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
    }
```

`transcribe(audio:)` переписывается на тот же вызов, сохраняя свою проверку на пустоту:

```swift
    public func transcribe(audio url: URL) async throws -> String {
        try await decode(url) { try TranscriberChecks.nonEmpty($0.text) }
    }
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `NOHANDS_TIMED_FIXTURE="$HOME/Meetings/.queue/2026-09-04-1053-telemost/system.wav" swift test --filter TimedTranscriptionTests`
Expected: PASS. В выводе должно быть видно, что тест не пропущен.

**Если тест упал на проверке про 30 секунд — остановиться и сказать об этом.** Это значит, что времена локальные для куска, и спека требует пересмотра, а не обхода в коде.

- [ ] **Step 5: Коммит**

```bash
git add Core/Transcription/TimedTranscriber.swift Core/Transcription/ParakeetTranscriber.swift Tests/CoreTests/TimedTranscriptionTests.swift
git commit -m "Parakeet отдаёт слова с таймкодами, проверено на длинной записи"
```

---

### Task 3: Пять ключей в `MeetingsConfig`

Все пять добавляются разом, а не по одному в каждой задаче: файл один, и пять заходов в него означали бы пять конфликтов на ровном месте.

**Files:**
- Modify: `Features/Meetings/MeetingsConfig.swift`
- Test: `Tests/MeetingsTests/MeetingsConfigTests.swift`

**Interfaces:**
- Produces: `MeetingsConfig.phraseGapSeconds: Double`, `.maxPhraseSeconds: Double`, `.micThresholdDBFS: Double`, `.audioRetentionDays: Int`, `.aacBitrate: Int`

- [ ] **Step 1: Написать падающий тест**

Дописать в `Tests/MeetingsTests/MeetingsConfigTests.swift`:

```swift
@Test func pipelineKeysHaveDefaults() throws {
    let config = try MeetingsConfig.decode(Data("{}".utf8))
    #expect(config.phraseGapSeconds == 1.0)
    #expect(config.maxPhraseSeconds == 40)
    #expect(config.micThresholdDBFS == -30)
    #expect(config.audioRetentionDays == 7)
    #expect(config.aacBitrate == 32000)
}

@Test func pipelineKeysAreReadFromTheFile() throws {
    let json = """
    {"phraseGapSeconds": 1.5, "maxPhraseSeconds": 20, "micThresholdDBFS": -42,
     "audioRetentionDays": 3, "aacBitrate": 24000}
    """
    let config = try MeetingsConfig.decode(Data(json.utf8))
    #expect(config.phraseGapSeconds == 1.5)
    #expect(config.maxPhraseSeconds == 20)
    #expect(config.micThresholdDBFS == -42)
    #expect(config.audioRetentionDays == 3)
    #expect(config.aacBitrate == 24000)
    // Keys absent from the file stayed at their defaults — the general rule for this config.
    #expect(config.autoStopSeconds == MeetingsConfig.default.autoStopSeconds)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingsConfigTests`
Expected: сборка не проходит — `value of type 'MeetingsConfig' has no member 'phraseGapSeconds'`.

- [ ] **Step 3: Написать минимальную реализацию**

Добавить пять свойств рядом с существующими:

```swift
    /// Pause that starts a new utterance. Speech is split on silence, not on punctuation: the
    /// recogniser's full stops are a guess, while a second of nothing is a fact.
    public var phraseGapSeconds: Double
    /// Hard ceiling on one utterance. Without it a ten-minute monologue with no pause long
    /// enough becomes one unreadable line.
    public var maxPhraseSeconds: Double
    /// Below this, an utterance on the microphone track is treated as the room rather than as
    /// the owner. Provisional until measured — see the plan's last task.
    public var micThresholdDBFS: Double
    /// How long compressed audio survives after the meeting started.
    public var audioRetentionDays: Int
    /// AAC bitrate for the archived tracks.
    public var aacBitrate: Int
```

В `default` дописать:

```swift
        phraseGapSeconds: 1.0,
        maxPhraseSeconds: 40,
        // A provisional value, set just so the pipeline builds. Speech at the first live meeting
        // hit three quarters of the scale — around -2.5 dBFS — while the room across the table
        // was reliably quieter. The real value is set by measuring with `nohands meeting levels`.
        micThresholdDBFS: -30,
        audioRetentionDays: 7,
        aacBitrate: 32000
```

Расширить `init` пятью параметрами (в том же порядке) и присваиваниями, а в `init(from:)` дописать пять строк по образцу соседних:

```swift
        phraseGapSeconds = try container.decodeIfPresent(Double.self, forKey: .phraseGapSeconds)
            ?? fallback.phraseGapSeconds
        maxPhraseSeconds = try container.decodeIfPresent(Double.self, forKey: .maxPhraseSeconds)
            ?? fallback.maxPhraseSeconds
        micThresholdDBFS = try container.decodeIfPresent(Double.self, forKey: .micThresholdDBFS)
            ?? fallback.micThresholdDBFS
        audioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .audioRetentionDays)
            ?? fallback.audioRetentionDays
        aacBitrate = try container.decodeIfPresent(Int.self, forKey: .aacBitrate)
            ?? fallback.aacBitrate
```

`CodingKeys` в этом типе синтезируются автоматически для всех свойств, кроме переопределённых во вложенных типах, — отдельно объявлять ключи не нужно.

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Run: `swift test --filter MeetingsConfigTests`
Expected: PASS. Проверить, что `defaultsFillEveryMissingKey` тоже прошёл — он сравнивает целиком и поймает забытое поле в `init(from:)`.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingsConfig.swift Tests/MeetingsTests/MeetingsConfigTests.swift
git commit -m "Пять ключей конвейера в конфиге встреч"
```

---

### Task 4: Резка слов на реплики

**Files:**
- Create: `Core/Transcript/Utterance.swift`
- Test: `Tests/CoreTests/UtteranceTests.swift`

**Interfaces:**
- Consumes: `TimedWord`
- Produces: `Utterance.Speaker` (`.me`, `.others`), `Utterance(speaker:start:end:text:)`, `Utterance.split(words:speaker:gap:maxLength:) -> [Utterance]`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/UtteranceTests.swift
import Foundation
import Testing
@testable import Core

private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end, confidence: 1)
}

@Test func aLongPauseStartsANewUtterance() {
    let result = Utterance.split(
        words: [word("раз", 0, 0.4), word("два", 0.5, 0.9), word("три", 3.0, 3.4)],
        speaker: .me, gap: 1.0, maxLength: 40
    )
    #expect(result.count == 2)
    #expect(result[0].text == "раз два")
    #expect(result[0].start == 0)
    #expect(result[0].end == 0.9)
    #expect(result[1].text == "три")
    #expect(result[1].start == 3.0)
}

@Test func aShortPauseKeepsOneUtterance() {
    let result = Utterance.split(
        words: [word("раз", 0, 0.4), word("два", 1.2, 1.6)],
        speaker: .others, gap: 1.0, maxLength: 40
    )
    #expect(result.count == 1)
    #expect(result[0].text == "раз два")
    #expect(result[0].speaker == .others)
}

// A monologue with not one sufficient pause still has to be cut, or the transcript ends up as
// one line filling the whole screen.
@Test func theLengthCeilingCutsAMonologue() {
    let words = (0..<20).map { index -> TimedWord in
        let start = Double(index) * 1.0
        return word("слово", start, start + 0.9)
    }
    let result = Utterance.split(words: words, speaker: .me, gap: 1.5, maxLength: 5)
    #expect(result.count > 1)
    for utterance in result {
        #expect(utterance.end - utterance.start <= 5.5)
    }
}

@Test func noWordsGiveNoUtterances() {
    #expect(Utterance.split(words: [], speaker: .me, gap: 1, maxLength: 40).isEmpty)
}

@Test func aSingleWordIsAnUtterance() {
    let result = Utterance.split(words: [word("да", 2, 2.3)], speaker: .me, gap: 1, maxLength: 40)
    #expect(result.count == 1)
    #expect(result[0].text == "да")
    #expect(result[0].start == 2)
    #expect(result[0].end == 2.3)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter UtteranceTests`
Expected: сборка не проходит — `cannot find 'Utterance' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Transcript/Utterance.swift
import Foundation

/// One continuous stretch of speech by one side of the conversation.
///
/// Two speakers and no more, because phase 2б has no way to tell one interlocutor from another
/// — that is 2г's job. What it does know for free is which track a word came from, and that is
/// exactly the difference between the owner and everyone else.
public struct Utterance: Equatable, Sendable {
    public enum Speaker: String, Equatable, Sendable, CaseIterable {
        case me
        case others
    }

    public var speaker: Speaker
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: Speaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    /// Cuts a stream of words into utterances on two rules: a silence longer than `gap`, and a
    /// hard ceiling of `maxLength`.
    ///
    /// Silence rather than the recogniser's punctuation: full stops from a decoder are a guess,
    /// while a second of nothing between two words is a fact about the audio. The ceiling is
    /// there for the speaker who never gives one — without it a monologue becomes a single line.
    public static func split(
        words: [TimedWord],
        speaker: Speaker,
        gap: TimeInterval,
        maxLength: TimeInterval
    ) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            utterances.append(
                Utterance(
                    speaker: speaker,
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " ")
                )
            )
            current = []
        }

        for word in words {
            if let last = current.last, let first = current.first {
                if word.start - last.end > gap || word.end - first.start > maxLength { flush() }
            }
            current.append(word)
        }
        flush()
        return utterances
    }
}
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter UtteranceTests`
Expected: PASS, пять тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Transcript/Utterance.swift Tests/CoreTests/UtteranceTests.swift
git commit -m "Слова режутся на реплики по паузам и по пределу длины"
```

---

### Task 5: Замер громкости реплики и отсечка фона

Решение от 2026-09-04: фон отсекается при расшифровке, а не при записи. Реплика оценивается по громчайшему стомиллисекундному окну внутри её интервала и проходит целиком либо выбрасывается целиком.

По максимуму, а не по среднему: реплика, начатая тихо и продолженная в полный голос, — своя, а среднее размазало бы её ниже порога.

**Files:**
- Create: `Core/Audio/AudioDuration.swift`
- Create: `Core/Audio/PhraseLevel.swift`
- Modify: `Core/Audio/AudioLevel.swift` (публичная перегрузка RMS для Float)
- Modify: `Core/Transcription/ParakeetTranscriber.swift` (убрать приватный дубликат `duration(of:)`)
- Test: `Tests/CoreTests/PhraseLevelTests.swift`

**Interfaces:**
- Consumes: `Utterance`
- Produces: `AudioDuration.seconds(of: URL) throws -> TimeInterval`, `PhraseLevel.peakDBFS(of:from:to:) throws -> Float`, `PhraseLevel.passing(_:thresholdDBFS:level:) rethrows -> [Utterance]`, `AudioLevel.rms(UnsafePointer<Float>, count:) -> Float`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/PhraseLevelTests.swift
import AVFoundation
import Foundation
import Testing
@testable import Core

/// Writes a 16 kHz mono Int16 WAV where the first half is quiet and the second half is loud.
private func makeTwoHalvesFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phrase-level-\(UUID().uuidString).wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(16000)  // one second
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.int16ChannelData![0]
    for index in 0..<Int(frames) {
        // First half: -60 dBFS. Second half: around -6 dBFS. A square wave, so RMS equals amplitude.
        let amplitude: Int16 = index < 8000 ? 33 : 16384
        channel[index] = index % 2 == 0 ? amplitude : -amplitude
    }
    try file.write(from: buffer)
    return url
}

@Test func theLoudHalfMeasuresLoud() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.5, to: 1.0)
    #expect(level > -8 && level < -4)
}

@Test func theQuietHalfMeasuresQuiet() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.0, to: 0.5)
    #expect(level < -50)
}

// The loudest window, not the average: a span that is quiet almost everywhere but has one loud
// piece counts as loud.
@Test func oneLoudWindowMakesTheWholeSpanLoud() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let level = try PhraseLevel.peakDBFS(of: url, from: 0.0, to: 1.0)
    #expect(level > -8)
}

@Test func anEmptySpanIsSilence() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try PhraseLevel.peakDBFS(of: url, from: 0.5, to: 0.5) == -Float.infinity)
}

@Test func durationOfTheFixtureIsOneSecond() throws {
    let url = try makeTwoHalvesFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(abs(try AudioDuration.seconds(of: url) - 1.0) < 0.01)
}

@Test func gateKeepsLoudUtterancesAndDropsQuietOnes() throws {
    let loud = Utterance(speaker: .me, start: 0, end: 1, text: "своя речь")
    let quiet = Utterance(speaker: .me, start: 2, end: 3, text: "комната")
    let kept = try PhraseLevel.passing([loud, quiet], thresholdDBFS: -30) { utterance in
        utterance.start == 0 ? -6 : -45
    }
    #expect(kept.map(\.text) == ["своя речь"])
}

// A phrase is dropped whole, not word by word: "... yeah ... got it ..." can neither be read nor
// used to tune the threshold.
@Test func gateKeepsAnUtteranceWhole() throws {
    let utterance = Utterance(speaker: .me, start: 0, end: 5, text: "длинная своя реплика целиком")
    let kept = try PhraseLevel.passing([utterance], thresholdDBFS: -30) { _ in -10 }
    #expect(kept == [utterance])
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter PhraseLevelTests`
Expected: сборка не проходит — `cannot find 'PhraseLevel' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Audio/AudioDuration.swift
import AVFoundation
import Foundation

/// How long an audio file is, in seconds.
///
/// Its own type because three unrelated places need this and each was about to grow a private
/// copy: the transcriber reporting a file too short, the phrase-level measurement, and the
/// pipeline writing `duration` into the meeting's front matter.
public enum AudioDuration {
    public static func seconds(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
```

В `Core/Audio/AudioLevel.swift` добавить публичную перегрузку рядом с приватной для `Int16`:

```swift
    /// The same accumulation over float samples, which is what `AVAudioFile` hands back when it
    /// is read through its processing format. Public because `PhraseLevel` reads meeting tracks
    /// off disk; the `Int16` path above stays private to the real-time capture that owns it.
    public static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index])
            sum += value * value
        }
        return Float((sum / Double(count)).squareRoot())
    }
```

```swift
// Core/Audio/PhraseLevel.swift
import AVFoundation
import Foundation

/// How loud a stretch of a track actually was, and which utterances that lets through.
///
/// Exists because of one fact about the owner's setup: the microphone is an iPhone lying on the
/// desk, and it hears the room. The microphone track is supposed to mean "me"; keeping that
/// promise is recognition's job, not the microphone's, so the room is removed here rather than
/// suppressed at capture — capture would have cost the two tracks their shared clock.
public enum PhraseLevel {
    /// Windows this long are measured separately and the loudest one wins.
    public static let windowSeconds: TimeInterval = 0.1

    /// Loudest window inside the span, in dBFS. Silence returns `-infinity`, which compares
    /// below every threshold without needing a special case at the call site.
    public static func peakDBFS(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let firstFrame = max(0, AVAudioFramePosition(start * rate))
        let lastFrame = min(file.length, AVAudioFramePosition(end * rate))
        guard lastFrame > firstFrame else { return -.infinity }

        let windowFrames = AVAudioFrameCount(max(1, windowSeconds * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return -.infinity
        }

        var peak: Float = 0
        var frame = firstFrame
        while frame < lastFrame {
            file.framePosition = frame
            let remaining = lastFrame - frame
            let count = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData else { break }
            peak = max(peak, AudioLevel.rms(channel[0], count: Int(buffer.frameLength)))
            frame += AVAudioFramePosition(buffer.frameLength)
        }

        guard peak > 0 else { return -.infinity }
        return 20 * log10(peak)
    }

    /// Utterances loud enough to be the owner rather than the room.
    ///
    /// Takes the measurement as a closure instead of an array of levels: pairing two arrays by
    /// index is the kind of coupling that survives every test and breaks the first time someone
    /// filters one of them.
    public static func passing(
        _ utterances: [Utterance],
        thresholdDBFS: Float,
        level: (Utterance) throws -> Float
    ) rethrows -> [Utterance] {
        try utterances.filter { try level($0) >= thresholdDBFS }
    }
}
```

В `ParakeetTranscriber` заменить приватный `duration(of:)` на `AudioDuration.seconds(of:)` в обеих точках вызова и удалить приватный метод.

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Run: `swift test --filter PhraseLevelTests && swift test --filter ParakeetTranscriberTests`
Expected: PASS в обоих — второй проверяет, что удаление приватного дубликата ничего не сломало.

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/AudioDuration.swift Core/Audio/PhraseLevel.swift Core/Audio/AudioLevel.swift Core/Transcription/ParakeetTranscriber.swift Tests/CoreTests/PhraseLevelTests.swift
git commit -m "Замер громкости реплики и отсечка фона на дорожке микрофона"
```

---

### Task 6: Слияние двух дорожек на одну шкалу

`meeting.json` хранит `systemStartedAt` и `microphoneStartedAt` — момент первого буфера каждой дорожки на часах потока захвата. Часы общие (обе дорожки от одного `SCStream`), но отдавать буферы каждый выход начинает когда начинает: на первой живой встрече разница составила 0,87 секунды.

**Files:**
- Create: `Core/Transcript/MeetingTranscript.swift`
- Test: `Tests/CoreTests/MeetingTranscriptTests.swift`

**Interfaces:**
- Consumes: `Utterance`
- Produces: `MeetingTranscript.merge(mine:theirs:microphoneStartedAt:systemStartedAt:) -> [Utterance]`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/MeetingTranscriptTests.swift
import Foundation
import Testing
@testable import Core

private func mine(_ start: Double, _ text: String) -> Utterance {
    Utterance(speaker: .me, start: start, end: start + 1, text: text)
}

private func theirs(_ start: Double, _ text: String) -> Utterance {
    Utterance(speaker: .others, start: start, end: start + 1, text: text)
}

@Test func theLaterTrackIsShiftedForward() {
    let merged = MeetingTranscript.merge(
        mine: [mine(0, "я")],
        theirs: [theirs(0, "они")],
        microphoneStartedAt: 503221.034,
        systemStartedAt: 503220.169
    )
    // The system track started earlier, so its zero is the timeline's zero, and the microphone
    // shifts to 0.865.
    #expect(merged.map(\.text) == ["они", "я"])
    #expect(abs(merged[0].start - 0) < 0.001)
    #expect(abs(merged[1].start - 0.865) < 0.001)
}

@Test func repliesInterleaveByTime() {
    let merged = MeetingTranscript.merge(
        mine: [mine(1, "второй"), mine(5, "четвёртый")],
        theirs: [theirs(0, "первый"), theirs(3, "третий")],
        microphoneStartedAt: 100,
        systemStartedAt: 100
    )
    #expect(merged.map(\.text) == ["первый", "второй", "третий", "четвёртый"])
}

// A track that never delivered a single buffer is `nil`. There is nothing to shift, and no words
// come from it anyway.
@Test func aTrackThatNeverStartedDoesNotMoveTheZero() {
    let merged = MeetingTranscript.merge(
        mine: [],
        theirs: [theirs(0, "они"), theirs(2, "ещё они")],
        microphoneStartedAt: nil,
        systemStartedAt: 500
    )
    #expect(merged.map(\.start) == [0, 2])
}

@Test func bothTracksMissingLeavesTimesAsTheyAre() {
    let merged = MeetingTranscript.merge(
        mine: [mine(1, "я")],
        theirs: [],
        microphoneStartedAt: nil,
        systemStartedAt: nil
    )
    #expect(merged.map(\.start) == [1])
}

// Equal timestamps are resolved deterministically, or the same run would produce a different file
// each time.
@Test func aTieIsBrokenTowardsTheOtherSide() {
    let merged = MeetingTranscript.merge(
        mine: [mine(0, "я")],
        theirs: [theirs(0, "они")],
        microphoneStartedAt: 100,
        systemStartedAt: 100
    )
    #expect(merged.map(\.text) == ["они", "я"])
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingTranscriptTests`
Expected: сборка не проходит — `cannot find 'MeetingTranscript' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Transcript/MeetingTranscript.swift
import Foundation

/// Puts both tracks of a meeting on one timeline.
///
/// The two tracks come off a single `SCStream` and therefore share a clock, but each output
/// starts delivering when it starts delivering: on the first live meeting the microphone was
/// 0.87 seconds behind the system audio — nearly a whole word. That difference is recorded in
/// `meeting.json` precisely so it can be undone here rather than guessed at from content.
public enum MeetingTranscript {
    /// - Parameters:
    ///   - microphoneStartedAt: capture-clock second of the microphone track's first buffer,
    ///     `nil` when the track never delivered one.
    ///   - systemStartedAt: the same for the system audio track.
    public static func merge(
        mine: [Utterance],
        theirs: [Utterance],
        microphoneStartedAt: Double?,
        systemStartedAt: Double?
    ) -> [Utterance] {
        let zero = [microphoneStartedAt, systemStartedAt].compactMap { $0 }.min()
        let mineOffset = offset(of: microphoneStartedAt, from: zero)
        let theirsOffset = offset(of: systemStartedAt, from: zero)

        let shifted = shift(mine, by: mineOffset) + shift(theirs, by: theirsOffset)
        return shifted.sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            // A deterministic tie-break, so the same recording always renders the same file.
            // The other side goes first: they are the reason there is a meeting to transcribe.
            return left.speaker == .others && right.speaker == .me
        }
    }

    private static func offset(of startedAt: Double?, from zero: Double?) -> TimeInterval {
        guard let startedAt, let zero else { return 0 }
        return startedAt - zero
    }

    private static func shift(_ utterances: [Utterance], by offset: TimeInterval) -> [Utterance] {
        guard offset != 0 else { return utterances }
        return utterances.map {
            Utterance(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
    }
}
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter MeetingTranscriptTests`
Expected: PASS, пять тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Transcript/MeetingTranscript.swift Tests/CoreTests/MeetingTranscriptTests.swift
git commit -m "Две дорожки сводятся на одну шкалу по расхождению из meeting.json"
```

---

### Task 7: Рендер markdown

**Files:**
- Create: `Core/Transcript/MeetingMarkdown.swift`
- Test: `Tests/CoreTests/MeetingMarkdownTests.swift`

**Interfaces:**
- Consumes: `Utterance`
- Produces: `MeetingMarkdown.render(transcript:startedAt:durationSeconds:appName:) -> String`, `MeetingMarkdown.timestamp(_:) -> String`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/MeetingMarkdownTests.swift
import Foundation
import Testing
@testable import Core

private let started = Date(timeIntervalSince1970: 1_788_500_000)  // a fixed moment

@Test func timestampsAreHoursMinutesSeconds() {
    #expect(MeetingMarkdown.timestamp(0) == "00:00:00")
    #expect(MeetingMarkdown.timestamp(3) == "00:00:03")
    #expect(MeetingMarkdown.timestamp(192) == "00:03:12")
    #expect(MeetingMarkdown.timestamp(3725) == "01:02:05")
}

@Test func theFileCarriesFrontMatterAndATranscript() {
    let rendered = MeetingMarkdown.render(
        transcript: [
            Utterance(speaker: .others, start: 3, end: 6, text: "привет"),
            Utterance(speaker: .me, start: 11, end: 13, text: "привет и тебе"),
        ],
        startedAt: started,
        durationSeconds: 254,
        appName: "Телемост"
    )
    #expect(rendered.hasPrefix("---\n"))
    #expect(rendered.contains("duration: 4m\n"))
    #expect(rendered.contains("app: Телемост\n"))
    #expect(rendered.contains("## Транскрипт\n"))
    #expect(rendered.contains("[00:00:03] Собеседник: привет\n"))
    #expect(rendered.contains("[00:00:11] Я: привет и тебе\n"))
}

// Phase 2б does not know how many people are in the meeting or their names. The `participants`
// line will appear in 2г along with the names; writing it now would claim knowledge that does
// not exist yet.
@Test func participantsAreNotWritten() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: "Телемост"
    )
    #expect(!rendered.contains("participants"))
}

@Test func anUnknownApplicationLeavesTheLineOut() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: nil
    )
    #expect(!rendered.contains("app:"))
}

@Test func durationOverAnHourIsStillMinutes() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 4320, appName: nil
    )
    #expect(rendered.contains("duration: 72m\n"))
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingMarkdownTests`
Expected: сборка не проходит — `cannot find 'MeetingMarkdown' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Transcript/MeetingMarkdown.swift
import Foundation

/// The meeting file itself: front matter and a transcript, as `DESIGN.md` draws it.
///
/// Phase 2в will insert `## Саммари` and `## Решения` above the transcript, and 2г will replace
/// `Собеседник` with names and add `participants`. Neither needs this renderer to change, which
/// is why it writes only what phase 2б actually knows.
public enum MeetingMarkdown {
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    public static func render(
        transcript: [Utterance],
        startedAt: Date,
        durationSeconds: TimeInterval,
        appName: String?
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(format(startedAt, as: "yyyy-MM-dd"))")
        lines.append("started: \(format(startedAt, as: "HH:mm"))")
        lines.append("duration: \(Int((durationSeconds / 60).rounded()))m")
        if let appName { lines.append("app: \(appName)") }
        lines.append("---")
        lines.append("")
        lines.append("## Транскрипт")
        lines.append("")
        for utterance in transcript {
            lines.append("[\(timestamp(utterance.start))] \(label(utterance.speaker)): \(utterance.text)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func label(_ speaker: Utterance.Speaker) -> String {
        switch speaker {
        case .me: return "Я"
        case .others: return "Собеседник"
        }
    }

    /// Local time on purpose, matching `MeetingFolder.baseName`: the archive is read by a human
    /// who remembers when the meeting was.
    private static func format(_ date: Date, as template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter MeetingMarkdownTests`
Expected: PASS, пять тестов.

- [ ] **Step 5: Коммит**

```bash
git add Core/Transcript/MeetingMarkdown.swift Tests/CoreTests/MeetingMarkdownTests.swift
git commit -m "Рендер файла встречи: фронтматтер и транскрипт"
```

---

### Task 8: Сжатие дорожек в AAC

`AVAssetExportSession` не даёт задать битрейт, поэтому связка `AVAssetReader` плюс `AVAssetWriter`.

**Files:**
- Create: `Core/Audio/AudioCompressor.swift`
- Test: `Tests/CoreTests/AudioCompressorTests.swift`

**Interfaces:**
- Produces: `AudioCompressor.compress(_ source: URL, to destination: URL, bitrate: Int) async throws`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CoreTests/AudioCompressorTests.swift
import AVFoundation
import Foundation
import Testing
@testable import Core

private func makeToneFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("compress-\(UUID().uuidString).wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(16000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channel = buffer.int16ChannelData![0]
    for index in 0..<Int(frames) {
        let phase = Double(index) / 16000 * 440 * 2 * .pi
        channel[index] = Int16(sin(phase) * 8000)
    }
    try file.write(from: buffer)
    return url
}

@Test func compressionProducesAShorterFileOfTheSameLength() async throws {
    let source = try makeToneFile(seconds: 3)
    let destination = source.deletingPathExtension().appendingPathExtension("m4a")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: destination)
    }

    try await AudioCompressor.compress(source, to: destination, bitrate: 32000)

    #expect(FileManager.default.fileExists(atPath: destination.path))

    let sourceSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int
    let resultSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! Int
    #expect(resultSize < sourceSize / 2, "AAC at 32 kbit/s must be several times smaller than 16-bit WAV")

    let asset = AVURLAsset(url: destination)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 3) < 0.2)
}

@Test func aFileWithoutAudioIsAnamedFailure() async throws {
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
    try Data("это не аудио".utf8).write(to: empty)
    let destination = empty.deletingPathExtension().appendingPathExtension("m4a")
    defer {
        try? FileManager.default.removeItem(at: empty)
        try? FileManager.default.removeItem(at: destination)
    }

    await #expect(throws: (any Error).self) {
        try await AudioCompressor.compress(empty, to: destination, bitrate: 32000)
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter AudioCompressorTests`
Expected: сборка не проходит — `cannot find 'AudioCompressor' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Core/Audio/AudioCompressor.swift
import AVFoundation
import Foundation

/// WAV to AAC, for the week the audio survives after a meeting.
///
/// `AVAssetExportSession` would be shorter but has no way to set a bitrate — its presets pick
/// one — and the whole point here is 32 kbit/s: the disk is 256 GB, and fifteen hours of
/// meetings a week is 3.4 GB of raw WAV against roughly 400 MB compressed.
public enum AudioCompressor {
    public enum Failure: LocalizedError {
        case noAudioTrack(String)
        case encodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack(let name):
                return "No audio track in \(name)"
            case .encodingFailed(let reason):
                return "AAC encoding failed: \(reason)"
            }
        }
    }

    public static func compress(_ source: URL, to destination: URL, bitrate: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack(source.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MeetingAudioRecorder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitrate,
            ]
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw Failure.encodingFailed(reader.error?.localizedDescription ?? "reader refused to start")
        }
        guard writer.startWriting() else {
            throw Failure.encodingFailed(writer.error?.localizedDescription ?? "writer refused to start")
        }
        writer.startSession(atSourceTime: .zero)

        // `requestMediaDataWhenReady` is a callback API: it calls back on its own queue whenever
        // the encoder has room. The continuation is resumed exactly once, on the one path that
        // stops asking for more data — after `markAsFinished()` AVFoundation does not call the
        // block again.
        let pump = DispatchQueue(label: "nohands.compress")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: pump) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        if reader.status == .failed {
            throw Failure.encodingFailed(reader.error?.localizedDescription ?? "reading failed")
        }
        guard writer.status == .completed else {
            throw Failure.encodingFailed(writer.error?.localizedDescription ?? "writing did not complete")
        }
    }
}
```

Если Swift 6 откажется захватывать `input`, `output` и `reader` в замыкание на `DispatchQueue` из-за `Sendable`, объявите эти три локальные переменные `nonisolated(unsafe)` с комментарием: доступ к ним есть только у очереди `pump` и у кода до `startReading`, между которыми стоит барьер `startWriting`. Так же поступает `MeetingAudioRecorder` со своими буферами.

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter AudioCompressorTests`
Expected: PASS, два теста.

- [ ] **Step 5: Коммит**

```bash
git add Core/Audio/AudioCompressor.swift Tests/CoreTests/AudioCompressorTests.swift
git commit -m "Дорожки встречи жмутся в AAC 32 кбит/с"
```

---

### Task 9: Состояние папки, файл ошибки и `processed.json`

Состояние папки читается по её содержимому — ни базы, ни блокировок. `processed.json` нужен по делу: без него неоткуда узнать, что папка с `.m4a` отработана, а не брошена посередине.

**Files:**
- Create: `Features/Meetings/MeetingFolderState.swift`
- Create: `Features/Meetings/ProcessedRecord.swift`
- Modify: `Features/Meetings/MeetingFolder.swift` (добавить `archiveURL`)
- Test: `Tests/MeetingsTests/MeetingFolderStateTests.swift`

**Interfaces:**
- Produces: `MeetingFolderState` (`.recording`, `.waiting`, `.failed(String)`, `.processed(Date)`), `MeetingFolderState.of(_ folder: URL, fileManager:) -> MeetingFolderState`, `MeetingErrorFile.write(_:at:to:)` / `.read(in:)` / `.remove(in:)`, `ProcessedRecord(processedAt:elapsedSeconds:meetingDurationSeconds:transcriptPath:)` с `write(to:)` и `read(from:)`, `MeetingFolder.archiveURL`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/MeetingsTests/MeetingFolderStateTests.swift
import Foundation
import Testing
@testable import Meetings

private func makeFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("queue-\(UUID().uuidString)")
        .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aDottedFolderIsStillBeingRecorded() throws {
    let folder = try makeFolder(".draft-2026-09-04-1053-telemost")
    #expect(MeetingFolderState.of(folder) == .recording)
}

@Test func wavAndNothingElseMeansWaiting() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    try Data().write(to: folder.appendingPathComponent("system.wav"))
    #expect(MeetingFolderState.of(folder) == .waiting)
}

@Test func anErrorFileWins() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    try Data().write(to: folder.appendingPathComponent("system.wav"))
    try MeetingErrorFile.write("модель не поднялась", at: Date(), to: folder)
    #expect(MeetingFolderState.of(folder) == .failed("модель не поднялась"))
}

@Test func anErrorFileCanBeRemovedBeforeARetry() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    try MeetingErrorFile.write("сеть", at: Date(), to: folder)
    try MeetingErrorFile.remove(in: folder)
    #expect(MeetingErrorFile.read(in: folder) == nil)
    #expect(MeetingFolderState.of(folder) == .waiting)
}

@Test func processedIsRecognisedByItsRecord() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    let when = Date(timeIntervalSince1970: 1_788_500_000)
    let record = ProcessedRecord(
        processedAt: when, elapsedSeconds: 21, meetingDurationSeconds: 254,
        transcriptPath: "/Users/x/Meetings/2026-09-04-1053-telemost.md"
    )
    try record.write(to: folder.appendingPathComponent(ProcessedRecord.fileName))
    #expect(MeetingFolderState.of(folder) == .processed(when))
}

@Test func aProcessedRecordSurvivesAWriteAndARead() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    let url = folder.appendingPathComponent(ProcessedRecord.fileName)
    let record = ProcessedRecord(
        processedAt: Date(timeIntervalSince1970: 1_788_500_000), elapsedSeconds: 21,
        meetingDurationSeconds: 254, transcriptPath: "/tmp/a.md"
    )
    try record.write(to: url)
    #expect(try ProcessedRecord.read(from: url) == record)
}

// The archive is the folder above the queue — the same one Obsidian opens.
@Test func theArchiveIsTheFolderAboveTheQueue() {
    #expect(MeetingFolder.archiveURL == MeetingFolder.queueURL.deletingLastPathComponent())
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingFolderStateTests`
Expected: сборка не проходит — `cannot find 'MeetingFolderState' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Features/Meetings/MeetingFolderState.swift
import Foundation

/// What is going on in one folder of the queue, told by what is in it.
///
/// No database and no locks, for the same reason the hand-off from phase 2а is a rename: the
/// file system already knows all of this, and a second copy of the knowledge is a second thing
/// that can be wrong.
public enum MeetingFolderState: Equatable, Sendable {
    /// The name starts with a dot — phase 2а is still writing into it.
    case recording
    /// Ready and untouched.
    case waiting
    /// Processing went wrong, with the reason it went wrong. The audio stays and is spared by
    /// rotation: a recording that failed is worth more than the disk space it costs.
    case failed(String)
    /// Done, at the moment recorded in `processed.json`.
    case processed(Date)

    public static func of(_ folder: URL, fileManager: FileManager = .default) -> MeetingFolderState {
        if folder.lastPathComponent.hasPrefix(MeetingFolder.draftPrefix) { return .recording }
        if let reason = MeetingErrorFile.read(in: folder, fileManager: fileManager) {
            return .failed(reason)
        }
        let record = folder.appendingPathComponent(ProcessedRecord.fileName)
        if let processed = try? ProcessedRecord.read(from: record) {
            return .processed(processed.processedAt)
        }
        return .waiting
    }
}

/// The reason a folder could not be processed, written next to the audio it is about.
///
/// A file rather than a field in `meeting.json`: that file belongs to phase 2а and describes
/// the recording, while this describes an attempt to read it. Keeping them apart means a failed
/// attempt can be dropped by deleting one file, which is exactly what a retry does.
public enum MeetingErrorFile {
    public static let fileName = "error.txt"

    public static func write(_ reason: String, at date: Date, to folder: URL) throws {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: date))\n\(reason)\n"
        try Data(line.utf8).write(to: folder.appendingPathComponent(fileName))
    }

    /// The reason without the timestamp line, or `nil` when the folder carries no error.
    public static func read(in folder: URL, fileManager: FileManager = .default) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func remove(in folder: URL, fileManager: FileManager = .default) throws {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
```

```swift
// Features/Meetings/ProcessedRecord.swift
import Foundation

/// `processed.json` — the folder's own record that it has been through the pipeline.
///
/// Without it there is no way to tell a folder whose tracks were compressed from one abandoned
/// halfway. It also answers "where did the file go" a week later, when the audio is gone and
/// only the markdown is left.
public struct ProcessedRecord: Equatable, Sendable, Codable {
    public var processedAt: Date
    /// How long the pipeline took. Kept because it is the one number that says whether the
    /// two-hundred-times-real-time figure holds on real meetings.
    public var elapsedSeconds: Double
    public var meetingDurationSeconds: Double
    public var transcriptPath: String

    public init(
        processedAt: Date, elapsedSeconds: Double, meetingDurationSeconds: Double, transcriptPath: String
    ) {
        self.processedAt = processedAt
        self.elapsedSeconds = elapsedSeconds
        self.meetingDurationSeconds = meetingDurationSeconds
        self.transcriptPath = transcriptPath
    }

    public static let fileName = "processed.json"

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

    public static func read(from url: URL) throws -> ProcessedRecord {
        try decoder.decode(ProcessedRecord.self, from: Data(contentsOf: url))
    }
}
```

В `MeetingFolder` добавить рядом с `queueURL`:

```swift
    /// `~/Meetings` — where the markdown lands and what Obsidian opens. The queue is the hidden
    /// folder inside it, so this is simply one level up.
    public static var archiveURL: URL {
        queueURL.deletingLastPathComponent()
    }
```

- [ ] **Step 4: Прогнать тест и убедиться, что он проходит**

Run: `swift test --filter MeetingFolderStateTests`
Expected: PASS, семь тестов.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingFolderState.swift Features/Meetings/ProcessedRecord.swift Features/Meetings/MeetingFolder.swift Tests/MeetingsTests/MeetingFolderStateTests.swift
git commit -m "Состояние папки очереди читается по её содержимому"
```

---

### Task 10: `MeetingQueue` — обработка одной папки

Актор, разбирающий папки по одной. Модель своя, не та, что держит диктовка, — иначе диктовка, начатая посреди расшифровки часовой встречи, ждала бы сорок секунд. Отпускается, когда работать не над чем.

Порядок внутри папки выбран так, чтобы падение на позднем шаге не стоило текста: markdown пишется **до** сжатия.

**Files:**
- Create: `Features/Meetings/MeetingQueue.swift`
- Test: `Tests/MeetingsTests/MeetingQueueTests.swift`

**Interfaces:**
- Consumes: `TimedTranscriber`, `Utterance`, `PhraseLevel`, `MeetingTranscript`, `MeetingMarkdown`, `AudioDuration`, `AudioCompressor`, `MeetingMetadata`, `MeetingFolderState`, `ProcessedRecord`, `MeetingErrorFile`
- Produces: `MeetingQueue.Outcome(folder:minutes:failure:)`, `MeetingQueue(queue:archive:config:makeTranscriber:measureLevel:compress:report:)`, `func enqueue(_ folder: URL) async`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/MeetingsTests/MeetingQueueTests.swift
import AVFoundation
import Core
import Foundation
import Testing
@testable import Meetings

private struct StubTranscriber: TimedTranscriber {
    /// Words keyed by file name: "system.wav" and "mic.wav".
    let words: [String: [TimedWord]]
    /// Text, not `any Error`: a field of type `any Error` is not `Sendable`, and Swift 6 would
    /// refuse to accept this `TimedTranscriber` stub.
    var failureMessage: String?

    func transcribeTimed(audio url: URL) async throws -> [TimedWord] {
        if let failureMessage { throw TranscriptionError.modelUnavailable(failureMessage) }
        return words[url.lastPathComponent] ?? []
    }
}

private struct Fixture {
    let queue: URL
    let archive: URL
    let folder: URL
}

/// A meeting folder with real one-second WAV files: the pipeline reads duration from disk rather
/// than being told it, so there is nothing to fake.
private func makeMeetingFolder(name: String = "2026-09-04-1053-telemost") throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mq-\(UUID().uuidString)")
    let archive = root
    let queue = root.appendingPathComponent(".queue")
    let folder = queue.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for track in ["system.wav", "mic.wav"] {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent(track), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        try file.write(from: buffer)
    }

    let metadata = MeetingMetadata(
        startedAt: Date(timeIntervalSince1970: 1_788_500_000), stoppedAt: nil,
        app: MeetingMetadata.App(bundleID: "ru.yandex.desktop.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000, channelCount: 1, inputDevice: nil, stopReason: .manual,
        excludedApps: [], gaps: [], systemStartedAt: 100, microphoneStartedAt: 100
    )
    try metadata.write(to: folder.appendingPathComponent(MeetingMetadata.fileName))
    return Fixture(queue: queue, archive: archive, folder: folder)
}

private func word(_ text: String, _ start: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: start + 0.4, confidence: 1)
}

private func makeQueue(
    _ fixture: Fixture,
    transcriber: StubTranscriber,
    level: @escaping @Sendable (URL, TimeInterval, TimeInterval) throws -> Float = { _, _, _ in 0 },
    outcomes: @escaping @Sendable (MeetingQueue.Outcome) -> Void
) -> MeetingQueue {
    MeetingQueue(
        queue: fixture.queue,
        archive: fixture.archive,
        config: .default,
        makeTranscriber: { transcriber },
        measureLevel: level,
        compress: { _, destination, _ in try Data("aac".utf8).write(to: destination) },
        report: outcomes
    )
}

@Test func aGoodFolderProducesMarkdownAndCompressedTracks() async throws {
    let fixture = try makeMeetingFolder()
    let transcriber = StubTranscriber(words: [
        "system.wav": [word("привет", 3)],
        "mic.wav": [word("здравствуйте", 11)],
    ])
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let markdown = fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md")
    let text = try String(contentsOf: markdown, encoding: .utf8)
    #expect(text.contains("Собеседник: привет"))
    #expect(text.contains("Я: здравствуйте"))

    let fm = FileManager.default
    #expect(fm.fileExists(atPath: fixture.folder.appendingPathComponent("system.m4a").path))
    #expect(fm.fileExists(atPath: fixture.folder.appendingPathComponent("mic.m4a").path))
    #expect(!fm.fileExists(atPath: fixture.folder.appendingPathComponent("system.wav").path))
    #expect(MeetingFolderState.of(fixture.folder) != .waiting)
    #expect(box.all.first?.failure == nil)
}

@Test func quietMicrophoneUtterancesDoNotReachTheFile() async throws {
    let fixture = try makeMeetingFolder()
    let transcriber = StubTranscriber(words: [
        "system.wav": [word("вопрос", 1)],
        "mic.wav": [word("комната", 5)],
    ])
    let box = OutcomeBox()
    // The default threshold is -30; return -45 for every microphone query.
    let queue = makeQueue(fixture, transcriber: transcriber, level: { _, _, _ in -45 }) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains("вопрос"))
    #expect(!text.contains("комната"))
}

// Both tracks without a single word is a failure, not an empty file: something is wrong with the
// audio, and it needs to be kept so it can be listened to.
@Test func twoSilentTracksAreAFailureAndKeepTheAudio() async throws {
    let fixture = try makeMeetingFolder()
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: StubTranscriber(words: [:])) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md").path))
    #expect(fm.fileExists(atPath: fixture.folder.appendingPathComponent("system.wav").path))
    #expect(MeetingErrorFile.read(in: fixture.folder) != nil)
    #expect(box.all.first?.failure != nil)
}

@Test func aFailingRecogniserNamesTheReason() async throws {
    let fixture = try makeMeetingFolder()
    var transcriber = StubTranscriber(words: [:])
    transcriber.failureMessage = "нет модели"
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let reason = try #require(MeetingErrorFile.read(in: fixture.folder))
    #expect(reason.contains("нет модели"))
}

@Test func aRetryClearsThePreviousError() async throws {
    let fixture = try makeMeetingFolder()
    try MeetingErrorFile.write("прошлый раз не вышло", at: Date(), to: fixture.folder)
    let transcriber = StubTranscriber(words: ["system.wav": [word("да", 1)]])
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    #expect(MeetingErrorFile.read(in: fixture.folder) == nil)
}

/// Collects outcomes: `report` is called from an actor, and the check happens outside it.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeetingQueue.Outcome] = []
    func append(_ outcome: MeetingQueue.Outcome) {
        lock.lock(); defer { lock.unlock() }
        storage.append(outcome)
    }
    var all: [MeetingQueue.Outcome] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingQueueTests`
Expected: сборка не проходит — `cannot find 'MeetingQueue' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Features/Meetings/MeetingQueue.swift
import Core
import Foundation

/// Turns finished recordings into meeting files, one folder at a time.
///
/// Serial by construction, and that is a requirement rather than an optimisation: two meetings
/// back to back must not fight over the Neural Engine.
public actor MeetingQueue {
    public struct Outcome: Equatable, Sendable {
        public var folder: String
        public var minutes: Int?
        public var failure: String?

        public init(folder: String, minutes: Int?, failure: String?) {
            self.folder = folder
            self.minutes = minutes
            self.failure = failure
        }
    }

    enum Failure: LocalizedError {
        case noTracks(String)
        case nothingRecognised(String)

        var errorDescription: String? {
            switch self {
            case .noTracks(let name):
                return "В папке \(name) нет ни одной дорожки"
            case .nothingRecognised(let name):
                return "В обеих дорожках \(name) не распознано ни одного слова"
            }
        }
    }

    private let queue: URL
    private let archive: URL
    private let config: MeetingsConfig
    private let makeTranscriber: @Sendable () async throws -> any TimedTranscriber
    private let measureLevel: @Sendable (URL, TimeInterval, TimeInterval) throws -> Float
    private let compress: @Sendable (URL, URL, Int) async throws -> Void
    private let report: @Sendable (Outcome) -> Void

    /// Held only while there is work. Loading costs 0.3 s from cache and 470 MB resident, and
    /// the alternative — sharing the transcriber dictation keeps — would put a dictation behind
    /// a whole meeting in the actor's queue.
    private var transcriber: (any TimedTranscriber)?
    private var pending: [URL] = []
    private var draining = false

    public init(
        queue: URL = MeetingFolder.queueURL,
        archive: URL = MeetingFolder.archiveURL,
        config: MeetingsConfig,
        makeTranscriber: @escaping @Sendable () async throws -> any TimedTranscriber,
        measureLevel: @escaping @Sendable (URL, TimeInterval, TimeInterval) throws -> Float
            = { url, from, to in try PhraseLevel.peakDBFS(of: url, from: from, to: to) },
        compress: @escaping @Sendable (URL, URL, Int) async throws -> Void
            = { source, destination, bitrate in
                try await AudioCompressor.compress(source, to: destination, bitrate: bitrate)
            },
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.queue = queue
        self.archive = archive
        self.config = config
        self.makeTranscriber = makeTranscriber
        self.measureLevel = measureLevel
        self.compress = compress
        self.report = report
    }

    public func enqueue(_ folder: URL) async {
        pending.append(folder)
        await drain()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let folder = pending.removeFirst()
            report(await run(folder))
        }
        // Nothing left to do: the model goes, and the resting footprint is what it was before.
        transcriber = nil
        draining = false
    }

    private func run(_ folder: URL) async -> Outcome {
        let name = folder.lastPathComponent
        let started = Date()
        do {
            try MeetingErrorFile.remove(in: folder)
            let duration = try await process(folder, startedProcessingAt: started)
            return Outcome(folder: name, minutes: Int((duration / 60).rounded()), failure: nil)
        } catch {
            let reason = error.localizedDescription
            try? MeetingErrorFile.write(reason, at: Date(), to: folder)
            return Outcome(folder: name, minutes: nil, failure: reason)
        }
    }

    /// - Returns: the meeting's duration in seconds.
    private func process(_ folder: URL, startedProcessingAt: Date) async throws -> TimeInterval {
        let fileManager = FileManager.default
        let metadata = try MeetingMetadata.read(
            from: folder.appendingPathComponent(MeetingMetadata.fileName)
        )
        let system = folder.appendingPathComponent(MeetingAudioRecorder.systemFileName)
        let microphone = folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName)
        let tracks = [system, microphone].filter { fileManager.fileExists(atPath: $0.path) }
        guard !tracks.isEmpty else { throw Failure.noTracks(folder.lastPathComponent) }

        let transcriber = try await resolveTranscriber()

        var theirs: [Utterance] = []
        if fileManager.fileExists(atPath: system.path) {
            theirs = Utterance.split(
                words: try await transcriber.transcribeTimed(audio: system),
                speaker: .others,
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
        }

        var mine: [Utterance] = []
        if fileManager.fileExists(atPath: microphone.path) {
            let all = Utterance.split(
                words: try await transcriber.transcribeTimed(audio: microphone),
                speaker: .me,
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
            // The room the desk microphone hears is removed here rather than at capture — see
            // the decision of 2026-09-04. Whole utterances, never single words.
            mine = try PhraseLevel.passing(all, thresholdDBFS: Float(config.micThresholdDBFS)) {
                try measureLevel(microphone, $0.start, $0.end)
            }
        }

        let merged = MeetingTranscript.merge(
            mine: mine,
            theirs: theirs,
            microphoneStartedAt: metadata.microphoneStartedAt,
            systemStartedAt: metadata.systemStartedAt
        )
        guard !merged.isEmpty else { throw Failure.nothingRecognised(folder.lastPathComponent) }

        let duration = try tracks.map { try AudioDuration.seconds(of: $0) }.max() ?? 0

        // Markdown before compression, deliberately: if the encoder falls over, the text is
        // already in the archive and the raw audio is still on disk.
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let transcript = archive.appendingPathComponent(folder.lastPathComponent + ".md")
        let markdown = MeetingMarkdown.render(
            transcript: merged,
            startedAt: metadata.startedAt,
            durationSeconds: duration,
            appName: metadata.app?.name
        )
        try Data(markdown.utf8).write(to: transcript)

        for track in tracks {
            let compressed = track.deletingPathExtension().appendingPathExtension("m4a")
            try await compress(track, compressed, config.aacBitrate)
            try fileManager.removeItem(at: track)
        }

        let record = ProcessedRecord(
            processedAt: Date(),
            elapsedSeconds: Date().timeIntervalSince(startedProcessingAt),
            meetingDurationSeconds: duration,
            transcriptPath: transcript.path
        )
        try record.write(to: folder.appendingPathComponent(ProcessedRecord.fileName))
        return duration
    }

    private func resolveTranscriber() async throws -> any TimedTranscriber {
        if let transcriber { return transcriber }
        let made = try await makeTranscriber()
        transcriber = made
        return made
    }
}
```

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Run: `swift test --filter MeetingQueueTests`
Expected: PASS, пять тестов.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingQueue.swift Tests/MeetingsTests/MeetingQueueTests.swift
git commit -m "Очередь встреч: расшифровка папки, markdown, сжатие, отказы"
```

---

### Task 11: Скан при запуске и семидневная ротация

**Files:**
- Modify: `Features/Meetings/MeetingQueue.swift`
- Test: `Tests/MeetingsTests/MeetingQueueSweepTests.swift`

**Interfaces:**
- Produces: `MeetingQueue.scanAll() async`, `MeetingQueue.sweep(now:) async`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/MeetingsTests/MeetingQueueSweepTests.swift
import Core
import Foundation
import Testing
@testable import Meetings

private func makeQueueRoot() throws -> (queue: URL, archive: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
    let queue = root.appendingPathComponent(".queue")
    try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
    return (queue, root)
}

private func makeFolder(_ queue: URL, _ name: String, startedAt: Date) throws -> URL {
    let folder = queue.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let metadata = MeetingMetadata(
        startedAt: startedAt, stoppedAt: nil, app: nil, sampleRate: 16000, channelCount: 1,
        inputDevice: nil, stopReason: .manual, excludedApps: [], gaps: [],
        systemStartedAt: 0, microphoneStartedAt: 0
    )
    try metadata.write(to: folder.appendingPathComponent(MeetingMetadata.fileName))
    return folder
}

private func markProcessed(_ folder: URL, at date: Date) throws {
    let record = ProcessedRecord(
        processedAt: date, elapsedSeconds: 1, meetingDurationSeconds: 60, transcriptPath: "/tmp/a.md"
    )
    try record.write(to: folder.appendingPathComponent(ProcessedRecord.fileName))
}

private struct NeverCalledTranscriber: TimedTranscriber {
    func transcribeTimed(audio url: URL) async throws -> [TimedWord] { [] }
}

private func makeQueue(_ root: (queue: URL, archive: URL), seen: Seen) -> MeetingQueue {
    MeetingQueue(
        queue: root.queue, archive: root.archive, config: .default,
        makeTranscriber: { NeverCalledTranscriber() },
        measureLevel: { _, _, _ in 0 },
        compress: { _, destination, _ in try Data().write(to: destination) },
        report: { seen.append($0.folder) }
    )
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private let now = Date(timeIntervalSince1970: 1_788_500_000)

@Test func aProcessedFolderOlderThanTheWindowIsRemoved() async throws {
    let root = try makeQueueRoot()
    let old = try makeFolder(root.queue, "2026-08-20-1000-telemost", startedAt: now.addingTimeInterval(-8 * 86400))
    try markProcessed(old, at: now.addingTimeInterval(-8 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test func aFreshProcessedFolderStays() async throws {
    let root = try makeQueueRoot()
    let fresh = try makeFolder(root.queue, "2026-09-03-1000-telemost", startedAt: now.addingTimeInterval(-2 * 86400))
    try markProcessed(fresh, at: now.addingTimeInterval(-2 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

// Audio that failed to process is worth more than the disk space: rotation leaves such a folder
// alone no matter how old it gets.
@Test func aFailedFolderIsSparedRegardlessOfAge() async throws {
    let root = try makeQueueRoot()
    let broken = try makeFolder(root.queue, "2026-08-01-1000-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    try MeetingErrorFile.write("битый файл", at: now, to: broken)
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: broken.path))
}

// An unprocessed folder is never swept: rotation discards a copy of the audio, not the meeting.
@Test func anUnprocessedFolderIsNeverSwept() async throws {
    let root = try makeQueueRoot()
    let waiting = try makeFolder(root.queue, "2026-08-01-1100-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: waiting.path))
}

@Test func aDraftIsNeverSwept() async throws {
    let root = try makeQueueRoot()
    let draft = try makeFolder(root.queue, ".draft-2026-08-01-1200-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: draft.path))
}

@Test func scanPicksUpWaitingAndFailedFoldersButNotDraftsOrProcessed() async throws {
    let root = try makeQueueRoot()
    _ = try makeFolder(root.queue, "2026-09-04-1000-a", startedAt: now)
    let failed = try makeFolder(root.queue, "2026-09-04-1100-b", startedAt: now)
    try MeetingErrorFile.write("сеть", at: now, to: failed)
    let done = try makeFolder(root.queue, "2026-09-04-1200-c", startedAt: now)
    try markProcessed(done, at: now)
    _ = try makeFolder(root.queue, ".draft-2026-09-04-1300-d", startedAt: now)

    let seen = Seen()
    let queue = makeQueue(root, seen: seen)

    await queue.scanAll()

    #expect(seen.all.sorted() == ["2026-09-04-1000-a", "2026-09-04-1100-b"])
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingQueueSweepTests`
Expected: сборка не проходит — `value of type 'MeetingQueue' has no member 'sweep'`.

- [ ] **Step 3: Написать минимальную реализацию**

Добавить в `MeetingQueue`:

```swift
    /// Everything in the queue that has not been through the pipeline: leftovers from a
    /// previous run and folders a previous attempt failed on. Failures are retried at launch
    /// rather than on a timer — the typical one either fixes itself by the next launch (the
    /// model could not download) or never fixes itself (a broken file), and three quick
    /// attempts on a broken file are three wasted minutes.
    public func scanAll() async {
        for folder in folders() {
            switch MeetingFolderState.of(folder) {
            case .waiting, .failed:
                pending.append(folder)
            case .recording, .processed:
                continue
            }
        }
        await drain()
    }

    /// Drops the compressed audio of meetings older than the retention window.
    ///
    /// Only folders that have actually been processed. Rotation exists to throw away a copy of
    /// the audio, never a meeting: an untranscribed folder means the transcript does not exist
    /// yet, and deleting it would destroy the only record. Folders carrying `error.txt` are
    /// spared for the same reason, however old they are.
    public func sweep(now: Date = Date()) async {
        let window = TimeInterval(config.audioRetentionDays) * 86400
        for folder in folders() {
            guard case .processed = MeetingFolderState.of(folder) else { continue }
            let metadataURL = folder.appendingPathComponent(MeetingMetadata.fileName)
            guard let metadata = try? MeetingMetadata.read(from: metadataURL) else { continue }
            guard now.timeIntervalSince(metadata.startedAt) > window else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func folders() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: queue, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )
        return (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
```

- [ ] **Step 4: Прогнать тесты и убедиться, что они проходят**

Run: `swift test --filter MeetingQueueSweepTests && swift test --filter MeetingQueueTests`
Expected: PASS в обоих.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingQueue.swift Tests/MeetingsTests/MeetingQueueSweepTests.swift
git commit -m "Очередь разбирает остатки при запуске и сносит аудио через неделю"
```

---

### Task 12: Подключение к координатору и к приложению

Координатор переименовывает папку в двух местах — при обычной остановке и когда владелец решил сохранить осиротевший черновик. Оба места отдают папку очереди.

**Files:**
- Modify: `Features/Meetings/MeetingCoordinator.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Tests/MeetingsTests/MeetingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MeetingQueue.enqueue(_:)`, `MeetingQueue.scanAll()`, `MeetingQueue.sweep(now:)`
- Produces: параметр `onFolderReady: @escaping (URL) -> Void` в `MeetingCoordinator.init`

- [ ] **Step 1: Написать падающий тест**

В `Tests/MeetingsTests/MeetingCoordinatorTests.swift` завести в `Harness` ещё один сборщик рядом с `shown`, `hidden`, `blocked`:

```swift
    /// Folders handed to phase 2б. The rename is the only hand-off point, and it has two branches.
    private(set) var handedToQueue: [URL] = []
```

и в вызове `MeetingCoordinator(...)` внутри `Harness.init` дописать параметр рядом с остальными замыканиями:

```swift
            onFolderReady: { [weak self] in self?.handedToQueue.append($0) },
```

Затем добавить тест — последовательность та же, что в `theFolderIsHandedOverOnlyAfterTheCaptureFinishedClosingIt`:

```swift
// The rename is the only hand-off point into 2б. Without this call, a recording only reaches the
// archive on the next app launch, and nothing about a live meeting would show that — the file
// does show up, just a day later.
@Test @MainActor func stoppingARecordingHandsTheFolderToTheQueue() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.startPressed(at: noon)

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2820))
    await harness.coordinator.settle()

    #expect(harness.handedToQueue.count == 1)
    // The final name is handed over, not the draft: the queue must never see a folder still being written to.
    #expect(harness.handedToQueue[0].lastPathComponent.hasPrefix(".draft-") == false)
    #expect(harness.handedToQueue[0].lastPathComponent == harness.handedOver[0])
}

// An orphaned draft the owner chose to keep is the rename's second branch, and it is just as
// obligated to reach the queue.
@Test @MainActor func keepingAnOrphanedDraftAlsoHandsItToTheQueue() async throws {
    let harness = try Harness()
    // A draft left behind by a "crashed" app: a dotted folder with two tracks that no state
    // machine has claimed. Built the same way as the orphaned-draft tests above.
    let draft = harness.queue.appendingPathComponent(".draft-2026-09-04-1053-telemost")
    try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
    for name in [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName] {
        FileManager.default.createFile(
            atPath: draft.appendingPathComponent(name).path, contents: Data([0, 1, 2, 3])
        )
    }

    harness.coordinator.start()
    harness.coordinator.answer(.keep)
    await harness.coordinator.settle()

    #expect(harness.handedToQueue.count == 1)
    #expect(harness.handedToQueue[0].lastPathComponent.hasPrefix(".draft-") == false)
}
```

Второй тест повторяет подготовку осиротевшего черновика из уже существующих тестов этого файла; если там она устроена иначе — взять оттуда, а не переписывать.

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingCoordinatorTests`
Expected: сборка не проходит — у `MeetingCoordinator.init` нет `onFolderReady`.

- [ ] **Step 3: Написать минимальную реализацию**

В `MeetingCoordinator`:

```swift
    /// The hand-off to phase 2б. Called with the folder's final name, after the rename that
    /// makes it visible to the queue — never with the draft.
    private let onFolderReady: (URL) -> Void
```

Добавить в `init` параметр `onFolderReady: @escaping (URL) -> Void = { _ in }` и присваивание. Значение по умолчанию оставлено намеренно: у этого инициализатора десяток параметров и полтора десятка вызовов в тестах, а поведение по умолчанию — «никому не передавать» — ровно то, что было до этой задачи.

В обоих местах, где вызывается `MeetingFolder.promote`, забрать возвращённый URL и отдать его:

```swift
            do {
                let ready = try MeetingFolder.promote(folder)
                self?.onFolderReady(ready)
            } catch {
```

и, во второй ветке (сохранение осиротевшего черновика):

```swift
        do {
            let ready = try MeetingFolder.promote(draft)
            onFolderReady(ready)
        } catch {
```

В `App/AppDelegate.swift`, там же, где строится `MeetingCoordinator` (метод, возвращающий заметку для меню), поднять очередь и подключить её:

```swift
        let meetingsConfig = try MeetingsConfig.loadOrCreate()
        let dictationLanguage = (try? DictationConfig.loadOrCreate())?.language
        let queue = MeetingQueue(
            config: meetingsConfig,
            // The queue loads the model itself, with the same language as dictation: one machine
            // listens to the same speech, and a second key in the config would mean two settings
            // for one ear.
            makeTranscriber: { try await ParakeetTranscriber.load(language: dictationLanguage) },
            report: { [panel] outcome in
                Task { @MainActor in
                    panel.show(notice: MeetingNotice.forOutcome(outcome))
                    panel.hideNotice(after: MeetingNotice.dwell)
                }
            }
        )
        self.meetingQueue = queue
```

и в `onFolderReady` координатора:

```swift
            onFolderReady: { url in
                Task { await queue.enqueue(url) }
            },
```

Разбор остатков и ротация — при запуске, плюс раз в сутки:

```swift
        Task {
            await queue.scanAll()
            await queue.sweep()
        }
        // The machine is always on, so a once-a-day timer is all the scheduler this needs.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            Task { await queue.sweep() }
        }
```

Поля `meetingQueue` и `sweepTimer` объявить рядом с существующими полями делегата.

`MeetingNotice`, `panel.show(notice:)` и `panel.hideNotice(after:)` появляются в задаче 13 — до неё эти три строки не соберутся. Порядок выбран так намеренно: подключение проверяется тестом координатора, а панель — глазами, и смешивать эти две проверки в одной задаче незачем. Если хочется собирать после каждой задачи, поменяйте местами 12 и 13.

- [ ] **Step 4: Прогнать тесты и собрать**

Run: `swift test --filter MeetingCoordinatorTests`
Expected: PASS.

Run: `swift build`
Expected: ошибки только про `MeetingNotice`, `show(notice:)` и `hideNotice(after:)`, если задача 13 ещё не сделана. Любая другая ошибка — не по плану, разбираться.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingCoordinator.swift App/AppDelegate.swift Tests/MeetingsTests/MeetingCoordinatorTests.swift
git commit -m "Готовая папка уезжает в очередь, остатки и ротация — при запуске"
```

---

### Task 13: Слой уведомления на панели

Уведомление о расшифровке — третий слой, **над** основным, а не ещё одно состояние в нём. Расшифровка приходит через полминуты после конца встречи — ровно тогда, когда диктовку разблокировали и ею вполне могут воспользоваться; состояние в общем слое сбило бы её надпись.

**Files:**
- Create: `Features/Meetings/MeetingNotice.swift`
- Modify: `App/PanelModel.swift`, `App/PanelView.swift`, `App/PanelWindow.swift`
- Test: `Tests/MeetingsTests/MeetingNoticeTests.swift`

**Interfaces:**
- Consumes: `MeetingQueue.Outcome`
- Produces: `MeetingNotice(text:isFailure:)`, `MeetingNotice.forOutcome(_:) -> MeetingNotice`, `PanelWindow.show(notice:)`, `PanelWindow.hideNotice(after:)`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/MeetingsTests/MeetingNoticeTests.swift
import Foundation
import Testing
@testable import Meetings

@Test func aFinishedMeetingSaysHowLongItWas() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: 47, failure: nil)
    )
    #expect(notice.text == "Расшифровано, 47 мин")
    #expect(notice.isFailure == false)
}

@Test func aFailureNamesItsReason() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: nil, failure: "модель недоступна")
    )
    #expect(notice.text == "Не расшифровано: модель недоступна")
    #expect(notice.isFailure)
}

// A failure outranks the duration: if both arrive, we speak about the failure.
@Test func theDwellIsTheSameFiveSecondsAsEveryOtherNotice() {
    #expect(MeetingNotice.dwell == MeetingMachine.noticeDwell)
}

@Test func aFailureWinsOverMinutes() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "x", minutes: 3, failure: "не удалось сжать")
    )
    #expect(notice.isFailure)
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingNoticeTests`
Expected: сборка не проходит — `cannot find 'MeetingNotice' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

```swift
// Features/Meetings/MeetingNotice.swift
import Foundation

/// The one line the panel says when a recording has been through the pipeline.
///
/// The wording lives here rather than in the `App` target for the same reason every other
/// sentence in this feature does: it is the part that can be tested, and the panel's job is to
/// draw it.
public struct MeetingNotice: Equatable, Sendable {
    public var text: String
    /// Red text instead of secondary. The backing stays grey either way — only something
    /// waiting for an answer glows, and this asks nothing.
    public var isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }

    /// The same five seconds every other notice on this panel gets. Re-exported rather than
    /// duplicated: `MeetingMachine.noticeDwell` is internal to this module, and the `App` target
    /// needs a number to pass to `hideNotice(after:)`.
    public static let dwell: TimeInterval = MeetingMachine.noticeDwell

    public static func forOutcome(_ outcome: MeetingQueue.Outcome) -> MeetingNotice {
        if let failure = outcome.failure {
            return MeetingNotice(text: "Не расшифровано: \(failure)", isFailure: true)
        }
        return MeetingNotice(text: "Расшифровано, \(outcome.minutes ?? 0) мин", isFailure: false)
    }
}
```

В `App/PanelModel.swift` добавить третий слой:

```swift
    /// The transcription notice, kept apart from `state` and `meeting` rather than merged into
    /// either. A finished transcript lands seconds after a meeting ends — exactly when dictation
    /// has just been unblocked and may well be in use — so it must not take the row a dictation
    /// is drawing on.
    @Published var notice: MeetingNotice?
```

В `App/PanelView.swift` обернуть существующий `Group` в вертикальный стек:

```swift
    var body: some View {
        VStack(spacing: 6) {
            if let notice = model.notice {
                Text(notice.text)
                    .font(.system(size: 12))
                    .foregroundStyle(notice.isFailure ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Surface(recording: false))
            }
            Group {
                if model.state != nil {
                    active
                } else if let meeting = model.meeting {
                    MeetingContent(model: model, state: meeting)
                } else {
                    resting
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
```

В `App/PanelWindow.swift`: поднять высоту окна, чтобы строке было куда вырасти, и добавить собственный таймер выдержки.

```swift
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
```

```swift
    /// Its own dwell timer, a third one: a transcription notice lives by its own clock, and a
    /// shared timer would let the end of a dictation cut it off halfway.
    private var pendingNoticeHide: DispatchWorkItem?

    func show(notice: MeetingNotice) {
        pendingNoticeHide?.cancel()
        pendingNoticeHide = nil
        model.notice = notice
        position()
        panel.orderFrontRegardless()
    }

    func hideNotice(after delay: TimeInterval) {
        pendingNoticeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.notice = nil
            self?.panel.invalidateShadow()
        }
        pendingNoticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
```

`updateAcceptsClicks` не трогать: уведомление мышь не берёт никогда, и правило «панель глуха, пока подсказка не спрашивает» остаётся ровно тем же.

- [ ] **Step 4: Прогнать тесты, собрать и посмотреть глазами**

Run: `swift test --filter MeetingNoticeTests`
Expected: PASS, три теста.

Run: `swift build && ./Scripts/make-app.sh && open build/NoHands.app`
Затем `nohands meeting process` из задачи 14 ещё нет, поэтому проверка простая: положить готовую папку в `.queue` и перезапустить приложение — `scanAll` подхватит её и панель скажет исход. Убедиться, что строка появилась **над** полоской, не сдвинула её и погасла через пять секунд.

- [ ] **Step 5: Коммит**

```bash
git add Features/Meetings/MeetingNotice.swift App/PanelModel.swift App/PanelView.swift App/PanelWindow.swift Tests/MeetingsTests/MeetingNoticeTests.swift
git commit -m "Панель говорит исход расшифровки отдельной строкой над полоской"
```

---

### Task 14: Команды CLI

**Files:**
- Create: `CLI/MeetingArguments.swift`
- Create: `CLI/MeetingCommands.swift`
- Modify: `CLI/NoHands.swift` (usage и разбор команды)
- Modify: `Package.swift` (таргет `CLI` получает зависимость `Meetings`)
- Test: `Tests/CLITests/MeetingArgumentsTests.swift`

**Interfaces:**
- Consumes: `MeetingQueue`, `ParakeetTranscriber`, `PhraseLevel`, `Utterance`, `MeetingsConfig`
- Produces: `MeetingArguments.parse(_:) throws -> MeetingArguments` с полями `subcommand: Subcommand` и `folder: URL`

- [ ] **Step 1: Написать падающий тест**

```swift
// Tests/CLITests/MeetingArgumentsTests.swift
import Foundation
import Testing
@testable import CLI

@Test func processIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "process", "/tmp/2026-09-04-1053-telemost"])
    #expect(parsed.subcommand == .process)
    #expect(parsed.folder.lastPathComponent == "2026-09-04-1053-telemost")
}

@Test func levelsIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "levels", "/tmp/x"])
    #expect(parsed.subcommand == .levels)
}

@Test func anUnknownSubcommandIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "summarize", "/tmp/x"])
    }
}

@Test func aMissingFolderIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "process"])
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter MeetingArgumentsTests`
Expected: сборка не проходит — `cannot find 'MeetingArguments' in scope`.

- [ ] **Step 3: Написать минимальную реализацию**

В `Package.swift` у таргета `CLI` заменить зависимости на `["Core", "Dictation", "Meetings"]`.

```swift
// CLI/MeetingArguments.swift
import Foundation

/// Arguments of `nohands meeting …`, parsed apart from being executed so the parsing can be
/// tested — the same split `TranscribeArguments` uses.
struct MeetingArguments {
    enum Subcommand: String {
        case process
        case levels
    }

    enum ParseError: Error {
        case message(String)
    }

    var subcommand: Subcommand
    var folder: URL

    static func parse(_ arguments: [String]) throws -> MeetingArguments {
        guard arguments.count >= 3 else {
            throw ParseError.message("Использование: nohands meeting <process|levels> <папка встречи>")
        }
        guard let subcommand = Subcommand(rawValue: arguments[1]) else {
            throw ParseError.message("Неизвестная подкоманда: \(arguments[1]). Поддерживаются process и levels")
        }
        return MeetingArguments(
            subcommand: subcommand,
            folder: URL(fileURLWithPath: arguments[2]).standardizedFileURL
        )
    }
}
```

```swift
// CLI/MeetingCommands.swift
import Core
import Foundation
import Meetings

/// `nohands meeting process` — re-run a single folder.
func runMeetingProcess(_ folder: URL) async throws {
    let config = try MeetingsConfig.loadOrCreate()
    let language = (try? DictationConfig.loadOrCreate())?.language

    // A processed folder is re-run, not skipped: the command exists precisely for repeated runs
    // while tuning the threshold.
    try? MeetingErrorFile.remove(in: folder)
    let record = folder.appendingPathComponent(ProcessedRecord.fileName)
    try? FileManager.default.removeItem(at: record)

    let queue = MeetingQueue(
        queue: folder.deletingLastPathComponent(),
        archive: folder.deletingLastPathComponent().deletingLastPathComponent(),
        config: config,
        makeTranscriber: { try await ParakeetTranscriber.load(language: language) },
        report: { outcome in
            if let failure = outcome.failure {
                note("не вышло: \(failure)")
            } else {
                note("готово: \(outcome.minutes ?? 0) мин")
            }
        }
    )
    await queue.enqueue(folder)
}

/// `nohands meeting levels` — a tool for tuning `micThresholdDBFS`.
///
/// Prints the microphone track's utterances next to their level: both the number and the text
/// are visible, so it is clear whether it is the owner's own speech or the room. Printing on an
/// explicit command is not logging; none of this is written anywhere.
func runMeetingLevels(_ folder: URL) async throws {
    let config = try MeetingsConfig.loadOrCreate()
    let language = (try? DictationConfig.loadOrCreate())?.language
    let microphone = folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName)
    guard FileManager.default.fileExists(atPath: microphone.path) else {
        fail("В папке нет \(MeetingAudioRecorder.microphoneFileName) — возможно, дорожки уже сжаты")
    }

    let transcriber = try await ParakeetTranscriber.load(language: language)
    let words = try await transcriber.transcribeTimed(audio: microphone)
    let utterances = Utterance.split(
        words: words, speaker: .me,
        gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
    )

    note("порог сейчас: \(config.micThresholdDBFS) dBFS, реплик: \(utterances.count)")
    for utterance in utterances {
        let level = try PhraseLevel.peakDBFS(of: microphone, from: utterance.start, to: utterance.end)
        let mark = Float(config.micThresholdDBFS) <= level ? " " : "×"
        print(
            String(format: "%@ %6.1f dBFS  [%@]  %@",
                   mark,
                   level.isFinite ? level : -99,
                   MeetingMarkdown.timestamp(utterance.start),
                   utterance.text)
        )
    }
}
```

В `CLI/NoHands.swift` дописать в `usage`:

```
nohands meeting process <папка встречи>
    Прогоняет папку из ~/Meetings/.queue заново и перезаписывает markdown.

nohands meeting levels <папка встречи>
    Печатает реплики дорожки микрофона с их уровнем в dBFS. Крестик слева — реплика
    не проходит текущий порог micThresholdDBFS. Инструмент подбора порога.
```

и ветку в `switch`:

```swift
            case "meeting":
                let parsed: MeetingArguments
                do {
                    parsed = try MeetingArguments.parse(arguments)
                } catch MeetingArguments.ParseError.message(let message) {
                    fail(message)
                }
                switch parsed.subcommand {
                case .process:
                    try await runMeetingProcess(parsed.folder)
                case .levels:
                    try await runMeetingLevels(parsed.folder)
                }
```

- [ ] **Step 4: Прогнать тесты и команду**

Run: `swift test --filter MeetingArgumentsTests`
Expected: PASS, четыре теста.

Run: `swift build && .build/debug/nohands meeting levels ~/Meetings/.queue/2026-09-04-1053-telemost`
Expected: список реплик с уровнями. Если папка уже обработана и дорожки сжаты, команда честно скажет, что `mic.wav` нет.

- [ ] **Step 5: Коммит**

```bash
git add CLI/MeetingArguments.swift CLI/MeetingCommands.swift CLI/NoHands.swift Package.swift Tests/CLITests/MeetingArgumentsTests.swift
git commit -m "Команды CLI: повторный прогон встречи и замер уровней"
```

---

### Task 15: Живой прогон и настоящий порог

Последняя задача не про код. Всё, что можно было проверить тестами, проверено; здесь проверяется то, чего они не видят.

**Files:**
- Modify: `Features/Meetings/MeetingsConfig.swift` (значение `micThresholdDBFS`, если замер его сдвинет)
- Modify: `docs/DECISIONS.md`

- [ ] **Step 1: Прогнать конвейер на настоящей записи**

```bash
swift build
.build/debug/nohands meeting levels ~/Meetings/.queue/2026-09-04-1053-telemost
```

Прочитать вывод глазами. Найти границу: где кончается своя речь и начинается комната. Если крестики стоят не там, где надо, — вот значение порога.

- [ ] **Step 2: Поставить порог и перепрогнать**

Поправить `micThresholdDBFS` в `~/Library/Application Support/NoHands/config.json`, затем:

```bash
.build/debug/nohands meeting process ~/Meetings/.queue/2026-09-04-1053-telemost
cat ~/Meetings/2026-09-04-1053-telemost.md
```

Прочитать транскрипт целиком. Проверить: читается ли как разговор, попала ли фоновая речь, не разрезаны ли реплики посреди мысли (это про `phraseGapSeconds`), не съехали ли метки во времени (это про расхождение дорожек).

- [ ] **Step 3: Собрать приложение и провести настоящую встречу**

```bash
./Scripts/make-app.sh && open build/NoHands.app
```

Провести созвон. Проверить, что после остановки markdown появляется сам, панель говорит исход отдельной строкой над полоской, а через полминуты в папке лежат два `.m4a` и `processed.json`.

- [ ] **Step 4: Записать замеренное**

Если замер сдвинул порог — поменять дефолт в `MeetingsConfig.default` и заменить комментарий «провизорное значение» на то, чем оно стало и по какому материалу.

Дописать в `docs/DECISIONS.md` запись с датой прогона: какой порог получился и почему, сколько заняла обработка против длины встречи, каким оказалось расхождение дорожек на длинной записи, и всё, что пошло не так, — тем же тоном, что записи фазы 2а.

- [ ] **Step 5: Коммит и пуш**

```bash
git add Features/Meetings/MeetingsConfig.swift docs/DECISIONS.md
git commit -m "Порог отсечки фона поставлен по замеру, итоги живого прогона"
git push origin main
```
