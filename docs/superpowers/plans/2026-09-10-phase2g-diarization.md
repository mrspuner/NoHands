# Фаза 2г — диаризация, отпечатки голосов, имена

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** дорожка собеседников делится на голоса, голоса узнаются между встречами по отпечаткам, и однажды названный человек подписан именем во всех следующих файлах.

**Architecture:** офлайновый пайплайн FluidAudio даёт сегменты с эмбеддингами; кластеры склеиваются по косинусу центроидов после диаризации, тем же порогом голос ищется в базе `~/Meetings/.voices.json`; слова Parakeet получают голос по перекрытию, реплика режется на смене голоса; имя правится владельцем в строке `participants`, проход по архиву переносит правку в базу и переписывает метки.

**Tech Stack:** Swift 6, SwiftPM, FluidAudio 0.14.8 (`OfflineDiarizerManager`), Swift Testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-09-10-phase2g-diarization-design.md`

## Global Constraints

- Общение и документация по-русски; **идентификаторы, комментарии в коде и сообщения об ошибках — по-английски**. Строки, которые видит владелец (панель, CLI, содержимое файла встречи), — по-русски.
- Новых зависимостей SwiftPM не добавляем. FluidAudio закреплён `.exact("0.14.8")`.
- Не логировать содержимое транскриптов и распознанного текста. Печать по явной команде CLI логированием не считается.
- TDD: тест раньше кода, каждая задача кончается коммитом.
- Тесты не поднимают CoreML и живой звук: за `Diarizing` в тестах стоит подделка.
- Порог узнавания и склейки — один и тот же `voiceMatchThreshold`, значение по умолчанию `0.7`.
- `minVoicePrintSeconds` = 30, `maxVoicePrints` = 10, `diarizationEnabled` = true.
- Модуль `Core` не может импортировать `Meetings`: зависимость идёт в обратную сторону.
- Существующее поведение 2б сохраняется дословно там, где голосов нет: единственный безымянный голос подписан `Собеседник`, без номера.

---

### Task 1: Диаризатор за протоколом

**Files:**
- Create: `Core/Diarization/VoiceSegment.swift`
- Create: `Core/Diarization/Diarizing.swift`
- Create: `Core/Diarization/FluidDiarizer.swift`
- Test: `Tests/CoreTests/VoiceSegmentTests.swift`

**Interfaces:**
- Consumes: `FluidAudio.OfflineDiarizerManager`, `FluidAudio.TimedSpeakerSegment`
- Produces: `VoiceSegment(cluster:start:end:embedding:)`, `VoiceSegment.durationSeconds`, `VoiceSegment.from(_:)`, `protocol Diarizing { func segments(of audio: URL) async throws -> [VoiceSegment] }`, `DiarizationError.modelUnavailable(String)`, `FluidDiarizer.load()`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CoreTests/VoiceSegmentTests.swift
import FluidAudio
import Foundation
import Testing
@testable import Core

@Test func aSegmentKnowsHowLongItLasted() {
    let segment = VoiceSegment(cluster: "S1", start: 3, end: 7.5, embedding: [1, 0])
    #expect(segment.durationSeconds == 4.5)
}

// A segment whose end precedes its start is not a shorter segment, it is a broken one; letting
// the duration go negative would make it *subtract* speech from a voice's total further down.
@Test func aBackwardsSegmentLastsNothing() {
    let segment = VoiceSegment(cluster: "S1", start: 9, end: 4, embedding: [1, 0])
    #expect(segment.durationSeconds == 0)
}

@Test func librarySegmentsBecomeOurs() {
    let library = [
        TimedSpeakerSegment(
            speakerId: "S1", embedding: [0.5, 0.5], startTimeSeconds: 1, endTimeSeconds: 2,
            qualityScore: 1
        ),
        TimedSpeakerSegment(
            speakerId: "S2", embedding: [0, 1], startTimeSeconds: 4, endTimeSeconds: 9,
            qualityScore: 1
        ),
    ]
    let ours = VoiceSegment.from(library)
    #expect(ours.count == 2)
    #expect(ours[0] == VoiceSegment(cluster: "S1", start: 1, end: 2, embedding: [0.5, 0.5]))
    #expect(ours[1].cluster == "S2")
    #expect(ours[1].durationSeconds == 5)
}

// The pipeline weighs a voice by how long it spoke and averages its embedding over that time.
// A segment without an embedding cannot take part in either, and carrying it forward as a
// zero-length vector would poison the centroid with a vector of nothing.
@Test func aSegmentWithoutAnEmbeddingIsDropped() {
    let library = [
        TimedSpeakerSegment(
            speakerId: "S1", embedding: [], startTimeSeconds: 1, endTimeSeconds: 2, qualityScore: 1
        )
    ]
    #expect(VoiceSegment.from(library).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceSegmentTests`
Expected: FAIL — `cannot find 'VoiceSegment' in scope`

- [ ] **Step 3: Write the minimal implementation**

```swift
// Core/Diarization/VoiceSegment.swift
import FluidAudio
import Foundation

/// One stretch of one voice on the interlocutors' track, with the vector that identifies it.
///
/// `cluster` is what the diarizer decided *inside this file* and nothing more: the same person
/// regularly comes back as two or three clusters — measured on 2026-09-10, two clusters of one
/// speaker at cosine 0.923 — so nothing downstream may treat a cluster as a person. Turning
/// clusters into people is `VoiceClustering`'s job.
public struct VoiceSegment: Equatable, Sendable {
    public var cluster: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var embedding: [Float]

    public var durationSeconds: TimeInterval { max(0, end - start) }

    public init(cluster: String, start: TimeInterval, end: TimeInterval, embedding: [Float]) {
        self.cluster = cluster
        self.start = start
        self.end = end
        self.embedding = embedding
    }

    /// Segments without an embedding are dropped rather than carried: they can take part in
    /// neither the centroid nor the match, and an empty vector inside a weighted average is a
    /// vote for nothing.
    public static func from(_ segments: [TimedSpeakerSegment]) -> [VoiceSegment] {
        segments.compactMap { segment in
            guard !segment.embedding.isEmpty else { return nil }
            return VoiceSegment(
                cluster: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                embedding: segment.embedding
            )
        }
    }
}
```

```swift
// Core/Diarization/Diarizing.swift
import Foundation

/// What the pipeline needs from a diarizer, and the whole of it.
///
/// Behind it stands CoreML, which no test process can raise; in front of it stand the parts of
/// phase 2г that decide who is who, and those are pure. The boundary is here for that reason
/// and not for a second implementation — there is none planned.
public protocol Diarizing: Sendable {
    func segments(of audio: URL) async throws -> [VoiceSegment]
}

public enum DiarizationError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "Diarization model unavailable: \(reason)"
        }
    }
}
```

```swift
// Core/Diarization/FluidDiarizer.swift
import FluidAudio
import Foundation

/// FluidAudio's offline pipeline: pyannote segmentation, WeSpeaker embeddings, PLDA and VBx,
/// all CoreML on the Neural Engine.
///
/// Measured on 2026-09-10 over the real archive: 120–137× realtime, 825 MB peak on a 68-minute
/// meeting, models 21 MB. Compressed tracks are read as readily as raw ones — the library opens
/// the file through `AVAudioFile`, exactly as Parakeet does — and an AAC 32 kbit/s copy of a
/// voice matches its own raw WAV at cosine 0.970.
///
/// The clustering threshold is left at the library default on purpose. It is not monotonic:
/// on one meeting 0.6 gives four speakers, 0.65 gives seven, 0.8 gives six. Splitting is
/// undone afterwards, by `VoiceClustering`, with a threshold that can actually be tuned.
public actor FluidDiarizer: Diarizing {
    private let manager: OfflineDiarizerManager

    private init(manager: OfflineDiarizerManager) {
        self.manager = manager
    }

    /// Downloads the models on first call (21 MB) and compiles them.
    public static func load() async throws -> FluidDiarizer {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        do {
            try await manager.prepareModels()
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }
        return FluidDiarizer(manager: manager)
    }

    public func segments(of audio: URL) async throws -> [VoiceSegment] {
        do {
            let result = try await manager.process(audio)
            return VoiceSegment.from(result.segments)
        } catch {
            throw DiarizationError.modelUnavailable(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VoiceSegmentTests`
Expected: PASS, 4 теста

- [ ] **Step 5: Commit**

```bash
git add Core/Diarization Tests/CoreTests/VoiceSegmentTests.swift
git commit -m "Диаризатор FluidAudio за протоколом Diarizing"
```

---

### Task 2: Склейка кластеров в голоса

**Files:**
- Create: `Core/Diarization/VoicePrint.swift`
- Create: `Core/Diarization/MeetingVoice.swift`
- Create: `Core/Diarization/VoiceClustering.swift`
- Test: `Tests/CoreTests/VoiceClusteringTests.swift`

**Interfaces:**
- Consumes: `VoiceSegment` из задачи 1
- Produces: `VoicePrint(vector:)` (нормализует), `VoicePrint.cosine(_:_:) -> Float`, `VoicePrint.centroid(of: [VoiceSegment]) -> VoicePrint?`, `MeetingVoice(id:segments:print:speechSeconds:)`, `VoiceClustering.voices(from:threshold:) -> [MeetingVoice]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CoreTests/VoiceClusteringTests.swift
import Foundation
import Testing
@testable import Core

private func segment(_ cluster: String, _ start: Double, _ end: Double, _ vector: [Float]) -> VoiceSegment {
    VoiceSegment(cluster: cluster, start: start, end: end, embedding: vector)
}

@Test func aPrintIsUnitLength() {
    let print = VoicePrint(vector: [3, 4])
    #expect(abs(print.vector[0] - 0.6) < 0.0001)
    #expect(abs(print.vector[1] - 0.8) < 0.0001)
}

@Test func cosineIsOneForTheSameDirection() {
    #expect(abs(VoicePrint.cosine(VoicePrint(vector: [1, 1]), VoicePrint(vector: [5, 5])) - 1) < 0.0001)
    #expect(abs(VoicePrint.cosine(VoicePrint(vector: [1, 0]), VoicePrint(vector: [0, 1]))) < 0.0001)
}

// Vectors of different width never come from one model, so comparing them is a bug upstream,
// not a distant pair of voices. Zero says "no match" without pretending to have measured one.
@Test func cosineOfMismatchedWidthsIsZero() {
    #expect(VoicePrint.cosine(VoicePrint(vector: [1, 0]), VoicePrint(vector: [1, 0, 0])) == 0)
}

@Test func theCentroidIsWeightedBySpeech() {
    // Ten seconds pointing one way against one second pointing the other: the long one wins.
    let centroid = VoicePrint.centroid(of: [
        segment("S1", 0, 10, [1, 0]),
        segment("S1", 20, 21, [0, 1]),
    ])
    #expect(centroid != nil)
    #expect(centroid!.vector[0] > centroid!.vector[1])
}

@Test func farApartClustersStayTwoVoices() {
    let voices = VoiceClustering.voices(
        from: [segment("S1", 0, 30, [1, 0]), segment("S2", 30, 60, [0, 1])],
        threshold: 0.7
    )
    #expect(voices.count == 2)
    #expect(voices.map(\.id) == ["v1", "v2"])
    #expect(voices[0].speechSeconds == 30)
}

// The defect this whole task exists for: on 2026-09-10 one person came back as two clusters at
// cosine 0.923 and 0.930 inside single meetings.
@Test func aSplitSpeakerIsPutBackTogether() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S1", 0, 30, [1, 0]),
            segment("S2", 30, 50, [0.99, 0.14]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 1)
    #expect(voices[0].speechSeconds == 50)
    #expect(voices[0].segments.count == 2)
}

// Transitivity is what makes this a clustering and not a pairwise test: A pulls in B, B pulls in
// C, and C joins even though it is under the threshold away from A.
@Test func closenessCarriesThroughAChain() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S1", 0, 10, [1, 0]),
            segment("S2", 10, 20, [0.8, 0.6]),
            segment("S3", 20, 30, [0.35, 0.94]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 1)
}

// Identity is by order of first appearance, not by the diarizer's own numbering: the file the
// owner reads names people in the order they speak.
@Test func voicesAreNumberedByFirstAppearance() {
    let voices = VoiceClustering.voices(
        from: [
            segment("S7", 5, 15, [0, 1]),
            segment("S2", 0, 4, [1, 0]),
        ],
        threshold: 0.7
    )
    #expect(voices.count == 2)
    #expect(voices[0].id == "v1")
    #expect(voices[0].segments[0].cluster == "S2")
    #expect(voices[1].segments[0].cluster == "S7")
}

@Test func nothingInNothingOut() {
    #expect(VoiceClustering.voices(from: [], threshold: 0.7).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceClusteringTests`
Expected: FAIL — `cannot find 'VoicePrint' in scope`

- [ ] **Step 3: Write the minimal implementation**

```swift
// Core/Diarization/VoicePrint.swift
import Foundation

/// A voice reduced to one vector of unit length.
///
/// Normalised on the way in so that every comparison downstream is a plain dot product and no
/// caller has to remember whose vector was scaled. Measured on 2026-09-10: the same person
/// across meetings sits at 0.94–0.995, different people inside one meeting at 0.08–0.43.
public struct VoicePrint: Equatable, Sendable {
    public var vector: [Float]

    public init(vector: [Float]) {
        var length: Float = 0
        for value in vector { length += value * value }
        length = length.squareRoot()
        self.vector = length > 0 ? vector.map { $0 / length } : vector
    }

    /// Zero for vectors of different width: they cannot come from one model, so this is a defect
    /// upstream rather than a pair of distant voices, and zero refuses the match without
    /// claiming to have measured one.
    public static func cosine(_ left: VoicePrint, _ right: VoicePrint) -> Float {
        guard left.vector.count == right.vector.count, !left.vector.isEmpty else { return 0 }
        var dot: Float = 0
        for index in left.vector.indices { dot += left.vector[index] * right.vector[index] }
        return dot
    }

    /// Weighted by how long each segment lasted: a voice is what it said for a minute, not what
    /// it said in a one-second interjection.
    public static func centroid(of segments: [VoiceSegment]) -> VoicePrint? {
        guard let width = segments.first?.embedding.count, width > 0 else { return nil }
        var sum = [Float](repeating: 0, count: width)
        var weighted = false
        for segment in segments where segment.embedding.count == width {
            let weight = Float(segment.durationSeconds)
            guard weight > 0 else { continue }
            for index in 0..<width { sum[index] += segment.embedding[index] * weight }
            weighted = true
        }
        guard weighted else { return nil }
        return VoicePrint(vector: sum)
    }
}
```

```swift
// Core/Diarization/MeetingVoice.swift
import Foundation

/// One person as this meeting knows them: the segments they spoke, their fingerprint, and a
/// local identity `v1`, `v2` given by order of first appearance.
///
/// The identity means nothing outside this file. Between meetings a person is recognised by
/// their print in `VoiceBook`, never by this number.
public struct MeetingVoice: Equatable, Sendable {
    public var id: String
    public var segments: [VoiceSegment]
    public var print: VoicePrint
    public var speechSeconds: TimeInterval

    public init(id: String, segments: [VoiceSegment], print: VoicePrint, speechSeconds: TimeInterval) {
        self.id = id
        self.segments = segments
        self.print = print
        self.speechSeconds = speechSeconds
    }
}
```

```swift
// Core/Diarization/VoiceClustering.swift
import Foundation

/// Turns the diarizer's clusters into people.
///
/// The library's own clustering routinely splits one person in two — 0.923 and 0.930 between
/// clusters of a single speaker on the meetings of 2026-09-10 — and its internal threshold
/// cannot be tuned out of it, being non-monotonic. So the split is undone here, by the same
/// comparison that recognises a voice between meetings, with the same threshold. One number
/// answers one question: is this the same person?
public enum VoiceClustering {
    public static func voices(from segments: [VoiceSegment], threshold: Float) -> [MeetingVoice] {
        // Clusters in order of first appearance, so the numbering the owner reads follows the
        // order people spoke in.
        var order: [String] = []
        var grouped: [String: [VoiceSegment]] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if grouped[segment.cluster] == nil { order.append(segment.cluster) }
            grouped[segment.cluster, default: []].append(segment)
        }

        var prints: [String: VoicePrint] = [:]
        for cluster in order {
            guard let centroid = VoicePrint.centroid(of: grouped[cluster] ?? []) else { continue }
            prints[cluster] = centroid
        }
        let clusters = order.filter { prints[$0] != nil }

        // Connected components over "closer than the threshold". Transitive on purpose: a voice
        // split three ways has a middle piece close to both ends and ends that may not reach
        // each other.
        var parent = Dictionary(uniqueKeysWithValues: clusters.map { ($0, $0) })
        func find(_ cluster: String) -> String {
            var current = cluster
            while parent[current] != current { current = parent[current]! }
            return current
        }
        for (index, left) in clusters.enumerated() {
            for right in clusters[(index + 1)...] {
                guard VoicePrint.cosine(prints[left]!, prints[right]!) >= threshold else { continue }
                let (a, b) = (find(left), find(right))
                if a != b { parent[b] = a }
            }
        }

        var merged: [String: [String]] = [:]
        var mergedOrder: [String] = []
        for cluster in clusters {
            let root = find(cluster)
            if merged[root] == nil { mergedOrder.append(root) }
            merged[root, default: []].append(cluster)
        }

        var voices: [MeetingVoice] = []
        for (number, root) in mergedOrder.enumerated() {
            let all = (merged[root] ?? []).flatMap { grouped[$0] ?? [] }.sorted { $0.start < $1.start }
            guard let centroid = VoicePrint.centroid(of: all) else { continue }
            voices.append(
                MeetingVoice(
                    id: "v\(number + 1)",
                    segments: all,
                    print: centroid,
                    speechSeconds: all.reduce(0) { $0 + $1.durationSeconds }
                )
            )
        }
        return voices
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VoiceClusteringTests`
Expected: PASS, 9 тестов

- [ ] **Step 5: Commit**

```bash
git add Core/Diarization Tests/CoreTests/VoiceClusteringTests.swift
git commit -m "Склейка дроблёных кластеров в голоса встречи"
```

---

### Task 3: База отпечатков

**Files:**
- Create: `Core/Diarization/VoiceBook.swift`
- Create: `Core/Diarization/VoiceStore.swift`
- Test: `Tests/CoreTests/VoiceBookTests.swift`
- Test: `Tests/CoreTests/VoiceStoreTests.swift`

**Interfaces:**
- Consumes: `VoicePrint` из задачи 2
- Produces: `StoredPrint(meeting:seconds:vector:)`, `Voice(id:name:prints:createdAt:updatedAt:)`, `MeetingLabels(file:labels:)`, `MeetingLabels.Label(position:voiceId:renderedName:)`, `VoiceBook.empty`, `VoiceBook.match(_:threshold:) -> Voice?`, `VoiceBook.remember(_:meeting:seconds:as:maxPrints:now:) -> String`, `VoiceBook.rename(_:to:)`, `VoiceBook.name(of:) -> String?`, `VoiceBook.record(_:)`, `VoiceBook.labels(for:) -> MeetingLabels?`, `VoiceStore.defaultURL`, `VoiceStore.book()`, `VoiceStore.save(_:)`

- [ ] **Step 1: Write the failing test for the book**

```swift
// Tests/CoreTests/VoiceBookTests.swift
import Foundation
import Testing
@testable import Core

private let moment = Date(timeIntervalSince1970: 1_788_500_000)

@Test func anEmptyBookMatchesNothing() {
    #expect(VoiceBook.empty.match(VoicePrint(vector: [1, 0]), threshold: 0.7) == nil)
}

@Test func aRememberedVoiceIsFoundAgain() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "2026-09-09-0941-telemost",
        seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    let found = book.match(VoicePrint(vector: [0.99, 0.14]), threshold: 0.7)
    #expect(found?.id == id)
}

@Test func aDistantVoiceIsNotFound() {
    var book = VoiceBook.empty
    _ = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    #expect(book.match(VoicePrint(vector: [0, 1]), threshold: 0.7) == nil)
}

// The match is by the best of a voice's prints, not by their average. A person recorded on a
// close microphone once and through a bad connection another time is two directions, and the
// average of the two is a third direction that is neither.
@Test func theBestPrintWinsRatherThanTheirAverage() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    _ = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m2", seconds: 120, as: id, maxPrints: 10, now: moment
    )
    #expect(book.match(VoicePrint(vector: [0.02, 1]), threshold: 0.7)?.id == id)
}

@Test func aVoiceKeepsOnlyItsLatestPrints() {
    var book = VoiceBook.empty
    var id: String?
    for number in 1...12 {
        id = book.remember(
            VoicePrint(vector: [1, 0]), meeting: "m\(number)",
            seconds: 60, as: id, maxPrints: 10, now: moment
        )
    }
    let voice = book.voices.first { $0.id == id }
    #expect(voice?.prints.count == 10)
    #expect(voice?.prints.first?.meeting == "m3")
    #expect(voice?.prints.last?.meeting == "m12")
}

@Test func aNameIsRemembered() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(id, to: "Настя")
    #expect(book.name(of: id) == "Настя")
}

// The owner writing one name over two rows of the header is saying "these are one person" —
// the hand repair for a split the automatic merge missed.
@Test func oneNameOverTwoVoicesMergesThem() {
    var book = VoiceBook.empty
    let first = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let second = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(first, to: "Настя")
    book.rename(second, to: "Настя")
    #expect(book.voices.count == 1)
    let survivor = book.voices[0]
    #expect(survivor.name == "Настя")
    #expect(survivor.prints.count == 2)
    // Whichever row survived, both directions must still be findable under that name.
    #expect(book.match(VoicePrint(vector: [1, 0]), threshold: 0.7)?.name == "Настя")
    #expect(book.match(VoicePrint(vector: [0, 1]), threshold: 0.7)?.name == "Настя")
}

@Test func labelsOfAMeetingAreKeptByFileName() {
    var book = VoiceBook.empty
    book.record(
        MeetingLabels(
            file: "2026-09-09-0941-telemost.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: "abc", renderedName: "Собеседник 1")]
        )
    )
    #expect(book.labels(for: "2026-09-09-0941-telemost.md")?.labels.count == 1)
    #expect(book.labels(for: "другой.md") == nil)
}

// A meeting rewritten by `nohands meeting diarize` must not leave its old row behind: the two
// would then disagree about which voice a header position means.
@Test func recordingAMeetingTwiceKeepsOneRow() {
    var book = VoiceBook.empty
    book.record(MeetingLabels(file: "m.md", labels: []))
    book.record(
        MeetingLabels(
            file: "m.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: "abc", renderedName: "Настя")]
        )
    )
    #expect(book.meetings.count == 1)
    #expect(book.labels(for: "m.md")?.labels.first?.renderedName == "Настя")
}

@Test func theBookSurvivesAJsonRoundTrip() throws {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [0.6, 0.8]), meeting: "m", seconds: 61.5,
        as: nil, maxPrints: 10, now: moment
    )
    book.rename(id, to: "Настя")
    book.record(
        MeetingLabels(file: "m.md", labels: [MeetingLabels.Label(position: 1, voiceId: id, renderedName: "Настя")])
    )
    let data = try JSONEncoder().encode(book)
    let restored = try JSONDecoder().decode(VoiceBook.self, from: data)
    #expect(restored == book)
    #expect(restored.match(VoicePrint(vector: [0.6, 0.8]), threshold: 0.7)?.name == "Настя")
}

// Vectors are 256 floats each and there may be ten per voice; as a JSON array of numbers the
// file becomes unreadable to the eye it is meant to be readable to.
@Test func vectorsAreStoredAsBase64() throws {
    var book = VoiceBook.empty
    _ = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let json = String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
    #expect(!json.contains("[1,0]"))
    #expect(json.contains("\"vector\":\""))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceBookTests`
Expected: FAIL — `cannot find 'VoiceBook' in scope`

- [ ] **Step 3: Write the book**

```swift
// Core/Diarization/VoiceBook.swift
import Foundation

/// One fingerprint taken from one meeting.
public struct StoredPrint: Equatable, Sendable, Codable {
    public var meeting: String
    public var seconds: Double
    public var vector: [Float]

    public init(meeting: String, seconds: Double, vector: [Float]) {
        self.meeting = meeting
        self.seconds = seconds
        self.vector = vector
    }

    private enum CodingKeys: String, CodingKey {
        case meeting, seconds, vector
    }

    /// Base64 rather than an array of numbers: 256 floats times ten prints times a dozen voices
    /// is a file nobody can read, and this file lives beside the archive precisely so it can be
    /// opened and understood.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try container.decode(String.self, forKey: .meeting)
        seconds = try container.decode(Double.self, forKey: .seconds)
        let encoded = try container.decode(String.self, forKey: .vector)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .vector, in: container, debugDescription: "vector is not base64"
            )
        }
        vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting, forKey: .meeting)
        try container.encode(seconds, forKey: .seconds)
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try container.encode(data.base64EncodedString(), forKey: .vector)
    }
}

/// A person the archive has heard before.
public struct Voice: Equatable, Sendable, Codable {
    public var id: String
    public var name: String?
    public var prints: [StoredPrint]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String?, prints: [StoredPrint], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.prints = prints
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Which voice each header position of one meeting file stands for.
///
/// `renderedName` is what the application itself last wrote there. The header is compared
/// against it — that is the whole way an edit by the owner is told apart from what the
/// application put there on its own.
public struct MeetingLabels: Equatable, Sendable, Codable {
    public struct Label: Equatable, Sendable, Codable {
        public var position: Int
        /// `nil` for a voice too brief to store and unknown to the book: it is in the file and
        /// in the header, but there is no fingerprint for a name to attach to. The row exists
        /// anyway, because the header is matched to these rows position by position — a missing
        /// row would make an ordinary meeting look like an edited one.
        public var voiceId: String?
        public var renderedName: String

        public init(position: Int, voiceId: String?, renderedName: String) {
            self.position = position
            self.voiceId = voiceId
            self.renderedName = renderedName
        }
    }

    public var file: String
    public var labels: [Label]

    public init(file: String, labels: [Label]) {
        self.file = file
        self.labels = labels
    }
}

/// The whole of `~/Meetings/.voices.json`, as a value.
///
/// Pure on purpose: reading and writing the file is `VoiceStore`'s job, and everything that
/// decides who is who is testable without touching a disk.
public struct VoiceBook: Equatable, Sendable, Codable {
    public var version: Int
    public var voices: [Voice]
    public var meetings: [MeetingLabels]

    public static let empty = VoiceBook(version: 1, voices: [], meetings: [])

    public init(version: Int, voices: [Voice], meetings: [MeetingLabels]) {
        self.version = version
        self.voices = voices
        self.meetings = meetings
    }

    /// The nearest voice, if it is near enough — by the closest of its prints rather than by
    /// their average, so that one bad connection does not drag a whole identity sideways.
    public func match(_ print: VoicePrint, threshold: Float) -> Voice? {
        var best: (voice: Voice, score: Float)?
        for voice in voices {
            for stored in voice.prints {
                let score = VoicePrint.cosine(print, VoicePrint(vector: stored.vector))
                guard score >= threshold else { continue }
                if best == nil || score > best!.score { best = (voice, score) }
            }
        }
        return best?.voice
    }

    /// Adds a print to `voiceId`, or starts a new voice when it is `nil`.
    /// - Returns: the identity the print now belongs to.
    @discardableResult
    public mutating func remember(
        _ print: VoicePrint,
        meeting: String,
        seconds: Double,
        as voiceId: String?,
        maxPrints: Int,
        now: Date = Date()
    ) -> String {
        let stored = StoredPrint(meeting: meeting, seconds: seconds, vector: print.vector)
        if let voiceId, let index = voices.firstIndex(where: { $0.id == voiceId }) {
            voices[index].prints.append(stored)
            // Oldest first out: a voice should be described by how it sounds now.
            if voices[index].prints.count > maxPrints {
                voices[index].prints.removeFirst(voices[index].prints.count - maxPrints)
            }
            voices[index].updatedAt = now
            return voiceId
        }
        let fresh = Voice(
            id: UUID().uuidString, name: nil, prints: [stored], createdAt: now, updatedAt: now
        )
        voices.append(fresh)
        return fresh.id
    }

    /// Names a voice — and, when that name already belongs to another voice, merges the two.
    ///
    /// The merge is the point rather than a side effect: writing one name over two rows of the
    /// header is how the owner repairs a split the automatic clustering missed, and it is the
    /// only way the application ever learns that two fingerprints are one person.
    public mutating func rename(_ voiceId: String, to name: String) {
        guard let index = voices.firstIndex(where: { $0.id == voiceId }) else { return }
        if let twin = voices.firstIndex(where: { $0.name == name && $0.id != voiceId }) {
            let absorbed = voices.remove(at: index)
            let keep = twin > index ? twin - 1 : twin
            voices[keep].prints.append(contentsOf: absorbed.prints)
            voices[keep].updatedAt = max(voices[keep].updatedAt, absorbed.updatedAt)
            // Every row of every meeting that pointed at the absorbed voice has to follow it,
            // or the archive would hold labels pointing at an identity that no longer exists.
            for meeting in meetings.indices {
                for label in meetings[meeting].labels.indices
                where meetings[meeting].labels[label].voiceId == absorbed.id {
                    meetings[meeting].labels[label].voiceId = voices[keep].id
                }
            }
            return
        }
        voices[index].name = name
    }

    public func name(of voiceId: String) -> String? {
        voices.first { $0.id == voiceId }?.name
    }

    public mutating func record(_ labels: MeetingLabels) {
        meetings.removeAll { $0.file == labels.file }
        meetings.append(labels)
    }

    public func labels(for file: String) -> MeetingLabels? {
        meetings.first { $0.file == file }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VoiceBookTests`
Expected: PASS, 11 тестов

- [ ] **Step 5: Write the failing test for the store**

```swift
// Tests/CoreTests/VoiceStoreTests.swift
import Foundation
import Testing
@testable import Core

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("voices-\(UUID().uuidString)")
        .appendingPathComponent(".voices.json")
}

@Test func aMissingFileReadsAsAnEmptyBook() async throws {
    let store = VoiceStore(url: temporaryURL())
    #expect(try await store.book() == VoiceBook.empty)
}

@Test func whatIsSavedIsReadBack() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    try await store.save(book)
    #expect(try await store.book().name(of: id) == "Настя")
}

// The fingerprints cannot be rebuilt once the audio is gone — a week after the meeting there is
// nothing left to re-derive them from. So a file that does not parse is a refusal, never an
// empty book: an empty book would be written back over the only copy at the next save.
@Test func aBrokenFileIsRefusedRatherThanReplaced() async throws {
    let url = temporaryURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{ not json".utf8).write(to: url)
    let store = VoiceStore(url: url)
    await #expect(throws: (any Error).self) { try await store.book() }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "{ not json")
}

@Test func theStoreCreatesItsDirectory() async throws {
    let url = temporaryURL()
    let store = VoiceStore(url: url)
    try await store.save(VoiceBook.empty)
    #expect(FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `swift test --filter VoiceStoreTests`
Expected: FAIL — `cannot find 'VoiceStore' in scope`

- [ ] **Step 7: Write the store**

```swift
// Core/Diarization/VoiceStore.swift
import Foundation

/// `~/Meetings/.voices.json` — the only mutable state phase 2г keeps between meetings.
///
/// An actor because two things write here: the queue, when a meeting brings new fingerprints,
/// and the archive pass, when the owner renames somebody. Beside the archive rather than in
/// Application Support because the audio is gone in a week: a lost book cannot be rebuilt, and
/// everything worth keeping should sit in the one folder the owner already keeps.
public actor VoiceStore {
    private let url: URL

    public static var defaultURL: URL {
        // The path is spelled out here rather than taken from `MeetingFolder`, which lives in
        // `Meetings` — a module that depends on this one. `MeetingsConfig.configFileURL` repeats
        // the config path for the same reason.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
            .appendingPathComponent(".voices.json")
    }

    public init(url: URL = VoiceStore.defaultURL) {
        self.url = url
    }

    /// - Throws: when the file exists and does not parse. Deliberately not an empty book: the
    ///   next save would then write emptiness over fingerprints that nothing can recreate.
    public func book() throws -> VoiceBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceBook.self, from: try Data(contentsOf: url))
    }

    public func save(_ book: VoiceBook) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter VoiceStoreTests`
Expected: PASS, 4 теста

- [ ] **Step 9: Commit**

```bash
git add Core/Diarization Tests/CoreTests/VoiceBookTests.swift Tests/CoreTests/VoiceStoreTests.swift
git commit -m "База отпечатков голосов в ~/Meetings/.voices.json"
```

---

### Task 4: Слова получают голос, реплика режется на смене голоса

**Files:**
- Create: `Core/Transcript/VoiceAssignment.swift`
- Modify: `Core/Transcript/Utterance.swift` (enum `Speaker`, новая перегрузка `split`)
- Modify: `Core/Transcript/MeetingTranscript.swift:33-38` (тай-брейк по стороне)
- Modify: `Tests/CoreTests/UtteranceTests.swift`, `Tests/CoreTests/MeetingTranscriptTests.swift`, `Tests/CoreTests/MeetingMarkdownTests.swift` — замена `.others`
- Test: `Tests/CoreTests/VoiceAssignmentTests.swift`

**Interfaces:**
- Consumes: `MeetingVoice` (задача 2), `TimedWord`, `Utterance`
- Produces: `AssignedWord(word:voice:)`, `VoiceAssignment.assign(words:to:) -> [AssignedWord]`, `Utterance.Speaker.me`, `Utterance.Speaker.voice(String)`, `Utterance.split(assigned:gap:maxLength:) -> [Utterance]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CoreTests/VoiceAssignmentTests.swift
import Foundation
import Testing
@testable import Core

private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end, confidence: 1)
}

private func voice(_ id: String, _ spans: [(Double, Double)]) -> MeetingVoice {
    let segments = spans.map {
        VoiceSegment(cluster: id, start: $0.0, end: $0.1, embedding: [1, 0])
    }
    return MeetingVoice(
        id: id, segments: segments, print: VoicePrint(vector: [1, 0]),
        speechSeconds: segments.reduce(0) { $0 + $1.durationSeconds }
    )
}

@Test func aWordGoesToTheVoiceItOverlapsMost() {
    let assigned = VoiceAssignment.assign(
        words: [word("привет", 10, 11)],
        to: [voice("v1", [(0, 10.4)]), voice("v2", [(10.4, 20)])]
    )
    #expect(assigned.map(\.voice) == ["v2"])
}

// The diarizer drops stretches shorter than a second, so words fall into the gaps between its
// segments routinely. Such a word belongs to somebody who is already in the meeting; inventing
// an extra participant out of it, or dropping it, would both be worse than picking the nearest.
@Test func aWordInNobodysSegmentGoesToTheNearest() {
    let assigned = VoiceAssignment.assign(
        words: [word("ага", 12, 12.4)],
        to: [voice("v1", [(0, 10)]), voice("v2", [(13, 20)])]
    )
    #expect(assigned.map(\.voice) == ["v2"])
}

@Test func everyWordKeepsItsPlace() {
    let assigned = VoiceAssignment.assign(
        words: [word("раз", 0, 1), word("два", 14, 15), word("три", 16, 17)],
        to: [voice("v1", [(0, 5)]), voice("v2", [(13, 20)])]
    )
    #expect(assigned.map(\.word.text) == ["раз", "два", "три"])
    #expect(assigned.map(\.voice) == ["v1", "v2", "v2"])
}

// A track the diarizer found nothing in is still a track full of speech — the meeting simply
// stays as phase 2б wrote it, one unnamed interlocutor.
@Test func withoutVoicesEverythingIsOneVoice() {
    let assigned = VoiceAssignment.assign(words: [word("раз", 0, 1), word("два", 9, 10)], to: [])
    #expect(assigned.map(\.voice) == ["v1", "v1"])
}
```

```swift
// добавить в Tests/CoreTests/UtteranceTests.swift
@Test func aChangeOfVoiceStartsANewUtterance() {
    let assigned = [
        AssignedWord(word: TimedWord(text: "привет", start: 0, end: 1, confidence: 1), voice: "v1"),
        AssignedWord(word: TimedWord(text: "здравствуйте", start: 1.1, end: 2, confidence: 1), voice: "v2"),
    ]
    let utterances = Utterance.split(assigned: assigned, gap: 0.5, maxLength: 40)
    #expect(utterances.count == 2)
    #expect(utterances[0].speaker == .voice("v1"))
    #expect(utterances[1].speaker == .voice("v2"))
    #expect(utterances[1].text == "здравствуйте")
}

@Test func onePersonSpeakingOnKeepsOneUtterance() {
    let assigned = (0..<4).map { index in
        AssignedWord(
            word: TimedWord(
                text: "слово\(index)", start: Double(index), end: Double(index) + 0.3, confidence: 1
            ),
            voice: "v1"
        )
    }
    let utterances = Utterance.split(assigned: assigned, gap: 1.0, maxLength: 40)
    #expect(utterances.count == 1)
    #expect(utterances[0].text == "слово0 слово1 слово2 слово3")
}

@Test func theOldRulesStillApplyWithinOneVoice() {
    let assigned = [
        AssignedWord(word: TimedWord(text: "раз", start: 0, end: 1, confidence: 1), voice: "v1"),
        AssignedWord(word: TimedWord(text: "два", start: 5, end: 6, confidence: 1), voice: "v1"),
    ]
    let utterances = Utterance.split(assigned: assigned, gap: 0.5, maxLength: 40)
    #expect(utterances.count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceAssignmentTests`
Expected: FAIL — `cannot find 'VoiceAssignment' in scope`

- [ ] **Step 3: Change the speaker and add the assignment**

В `Core/Transcript/Utterance.swift` заменить объявление `Speaker` (сейчас `enum Speaker: String … case me, case others`) на:

```swift
    /// Who said it: the owner, or one of the voices this meeting found on the other track.
    ///
    /// The voice carries an identity, not a label. What it is called in the file — `Настя`,
    /// `Собеседник 2` — is decided at render time by `SpeakerLabels`, because the owner edits
    /// those names by hand and one name can even cover two voices.
    public enum Speaker: Equatable, Hashable, Sendable {
        case me
        case voice(String)
    }
```

и добавить туда же перегрузку `split`:

```swift
    /// The same two rules as above — a silence longer than `gap`, a ceiling of `maxLength` —
    /// plus a third: a change of voice ends the utterance. Without it two people would share a
    /// line whenever they spoke without a pause between them, and the archive would attribute
    /// one person's words to another. That is the failure phase 2б already paid for once, when
    /// leaked speech was merged into the owner's own replies.
    public static func split(
        assigned: [AssignedWord],
        gap: TimeInterval,
        maxLength: TimeInterval
    ) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [TimedWord] = []
        var currentVoice: String?

        func flush() {
            guard let first = current.first, let last = current.last, let voice = currentVoice else {
                current = []
                return
            }
            utterances.append(
                Utterance(
                    speaker: .voice(voice),
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " ")
                )
            )
            current = []
        }

        for item in assigned {
            if let last = current.last, let first = current.first {
                let broken = item.word.start - last.end > gap
                    || item.word.end - first.start > maxLength
                    || item.voice != currentVoice
                if broken { flush() }
            }
            currentVoice = item.voice
            current.append(item.word)
        }
        flush()
        return utterances
    }
```

```swift
// Core/Transcript/VoiceAssignment.swift
import Foundation

/// One recognised word together with the voice that said it.
public struct AssignedWord: Equatable, Sendable {
    public var word: TimedWord
    public var voice: String

    public init(word: TimedWord, voice: String) {
        self.word = word
        self.voice = voice
    }
}

/// Puts the recogniser's words and the diarizer's segments on the same timeline.
///
/// Both come from the same file, so their clocks are the same one and no shifting is needed —
/// unlike the two tracks of a meeting, which start at different instants and are reconciled in
/// `MeetingTranscript`.
public enum VoiceAssignment {
    /// - Parameter voices: the meeting's voices, already merged out of the diarizer's clusters.
    ///   Empty means the diarizer found nothing at all, and then every word belongs to a single
    ///   nameless voice — the file phase 2б used to write.
    public static func assign(words: [TimedWord], to voices: [MeetingVoice]) -> [AssignedWord] {
        guard !voices.isEmpty else {
            return words.map { AssignedWord(word: $0, voice: "v1") }
        }
        return words.map { word in
            AssignedWord(word: word, voice: voice(for: word, among: voices))
        }
    }

    private static func voice(for word: TimedWord, among voices: [MeetingVoice]) -> String {
        var bestOverlap: (voice: String, seconds: TimeInterval)?
        var nearest: (voice: String, distance: TimeInterval)?

        for voice in voices {
            for segment in voice.segments {
                let overlap = min(word.end, segment.end) - max(word.start, segment.start)
                if overlap > 0 {
                    if bestOverlap == nil || overlap > bestOverlap!.seconds {
                        bestOverlap = (voice.id, overlap)
                    }
                    continue
                }
                // Distance to the segment, zero-length overlap counting as touching.
                let distance = max(segment.start - word.end, word.start - segment.end)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (voice.id, distance)
                }
            }
        }
        // `voices` is non-empty and every voice carries at least one segment, so one of the two
        // is always set; the last fallback exists so the type does not have to be optional.
        return bestOverlap?.voice ?? nearest?.voice ?? voices[0].id
    }
}
```

В `Core/Transcript/MeetingTranscript.swift` заменить тай-брейк (сейчас `return left.speaker == .others && right.speaker == .me`) на:

```swift
            // The same deterministic tie-break as before, now that the other side is many
            // voices rather than one: whoever is not the owner goes first.
            if case .voice = left.speaker, right.speaker == .me { return true }
            return false
```

- [ ] **Step 4: Fix the existing tests**

В `Tests/CoreTests/UtteranceTests.swift`, `Tests/CoreTests/MeetingTranscriptTests.swift`, `Tests/CoreTests/MeetingMarkdownTests.swift` заменить каждое `.others` на `.voice("v1")`. Смысл тестов не меняется: до этой задачи «собеседник» был один.

Run: `grep -rn '\.others' Tests Core Features CLI App` — ожидается пусто.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS. `MeetingMarkdown.label` пока рисует «Собеседник» для любого `.voice` — метки появятся в задаче 5.

- [ ] **Step 6: Commit**

```bash
git add Core/Transcript Tests/CoreTests
git commit -m "Слово знает свой голос, смена голоса режет реплику"
```

---

### Task 5: Метки и `participants` в файле

**Files:**
- Create: `Core/Transcript/SpeakerLabels.swift`
- Modify: `Core/Transcript/MeetingMarkdown.swift` (сигнатура `render`, `label`, фронтматтер)
- Test: `Tests/CoreTests/SpeakerLabelsTests.swift`
- Test: `Tests/CoreTests/MeetingMarkdownTests.swift` (дополнить)

**Interfaces:**
- Consumes: `Utterance.Speaker` (задача 4)
- Produces: `SpeakerLabels(order:names:ownerSpoke:)`, `SpeakerLabels.make(transcript:names:) -> SpeakerLabels`, `SpeakerLabels.label(for:) -> String`, `SpeakerLabels.participants: [String]`, `SpeakerLabels.order: [String]`, `SpeakerLabels.ownerSpoke: Bool`, `MeetingMarkdown.render(transcript:startedAt:durationSeconds:appName:trailingMicrophoneSilenceSeconds:microphoneSawAudio:labels:diarizationFailure:)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CoreTests/SpeakerLabelsTests.swift
import Foundation
import Testing
@testable import Core

private func said(_ speaker: Utterance.Speaker, _ start: Double) -> Utterance {
    Utterance(speaker: speaker, start: start, end: start + 1, text: "…")
}

@Test func aLoneVoiceIsJustTheInterlocutor() {
    let labels = SpeakerLabels.make(transcript: [said(.voice("v1"), 0), said(.me, 2)], names: [:])
    #expect(labels.label(for: .voice("v1")) == "Собеседник")
    #expect(labels.label(for: .me) == "Я")
    #expect(labels.participants == ["Я", "Собеседник"])
}

@Test func severalVoicesAreNumberedByFirstAppearance() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v2"), 0), said(.me, 1), said(.voice("v1"), 2)], names: [:]
    )
    #expect(labels.label(for: .voice("v2")) == "Собеседник 1")
    #expect(labels.label(for: .voice("v1")) == "Собеседник 2")
    #expect(labels.participants == ["Я", "Собеседник 1", "Собеседник 2"])
}

@Test func aKnownNameReplacesTheNumber() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v1"), 0), said(.voice("v2"), 1)],
        names: ["v1": "Настя"]
    )
    #expect(labels.label(for: .voice("v1")) == "Настя")
    #expect(labels.label(for: .voice("v2")) == "Собеседник 2")
    #expect(labels.participants == ["Настя", "Собеседник 2"])
}

// Numbering counts every voice, named or not: two people in the file called «Собеседник 1» and
// «Собеседник 1» again would be indistinguishable, and the header would name one of them twice.
@Test func numberingCountsNamedVoicesToo() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v1"), 0), said(.voice("v2"), 1), said(.voice("v3"), 2)],
        names: ["v2": "Настя"]
    )
    #expect(labels.label(for: .voice("v1")) == "Собеседник 1")
    #expect(labels.label(for: .voice("v3")) == "Собеседник 3")
}

// A meeting the owner sat through in silence has no «Я» line, and claiming one in the header
// would be the same kind of invention the phase has been avoiding since 2б.
@Test func theOwnerIsListedOnlyIfHeSpoke() {
    let labels = SpeakerLabels.make(transcript: [said(.voice("v1"), 0)], names: [:])
    #expect(labels.participants == ["Собеседник"])
}
```

```swift
// добавить в Tests/CoreTests/MeetingMarkdownTests.swift
@Test func participantsAreWrittenWhenVoicesAreKnown() {
    let transcript = [
        Utterance(speaker: .voice("v1"), start: 3, end: 6, text: "привет"),
        Utterance(speaker: .me, start: 11, end: 13, text: "привет и тебе"),
        Utterance(speaker: .voice("v2"), start: 15, end: 18, text: "и вам"),
    ]
    let rendered = MeetingMarkdown.render(
        transcript: transcript,
        startedAt: started,
        durationSeconds: 254,
        appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: SpeakerLabels.make(transcript: transcript, names: ["v1": "Настя"]),
        diarizationFailure: nil
    )
    #expect(rendered.contains("participants: [Я, Настя, Собеседник 2]\n"))
    #expect(rendered.contains("[00:00:03] Настя: привет\n"))
    #expect(rendered.contains("[00:00:15] Собеседник 2: и вам\n"))
}

// A name with a comma or a bracket would break the list for anything that re-reads the file,
// and this value comes from whatever the owner typed.
@Test func awkwardNamesAreQuotedInTheList() {
    let transcript = [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")]
    let rendered = MeetingMarkdown.render(
        transcript: transcript,
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: SpeakerLabels.make(transcript: transcript, names: ["v1": "Настя, она же Настасья"]),
        diarizationFailure: nil
    )
    #expect(rendered.contains("participants: [\"Настя, она же Настасья\"]\n"))
}

// A refusal is named in the file that outlives everything, exactly as a refused cleanup is
// named on the panel: the silence about it would be the defect.
@Test func aRefusedDiarizationIsNamedAndClaimsNoParticipants() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")],
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: "модель диаризации недоступна"
    )
    #expect(!rendered.contains("participants:"))
    #expect(rendered.contains("speakers: \"не размечено — модель диаризации недоступна\"\n"))
    #expect(rendered.contains("[00:00:00] Собеседник: …\n"))
}

@Test func withoutLabelsAndWithoutFailureTheFileIsAsPhase2bWroteIt() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")],
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: nil, diarizationFailure: nil
    )
    #expect(!rendered.contains("participants:"))
    #expect(!rendered.contains("speakers:"))
    #expect(rendered.contains("[00:00:00] Собеседник: …\n"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeakerLabelsTests`
Expected: FAIL — `cannot find 'SpeakerLabels' in scope`

- [ ] **Step 3: Write the labels and extend the renderer**

```swift
// Core/Transcript/SpeakerLabels.swift
import Foundation

/// How the voices of one meeting are called in its file.
///
/// Derived from the transcript rather than stored with it: the order is the order people first
/// spoke, which is what a reader expects from the header, and a name is whatever the book knows
/// today. The same meeting rendered tomorrow, after the owner has named somebody, produces
/// different labels from the same utterances — that is the point.
public struct SpeakerLabels: Equatable, Sendable {
    /// Voice identities in order of first appearance.
    public var order: [String]
    /// Identity to name, for the voices that have one.
    public var names: [String: String]
    /// Whether the owner said anything at all. A meeting sat through in silence has no `Я` line,
    /// and the header must not claim one.
    public var ownerSpoke: Bool

    public init(order: [String], names: [String: String], ownerSpoke: Bool) {
        self.order = order
        self.names = names
        self.ownerSpoke = ownerSpoke
    }

    public static func make(transcript: [Utterance], names: [String: String]) -> SpeakerLabels {
        var order: [String] = []
        for utterance in transcript {
            guard case .voice(let id) = utterance.speaker, !order.contains(id) else { continue }
            order.append(id)
        }
        return SpeakerLabels(
            order: order,
            names: names,
            ownerSpoke: transcript.contains { $0.speaker == .me }
        )
    }

    public func label(for speaker: Utterance.Speaker) -> String {
        switch speaker {
        case .me:
            return "Я"
        case .voice(let id):
            if let name = names[id], !name.isEmpty { return name }
            guard let position = order.firstIndex(of: id) else { return "Собеседник" }
            // One nameless voice keeps the bare word phase 2б wrote — a meeting with one other
            // person has nothing to number.
            return order.count == 1 ? "Собеседник" : "Собеседник \(position + 1)"
        }
    }

    /// The header list. `Я` first when the owner spoke at all, then the voices in order.
    public var participants: [String] {
        (ownerSpoke ? ["Я"] : []) + order.map { label(for: .voice($0)) }
    }
}
```

В `Core/Transcript/MeetingMarkdown.swift`:

```swift
    public static func render(
        transcript: [Utterance],
        startedAt: Date,
        durationSeconds: TimeInterval,
        appName: String?,
        trailingMicrophoneSilenceSeconds: TimeInterval?,
        microphoneSawAudio: Bool?,
        labels: SpeakerLabels?,
        diarizationFailure: String?
    ) -> String {
```

внутри, после строки `app:` и до `microphone:`, добавить:

```swift
        // Written only when the voices are actually known. A list on a meeting where diarization
        // failed would claim knowledge the file does not have — the same rule that kept
        // `participants` out of phase 2б entirely.
        if let labels, !labels.order.isEmpty {
            let names = labels.participants.map(Frontmatter.listValue).joined(separator: ", ")
            lines.append("participants: [\(names)]")
        }
        if let diarizationFailure {
            lines.append("speakers: \(Frontmatter.quoted("не размечено — \(diarizationFailure)"))")
        }
```

а `label(_:)` заменить на:

```swift
    private static func label(_ speaker: Utterance.Speaker, _ labels: SpeakerLabels?) -> String {
        // Without labels the file looks exactly as phase 2б wrote it: the owner and one
        // unnamed interlocutor. That is what a failed diarization leaves behind, and it must
        // stay readable rather than become `v1`.
        labels?.label(for: speaker) ?? (speaker == .me ? "Я" : "Собеседник")
    }
```

и строку рендера реплики — на `lines.append("[\(timestamp(utterance.start))] \(label(utterance.speaker, labels)): \(utterance.text)")`.

В `Core/Transcript/Frontmatter.swift` добавить:

```swift
    /// A value inside a `[a, b]` list. Quoted only when it has to be: a plain name reads better
    /// unquoted, and a name with a comma, a bracket or a quote in it would otherwise break the
    /// list for everything that re-reads the file — including this application's own pass over
    /// the archive.
    public static func listValue(_ value: String) -> String {
        let plain = value.rangeOfCharacter(from: CharacterSet(charactersIn: ",[]\"\\:#")) == nil
            && !value.hasPrefix(" ") && !value.hasSuffix(" ") && !value.isEmpty
        return plain ? value : quoted(value)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter 'SpeakerLabelsTests|MeetingMarkdownTests|FrontmatterTests'`
Expected: PASS. Существующие вызовы `render` в тестах и в `MeetingQueue` придётся дополнить `labels: nil, diarizationFailure: nil` — компилятор укажет места.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Core/Transcript Tests/CoreTests
git commit -m "participants в шапке и имена в метках реплик"
```

---

### Task 6: Конфиг и встраивание в очередь

**Files:**
- Modify: `Features/Meetings/MeetingsConfig.swift` (четыре ключа: свойства, `default`, `init`, `init(from:)`)
- Create: `Features/Meetings/MeetingVoices.swift`
- Modify: `Features/Meetings/MeetingQueue.swift` (`init`, `update`, `process`, `drain`)
- Modify: `App/AppDelegate.swift:190` (создание очереди), `CLI/MeetingCommands.swift:36` (то же)
- Test: `Tests/MeetingsTests/MeetingsConfigTests.swift` (дополнить)
- Test: `Tests/MeetingsTests/MeetingVoicesTests.swift`
- Test: `Tests/MeetingsTests/MeetingQueueTests.swift` (дополнить)

**Interfaces:**
- Consumes: `VoiceClustering`, `VoiceBook`, `VoiceStore`, `VoiceAssignment`, `SpeakerLabels` из задач 2–5
- Produces: `MeetingsConfig.diarizationEnabled/voiceMatchThreshold/minVoicePrintSeconds/maxVoicePrints`, `MeetingVoices.resolve(voices:meeting:book:config:) -> MeetingVoices.Resolution` (поля `names`, `identities`), `MeetingQueue.init(…, makeDiarizer:voiceStore:…)`

- [ ] **Step 1: Write the failing config test**

```swift
// добавить в Tests/MeetingsTests/MeetingsConfigTests.swift
@Test func diarizationKeysHaveMeasuredDefaults() {
    let config = MeetingsConfig.default
    #expect(config.diarizationEnabled)
    #expect(config.voiceMatchThreshold == 0.7)
    #expect(config.minVoicePrintSeconds == 30)
    #expect(config.maxVoicePrints == 10)
}

@Test func aFileWithoutDiarizationKeysStillReads() throws {
    let json = Data(#"{"micThresholdDBFS": -35}"#.utf8)
    let config = try MeetingsConfig.decode(json)
    #expect(config.micThresholdDBFS == -35)
    #expect(config.voiceMatchThreshold == 0.7)
}
```

- [ ] **Step 2: Add the config keys**

В `MeetingsConfig` добавить свойства (с комментариями, объясняющими числа), значения в `default`, параметры в `init` с теми же умолчаниями и разбор в `init(from:)` по образцу соседних ключей:

```swift
    /// Whether speakers are separated at all. A switch, like `summaryEnabled`: if the step gets
    /// in the way, the archive must keep filling with transcripts.
    public var diarizationEnabled: Bool
    /// How close two fingerprints have to be to count as one person — both between meetings and
    /// between clusters of one meeting, because it is one question.
    ///
    /// Measured on 2026-09-10 over six real meetings: the same person across meetings 0.94–0.995,
    /// different people inside one meeting 0.08–0.43, one person split by the library into two
    /// clusters 0.76–0.93. The gap this sits in — 0.63 to 0.76 — is narrower than the 23 dB of
    /// `micThresholdDBFS`, and two pairs of that measurement fell inside it.
    public var voiceMatchThreshold: Double
    /// How much a voice has to say before its fingerprint is worth keeping. Clusters from 31
    /// seconds up matched at 0.96 in that same measurement; shorter scraps are noise that would
    /// later attract other people's voices to itself.
    public var minVoicePrintSeconds: Double
    /// Fingerprints kept per voice, newest last. They are compared by the best match rather than
    /// averaged: averaging blurs a voice the more often the person is met, which is backwards.
    public var maxVoicePrints: Int
```

в `default`: `diarizationEnabled: true, voiceMatchThreshold: 0.7, minVoicePrintSeconds: 30, maxVoicePrints: 10`.

- [ ] **Step 3: Run the config tests**

Run: `swift test --filter MeetingsConfigTests`
Expected: PASS

- [ ] **Step 4: Write the failing test for resolving voices against the book**

```swift
// Tests/MeetingsTests/MeetingVoicesTests.swift
import Core
import Foundation
import Testing
@testable import Meetings

private func meetingVoice(_ id: String, _ vector: [Float], seconds: Double) -> MeetingVoice {
    MeetingVoice(
        id: id,
        segments: [VoiceSegment(cluster: id, start: 0, end: seconds, embedding: vector)],
        print: VoicePrint(vector: vector),
        speechSeconds: seconds
    )
}

private let config = MeetingsConfig.default

@Test func anUnknownVoiceIsRemembered() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 120)],
        meeting: "2026-09-09-0941-telemost",
        book: &book,
        config: config
    )
    #expect(book.voices.count == 1)
    #expect(resolution.names.isEmpty)
    #expect(resolution.identities["v1"] == book.voices[0].id)
}

@Test func aKnownVoiceBringsItsName() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "прошлая", seconds: 120, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [0.99, 0.14], seconds: 120)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.names["v1"] == "Настя")
    #expect(resolution.identities["v1"] == id)
    // The new recording joined the same voice rather than starting a second one.
    #expect(book.voices.count == 1)
    #expect(book.voices[0].prints.count == 2)
}

@Test func aBriefVoiceLabelsTheMeetingButLeavesNoTrace() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 12)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(book.voices.isEmpty)
    #expect(resolution.identities.isEmpty)
    #expect(resolution.names.isEmpty)
}

// A brief voice that is nevertheless recognised keeps its name: the name is knowledge already
// paid for, and only the new fingerprint is refused.
@Test func aBriefButRecognisedVoiceKeepsItsName() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "прошлая", seconds: 300, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 12)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.names["v1"] == "Настя")
    #expect(book.voices[0].prints.count == 1)
}

@Test func severalVoicesAreNumberedInOrder() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [
            meetingVoice("v1", [1, 0], seconds: 120),
            meetingVoice("v2", [0, 1], seconds: 90),
        ],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.identities.count == 2)
    #expect(resolution.identities["v1"] != resolution.identities["v2"])
    #expect(book.voices.count == 2)
}
```

- [ ] **Step 5: Write the resolution**

```swift
// Features/Meetings/MeetingVoices.swift
import Core
import Foundation

/// Matches the voices of one meeting against the book: what they are called, and what the book
/// should remember about them afterwards.
///
/// Separated from `MeetingQueue` because it is the whole of the decision-making and none of the
/// input/output — the queue reads the book, calls this, writes the book back.
public enum MeetingVoices {
    public struct Resolution: Equatable, Sendable {
        /// Meeting-local identity to name, for the voices the book can name.
        public var names: [String: String]
        /// Meeting-local identity to the book's identity, for the voices the book keeps.
        ///
        /// Deliberately not a rendered label: what a voice is *called* is decided once, by
        /// `SpeakerLabels`, from the merged transcript. Working it out a second time here would
        /// be two rules for one string — and they would disagree exactly when a voice loses all
        /// its words to a neighbour, at which point the archive pass would read an ordinary
        /// file as a rename and attach a name to a voice that never said it.
        public var identities: [String: String]

        public init(names: [String: String], identities: [String: String]) {
            self.names = names
            self.identities = identities
        }
    }

    public static func resolve(
        voices: [MeetingVoice],
        meeting: String,
        book: inout VoiceBook,
        config: MeetingsConfig
    ) -> Resolution {
        let threshold = Float(config.voiceMatchThreshold)
        var names: [String: String] = [:]
        var identities: [String: String] = [:]

        for voice in voices {
            let matched = book.match(voice.print, threshold: threshold)
            var identity = matched?.id

            if voice.speechSeconds >= config.minVoicePrintSeconds {
                identity = book.remember(
                    voice.print,
                    meeting: meeting,
                    seconds: voice.speechSeconds,
                    as: identity,
                    maxPrints: config.maxVoicePrints
                )
            }

            if let name = identity.flatMap({ book.name(of: $0) }) { names[voice.id] = name }
            // A voice too brief to store and unknown to the book leaves no identity here. It is
            // still labelled in the file — it spoke, after all — and it still gets a row in the
            // book's meeting record, built by the caller, with no voice behind it.
            if let identity { identities[voice.id] = identity }
        }
        return Resolution(names: names, identities: identities)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter MeetingVoicesTests`
Expected: PASS, 5 тестов

- [ ] **Step 7: Write the failing queue test**

Расширить существующий хелпер `makeQueue` в `Tests/MeetingsTests/MeetingQueueTests.swift` двумя
параметрами — `diarizer: FakeDiarizer = FakeDiarizer()` и `store: VoiceStore? = nil`, — передав их
в `MeetingQueue.init` как `makeDiarizer: { diarizer }` и `voiceStore: store ?? VoiceStore(url: fixture.archive.appendingPathComponent(".voices.json"))`.
Хранилище обязано указывать внутрь временной папки: иначе тест писал бы в настоящую базу владельца.

```swift
// Tests/MeetingsTests/MeetingQueueTests.swift — рядом с StubTranscriber

/// The real diarizer is CoreML and cannot be raised in a test process.
private struct FakeDiarizer: Diarizing {
    var found: [VoiceSegment] = []
    /// Text rather than `any Error`, for the same reason `StubTranscriber` carries a message:
    /// a stored `any Error` is not `Sendable` and Swift 6 refuses the stub.
    var failureMessage: String?

    func segments(of audio: URL) async throws -> [VoiceSegment] {
        if let failureMessage { throw DiarizationError.modelUnavailable(failureMessage) }
        return found
    }
}

@Test func twoVoicesEndUpInTheHeaderAndInTheLabels() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: [
        "system.wav": [word("привет", 0), word("здравствуйте", 50)],
        "mic.wav": [],
    ])
    // Both well past `minVoicePrintSeconds`, so both are worth remembering.
    let diarizer = FakeDiarizer(found: [
        VoiceSegment(cluster: "S1", start: 0, end: 40, embedding: [1, 0]),
        VoiceSegment(cluster: "S2", start: 45, end: 90, embedding: [0, 1]),
    ])
    let store = VoiceStore(url: fixture.archive.appendingPathComponent(".voices.json"))
    let box = OutcomeBox()
    let queue = makeQueue(
        fixture, transcriber: transcriber, diarizer: diarizer, store: store
    ) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains("participants: [Собеседник 1, Собеседник 2]\n"))
    #expect(text.contains("] Собеседник 1: привет"))
    #expect(text.contains("] Собеседник 2: здравствуйте"))
    #expect(box.all.first?.failure == nil)

    let book = try await store.book()
    #expect(book.voices.count == 2)
    #expect(book.labels(for: "2026-09-04-1053-telemost.md")?.labels.count == 2)
}

// The whole reason the failure is caught inside the step: a thrown error here would mark the
// folder failed, and the retry would find the tracks compressed and refuse for ever. A missing
// 21 MB model must not cost a meeting.
@Test func aFailedDiarizationStillProducesAMeeting() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: [
        "system.wav": [word("привет", 3)],
        "mic.wav": [word("здравствуйте", 11)],
    ])
    let box = OutcomeBox()
    let queue = makeQueue(
        fixture,
        transcriber: transcriber,
        diarizer: FakeDiarizer(failureMessage: "no model")
    ) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains("speakers: \"не размечено — "))
    #expect(!text.contains("participants:"))
    #expect(text.contains("] Собеседник: привет"))
    #expect(text.contains("] Я: здравствуйте"))
    #expect(box.all.first?.failure == nil)
    #expect(MeetingFolderState.of(fixture.folder) == .processed)
}

@Test func aRecognisedVoiceIsNamedOnTheNextMeeting() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    // Copied before the first run: processing compresses the tracks and deletes the raw ones.
    let second = fixture.queue.appendingPathComponent("2026-09-05-1000-telemost")
    try FileManager.default.copyItem(at: fixture.folder, to: second)

    let transcriber = StubTranscriber(words: [
        "system.wav": [word("привет", 0)],
        "mic.wav": [],
    ])
    let diarizer = FakeDiarizer(found: [
        VoiceSegment(cluster: "S1", start: 0, end: 60, embedding: [1, 0])
    ])
    let store = VoiceStore(url: fixture.archive.appendingPathComponent(".voices.json"))
    let box = OutcomeBox()
    let queue = makeQueue(
        fixture, transcriber: transcriber, diarizer: diarizer, store: store
    ) { box.append($0) }

    await queue.enqueue(fixture.folder)

    // The owner names the voice between the two meetings, exactly as the archive pass would.
    var book = try await store.book()
    #expect(book.voices.count == 1)
    book.rename(book.voices[0].id, to: "Настя")
    try await store.save(book)

    await queue.enqueue(second)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-05-1000-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains("participants: [Настя]\n"))
    #expect(text.contains("] Настя: привет"))
    // One person, not two: the second meeting joined the voice it recognised.
    #expect(try await store.book().voices.count == 1)
}
```

- [ ] **Step 8: Wire the diarizer into the queue**

В `MeetingQueue`:

```swift
    private var makeDiarizer: @Sendable () async throws -> any Diarizing
    private let voiceStore: VoiceStore
    /// Held while there is work, like the transcriber: 21 MB of models and 0.3 s from cache.
    private var diarizer: (any Diarizing)?
```

добавить их в `init` (параметры `makeDiarizer:` и `voiceStore: VoiceStore = VoiceStore()`), в `update(config:makeTranscriber:makeDiarizer:)`, и отпускать вместе с транскрайбером в конце `drain`: `diarizer = nil`.

В `process`, вместо нынешнего блока `if tracks.contains(system) { theirs = Utterance.split(…) }`:

```swift
        var theirs: [Utterance] = []
        var labels: SpeakerLabels?
        var diarizationFailure: String?
        var resolvedNames: [String: String] = [:]
        var identities: [String: String] = [:]
        // Held until the markdown is safely written: the book is saved once, at the end, so a
        // failure between the two never leaves fingerprints recorded for a meeting that has no
        // file.
        var updatedBook: VoiceBook?

        if tracks.contains(system) {
            let words = try await transcriber.transcribeTimed(audio: system)
            var voices: [MeetingVoice] = []
            if config.diarizationEnabled {
                do {
                    let diarizer = try await resolveDiarizer()
                    voices = VoiceClustering.voices(
                        from: try await diarizer.segments(of: system),
                        threshold: Float(config.voiceMatchThreshold)
                    )
                    var book = try await voiceStore.book()
                    let resolution = MeetingVoices.resolve(
                        voices: voices,
                        meeting: folder.lastPathComponent,
                        book: &book,
                        config: config
                    )
                    resolvedNames = resolution.names
                    identities = resolution.identities
                    updatedBook = book
                } catch {
                    // Never fatal to the meeting. A thrown error here would mark the folder
                    // failed, and its retry would find the tracks compressed and refuse for
                    // ever — the meeting would be lost over a missing 21 MB model. A book that
                    // does not parse arrives here too, and is likewise named rather than
                    // overwritten.
                    diarizationFailure = error.localizedDescription
                    voices = []
                    updatedBook = nil
                }
            }
            theirs = Utterance.split(
                assigned: VoiceAssignment.assign(words: words, to: voices),
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
        }
```

после `let merged = MeetingTranscript.merge(…)` и проверки на пустоту:

```swift
        // Built from the merged transcript rather than from `voices`, because the order in the
        // header must be the order the reader meets people in the file — and that is decided by
        // the merge, which interleaves both tracks.
        if diarizationFailure == nil, config.diarizationEnabled, !merged.isEmpty,
            merged.contains(where: { if case .voice = $0.speaker { return true } else { return false } }) {
            labels = SpeakerLabels.make(transcript: merged, names: resolvedNames)
        }
```

в вызов `MeetingMarkdown.render` добавить `labels: labels, diarizationFailure: diarizationFailure`.

после успешной записи markdown — запомнить связь файла с голосами:

```swift
        // Written after the file exists: the row says "the archive holds a file whose header
        // means these voices", and a row without its file would let the archive pass read a
        // rename out of thin air.
        //
        // The rows are built from `labels` — from what the file actually shows — and never from
        // the voices the diarizer found. Those two can differ: a voice all of whose words went
        // to a neighbour has no line in the transcript and no position in the header. Numbering
        // rows from the diarizer's list would shift every position after it by one, and the
        // archive pass would then read an untouched file as a rename.
        if var book = updatedBook, let labels, !labels.order.isEmpty {
            let rows = labels.order.enumerated().map { position, voice in
                MeetingLabels.Label(
                    position: position + 1,
                    voiceId: identities[voice],
                    renderedName: labels.label(for: .voice(voice))
                )
            }
            book.record(MeetingLabels(file: transcript.lastPathComponent, labels: rows))
            try? await voiceStore.save(book)
        }
```

и `resolveDiarizer()` по образцу `resolveTranscriber()`.

В `App/AppDelegate.swift` и `CLI/MeetingCommands.swift` дополнить создание очереди: `makeDiarizer: { try await FluidDiarizer.load() }`.

- [ ] **Step 9: Run the whole suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add Core Features CLI App Tests
git commit -m "Диаризация в конвейере встречи, отказ не роняет встречу"
```

---

### Task 7: Правка имени в шапке переезжает в базу

**Files:**
- Create: `Core/Transcript/ParticipantsLine.swift`
- Create: `Features/Meetings/SpeakerNaming.swift`
- Modify: `App/AppDelegate.swift` (запуск прохода рядом с `summarizer.scanArchive()`)
- Test: `Tests/CoreTests/ParticipantsLineTests.swift`
- Test: `Tests/MeetingsTests/SpeakerNamingTests.swift`

**Interfaces:**
- Consumes: `VoiceBook`, `MeetingLabels`, `VoiceStore`, `TranscriptIndex`
- Produces: `ParticipantsLine.parse(_:) -> [String]?`, `ParticipantsLine.replace(in:with:) -> String`, `ParticipantsLine.rename(in:from:to:) -> String`, `SpeakerNaming.scanArchive()`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CoreTests/ParticipantsLineTests.swift
import Foundation
import Testing
@testable import Core

private let file = """
---
date: 2026-09-09
participants: [Я, Настя, Собеседник 2]
---

## Транскрипт
[00:00:03] Настя: привет
[00:00:11] Я: привет и тебе
[00:00:15] Собеседник 2: и вам

"""

@Test func theListIsRead() {
    #expect(ParticipantsLine.parse(file) == ["Я", "Настя", "Собеседник 2"])
}

@Test func aFileWithoutTheLineHasNoParticipants() {
    #expect(ParticipantsLine.parse("---\ndate: 2026-09-09\n---\n") == nil)
}

@Test func quotedNamesComeBackWhole() {
    let quoted = "---\nparticipants: [Я, \"Настя, она же Настасья\"]\n---\n"
    #expect(ParticipantsLine.parse(quoted) == ["Я", "Настя, она же Настасья"])
}

@Test func theListIsWrittenBack() {
    let updated = ParticipantsLine.replace(in: file, with: ["Я", "Настя", "Пётр"])
    #expect(updated.contains("participants: [Я, Настя, Пётр]\n"))
    #expect(!updated.contains("Собеседник 2"))
}

// Only the label is touched. The text of a reply may have been edited by hand, and a line that
// merely mentions the old name in its text is not a label.
@Test func onlyTheLabelIsRenamed() {
    let renamed = ParticipantsLine.rename(in: file, from: "Собеседник 2", to: "Пётр")
    #expect(renamed.contains("[00:00:15] Пётр: и вам\n"))
    #expect(renamed.contains("[00:00:03] Настя: привет\n"))
}

@Test func renamingLeavesTheRestOfTheFileByteForByte() {
    let renamed = ParticipantsLine.rename(in: file, from: "Собеседник 2", to: "Пётр")
    let before = file.components(separatedBy: "\n")
    let after = renamed.components(separatedBy: "\n")
    #expect(before.count == after.count)
    for index in before.indices where !before[index].hasPrefix("[00:00:15]") {
        #expect(before[index] == after[index])
    }
}

// A reply whose text happens to start with a name-like prefix must not be re-labelled: the
// label is what stands between `] ` and the first colon, and nothing else is.
@Test func aColonInsideTheTextIsNotALabel() {
    let tricky = "## Транскрипт\n[00:00:01] Я: Собеседник 2: так он и сказал\n"
    let renamed = ParticipantsLine.rename(in: tricky, from: "Собеседник 2", to: "Пётр")
    #expect(renamed == tricky)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParticipantsLineTests`
Expected: FAIL — `cannot find 'ParticipantsLine' in scope`

- [ ] **Step 3: Write it**

```swift
// Core/Transcript/ParticipantsLine.swift
import Foundation

/// The `participants:` line of a meeting file — read, rewritten, and used to rename labels.
///
/// This is the one line of the archive the owner is expected to edit, so everything here works
/// on the text of the file rather than on a parsed model of it: the file is the archive, it
/// outlives every process, and rewriting it from parsed values would quietly discard whatever
/// else was typed into it.
public enum ParticipantsLine {
    public static let key = "participants:"

    /// - Returns: the names, or `nil` when the file has no such line at all. An empty list is a
    ///   different answer from a missing line and is returned as an empty array.
    public static func parse(_ markdown: String) -> [String]? {
        guard let line = markdown.components(separatedBy: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(key)
        }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces).dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return split(String(trimmed.dropFirst().dropLast()))
    }

    public static func replace(in markdown: String, with participants: [String]) -> String {
        let rendered = key + " [" + participants.map(Frontmatter.listValue).joined(separator: ", ") + "]"
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(key)
        }) else { return markdown }
        lines[index] = rendered
        return lines.joined(separator: "\n")
    }

    /// Renames the label of every reply that carries it, and touches nothing else.
    ///
    /// A label is what stands between `] ` and the first colon of a reply line — the same shape
    /// `TranscriptIndex` parses. The text after that colon is left alone even when it contains
    /// the old name, because the owner writes in that text and the archive is not ours to edit.
    public static func rename(in markdown: String, from old: String, to new: String) -> String {
        markdown.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
            let rest = line[line.index(after: close)...]
            let leading = rest.prefix { $0 == " " }
            let body = rest.dropFirst(leading.count)
            guard let colon = body.firstIndex(of: ":") else { return line }
            guard String(body[..<colon]) == old else { return line }
            return String(line[...close]) + leading + new + String(body[colon...])
        }.joined(separator: "\n")
    }

    /// Splits on commas that are not inside quotes, and unquotes what `Frontmatter.listValue`
    /// quoted on the way out.
    private static func split(_ body: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quoted:
                escaped = true
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !values.isEmpty { values.append(last) }
        return values.filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ParticipantsLineTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Write the failing test for the pass**

```swift
// Tests/MeetingsTests/SpeakerNamingTests.swift
import Core
import Foundation
import Testing
@testable import Meetings

private struct Archive {
    let root: URL
    let file: URL
    let store: VoiceStore
    let voices: [String]
}

private func makeArchive(
    header: String,
    replies: [String],
    labelNames: [String]
) throws -> Archive {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("2026-09-09-0941-telemost.md")
    let text = "---\ndate: 2026-09-09\n\(header)\n---\n\n## Транскрипт\n" + replies.joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: file)

    let store = VoiceStore(url: root.appendingPathComponent(".voices.json"))
    var book = VoiceBook.empty
    var ids: [String] = []
    for (index, rendered) in labelNames.enumerated() {
        // Distinct directions, so a merge is visible as one voice rather than two.
        var vector = [Float](repeating: 0, count: labelNames.count)
        vector[index] = 1
        let id = book.remember(
            VoicePrint(vector: vector), meeting: "2026-09-09-0941-telemost",
            seconds: 120, as: nil, maxPrints: 10
        )
        ids.append(id)
        _ = rendered
    }
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: labelNames.enumerated().map { index, rendered in
                MeetingLabels.Label(position: index + 1, voiceId: ids[index], renderedName: rendered)
            }
        )
    )
    try JSONEncoder.iso8601.encode(book).write(to: root.appendingPathComponent(".voices.json"))
    return Archive(root: root, file: file, store: store, voices: ids)
}

private func naming(_ archive: Archive, _ box: NamingBox) -> SpeakerNaming {
    SpeakerNaming(archive: archive.root, store: archive.store) { box.append($0) }
}

private final class NamingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [SpeakerNaming.Outcome] = []
    func append(_ outcome: SpeakerNaming.Outcome) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    var all: [SpeakerNaming.Outcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
}

@Test func aRenamedParticipantTeachesTheBook() async throws {
    let archive = try makeArchive(
        header: "participants: [Я, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:11] Я: привет и тебе"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    let text = try String(contentsOf: archive.file, encoding: .utf8)
    #expect(text.contains("[00:00:03] Настя: привет"))
    #expect(text.contains("[00:00:11] Я: привет и тебе"))
    let book = try await archive.store.book()
    #expect(book.name(of: archive.voices[0]) == "Настя")
    // Written back, so a second pass has nothing to do.
    #expect(book.labels(for: archive.file.lastPathComponent)?.labels[0].renderedName == "Настя")
    #expect(box.all.first?.named == ["Настя"])
}

@Test func anUntouchedFileIsLeftAlone() async throws {
    let archive = try makeArchive(
        header: "participants: [Я, Собеседник 1]",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().name(of: archive.voices[0]) == nil)
    #expect(box.all.isEmpty)
}

// One name over two rows is how the owner repairs a split the automatic clustering missed.
@Test func twoRowsWithOneNameMergeTheVoices() async throws {
    let archive = try makeArchive(
        header: "participants: [Настя, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:20] Собеседник 2: и вам"],
        labelNames: ["Собеседник 1", "Собеседник 2"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    let text = try String(contentsOf: archive.file, encoding: .utf8)
    #expect(text.contains("[00:00:03] Настя: привет"))
    #expect(text.contains("[00:00:20] Настя: и вам"))
    let book = try await archive.store.book()
    #expect(book.voices.count == 1)
    #expect(book.voices[0].prints.count == 2)
}

// The header is the one line the owner edits, and it can be edited into something that no longer
// lines up with what the file was written from. Guessing there would attach a name to a voice
// that never said it — permanently, in the book that outlives the audio.
@Test func aHeaderOfTheWrongLengthIsRefusedNotGuessed() async throws {
    let archive = try makeArchive(
        header: "participants: [Я, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:20] Собеседник 2: и вам"],
        labelNames: ["Собеседник 1", "Собеседник 2"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().voices.allSatisfy { $0.name == nil })
    #expect(box.all.first?.failure != nil)
}

// `~/Meetings` is an Obsidian folder by design: somebody else's note is not a broken meeting.
@Test func aFileTheBookDoesNotKnowIsSkippedInSilence() async throws {
    let archive = try makeArchive(
        header: "participants: [Я, Собеседник 1]",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let note = archive.root.appendingPathComponent("заметка.md")
    try Data("Заметка про понедельник.\n\n- купить молока\n".utf8).write(to: note)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(box.all.allSatisfy { $0.file != "заметка.md" })
    #expect(try String(contentsOf: note, encoding: .utf8).hasPrefix("Заметка"))
}
```

> `JSONEncoder.iso8601` в хелпере — это тот же энкодер, которым пишет `VoiceStore`; если такого
> расширения в проекте нет, соберите энкодер на месте с `dateEncodingStrategy = .iso8601`.
> Даты обязаны кодироваться так же, как их читает store, иначе хелпер запишет книгу, которую
> `book()` не разберёт, и тест провалится по причине, не имеющей отношения к его предмету.

- [ ] **Step 6: Write the pass**

```swift
// Features/Meetings/SpeakerNaming.swift
import Core
import Foundation

/// Carries a name the owner typed into a file's header back into the book, and down into that
/// file's own labels.
///
/// A pass over the archive rather than a watcher: the same shape `MeetingSummarizer` uses, for
/// the same reason — the state is the file itself, an edit made while the application was shut
/// down is picked up for free, and nothing has to be remembered between launches.
public actor SpeakerNaming {
    public struct Outcome: Equatable, Sendable {
        public var file: String
        public var named: [String]
        public var failure: String?

        public init(file: String, named: [String], failure: String?) {
            self.file = file
            self.named = named
            self.failure = failure
        }
    }

    private let archive: URL
    private let store: VoiceStore
    private let report: @Sendable (Outcome) -> Void
    private var scanning = false

    public init(
        archive: URL = MeetingFolder.archiveURL,
        store: VoiceStore = VoiceStore(),
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.archive = archive
        self.store = store
        self.report = report
    }

    /// One pass at a time, exactly like `MeetingSummarizer.scanArchive`: two overlapping passes
    /// would read one file before the other had written it and undo each other's edits.
    public func scanArchive() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        guard var book = try? await store.book() else {
            // A book that does not parse is not overwritten and not guessed at — see
            // `VoiceStore.book`. Nothing here can proceed without it.
            report(Outcome(file: "", named: [], failure: "Книга голосов не читается"))
            return
        }

        var changed = false
        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard let known = book.labels(for: file.lastPathComponent), !known.labels.isEmpty else {
                continue
            }
            guard let listed = ParticipantsLine.parse(text) else { continue }

            // The header lists the owner first when he spoke; the labels never include him.
            let voices = listed.first == "Я" ? Array(listed.dropFirst()) : listed
            guard voices.count == known.labels.count else {
                report(
                    Outcome(
                        file: file.lastPathComponent, named: [],
                        failure: "В шапке \(voices.count) участников, а размечено \(known.labels.count) —"
                            + " строка правится, а не переписывается целиком"
                    )
                )
                continue
            }

            var updated = text
            var named: [String] = []
            for (index, label) in known.labels.sorted(by: { $0.position < $1.position }).enumerated() {
                let typed = voices[index]
                guard typed != label.renderedName, !typed.isEmpty else { continue }
                // A row without a voice behind it — a speaker too brief to fingerprint — still
                // gets its label rewritten in the file and its row updated below, so the pass is
                // idempotent. It simply teaches the book nothing: there is nothing to teach it
                // about.
                if let voiceId = label.voiceId { book.rename(voiceId, to: typed) }
                updated = ParticipantsLine.rename(in: updated, from: label.renderedName, to: typed)
                named.append(typed)
            }
            guard !named.isEmpty else { continue }

            // The rows are rewritten with what the file now shows, so the next pass sees no
            // change. `book.rename` may have merged two voices, so identities are re-read from
            // the book rather than reused.
            let rows = known.labels.sorted { $0.position < $1.position }.enumerated().map { index, label in
                MeetingLabels.Label(
                    position: label.position,
                    // Re-read rather than reused: `book.rename` merges two voices when one name
                    // covers both, and the absorbed identity no longer exists.
                    voiceId: label.voiceId.map { id in
                        book.voices.contains { $0.id == id }
                            ? id
                            : (book.voices.first { $0.name == voices[index] }?.id ?? id)
                    },
                    renderedName: voices[index]
                )
            }
            book.record(MeetingLabels(file: file.lastPathComponent, labels: rows))

            do {
                try Data(updated.utf8).write(to: file, options: .atomic)
                changed = true
                report(Outcome(file: file.lastPathComponent, named: named, failure: nil))
            } catch {
                report(
                    Outcome(file: file.lastPathComponent, named: [], failure: error.localizedDescription)
                )
            }
        }

        if changed { try? await store.save(book) }
    }

    private func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

В `App/AppDelegate.swift` завести `SpeakerNaming` рядом с `MeetingSummarizer` и вызывать `scanArchive()` в тех же двух местах, где вызывается `summarizer.scanArchive()` — при запуске и после готовой встречи, **после** конспекта: конспект вставляет разделы, переименование меток трогает только строки реплик, и порядок между ними безразличен, но два прохода по одному файлу не должны идти одновременно.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Core Features App Tests
git commit -m "Имя из шапки переезжает в базу голосов и в метки реплик"
```

---

### Task 8: `nohands meeting diarize`

**Files:**
- Modify: `CLI/MeetingArguments.swift` (подкоманда, флаги `--threshold`, `--write`)
- Modify: `CLI/MeetingCommands.swift` (реализация)
- Modify: `CLI/NoHands.swift` (справка и диспетчеризация)
- Test: `Tests/CLITests/MeetingArgumentsTests.swift` (дополнить)

**Interfaces:**
- Consumes: `FluidDiarizer`, `VoiceClustering`, `VoiceBook`, `MeetingVoices`, `SummaryInsertion`-подобная вставка секции
- Produces: `MeetingArguments.Subcommand.diarize`, `MeetingArguments.threshold: Double?`, `MeetingArguments.write: Bool`

- [ ] **Step 1: Write the failing test**

```swift
// добавить в Tests/CLITests/MeetingArgumentsTests.swift
@Test func diarizeIsParsed() throws {
    let arguments = try MeetingArguments.parse(["meeting", "diarize", "/tmp/встреча"])
    #expect(arguments.subcommand == .diarize)
    #expect(arguments.threshold == nil)
    #expect(arguments.write == false)
}

@Test func theThresholdAndTheWriteFlagAreParsed() throws {
    let arguments = try MeetingArguments.parse(
        ["meeting", "diarize", "/tmp/встреча", "--threshold", "0.75", "--write"]
    )
    #expect(arguments.threshold == 0.75)
    #expect(arguments.write)
}

// A threshold that is not a number would otherwise silently become the default, and the whole
// point of the command is to see what a particular number does.
@Test func aBadThresholdIsRefused() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "diarize", "/tmp/встреча", "--threshold", "почти"])
    }
}
```

- [ ] **Step 2: Extend the parser**

Добавить `case diarize` в `Subcommand`, поля `threshold: Double?` и `write: Bool` со значениями по умолчанию `nil`/`false`, разбор флагов после позиционного аргумента и обновить оба сообщения об использовании — они перечисляют подкоманды.

- [ ] **Step 3: Run the parser tests**

Run: `swift test --filter MeetingArgumentsTests`
Expected: PASS

- [ ] **Step 4: Write the failing test for the section replacement**

```swift
// Tests/CoreTests/TranscriptSectionTests.swift
import Foundation
import Testing
@testable import Core

private let file = """
---
date: 2026-09-09
participants: [Я, Собеседник]
---

## Саммари

- о чём-то договорились

## Транскрипт
[00:00:03] Собеседник: привет

"""

@Test func onlyTheTranscriptAndTheHeaderChange() throws {
    let transcript = [
        Utterance(speaker: .voice("v1"), start: 3, end: 5, text: "привет"),
        Utterance(speaker: .voice("v2"), start: 7, end: 9, text: "и вам"),
    ]
    let updated = try TranscriptSection.replace(
        in: file,
        transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]),
        named: "тест.md"
    )
    #expect(updated.contains("## Саммари\n"))
    #expect(updated.contains("- о чём-то договорились\n"))
    #expect(updated.contains("participants: [Собеседник 1, Собеседник 2]\n"))
    #expect(updated.contains("[00:00:03] Собеседник 1: привет\n"))
    #expect(updated.contains("[00:00:07] Собеседник 2: и вам\n"))
    #expect(!updated.contains("[00:00:03] Собеседник: привет\n"))
}

@Test func aFileWithoutATranscriptSectionIsRefused() {
    #expect(throws: (any Error).self) {
        try TranscriptSection.replace(
            in: "---\n---\n", transcript: [], labels: SpeakerLabels(order: [], names: [:], ownerSpoke: false),
            named: "тест.md"
        )
    }
}

// A file that has never had a `participants:` line — every meeting written before phase 2г —
// gets one rather than losing the header it does have.
@Test func aHeaderWithoutParticipantsGainsTheLine() throws {
    let old = "---\ndate: 2026-09-01\n---\n\n## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "раз")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]), named: "тест.md"
    )
    #expect(updated.contains("date: 2026-09-01\n"))
    #expect(updated.contains("participants: [Собеседник]\n"))
}
```

- [ ] **Step 5: Write `TranscriptSection`**

```swift
// Core/Transcript/TranscriptSection.swift
import Foundation

/// Replaces the transcript of an existing meeting file, and its `participants:` line, leaving
/// everything above the transcript heading alone.
///
/// The counterpart of `SummaryInsertion`, which writes above the heading and leaves the
/// transcript alone. Between them the file has two owners and no overlap: re-diarizing a meeting
/// must not cost it its summary, and summarising must not cost it its speaker labels.
public enum TranscriptSection {
    public enum Failure: LocalizedError, Equatable {
        case noTranscriptSection(String)

        public var errorDescription: String? {
            switch self {
            case .noTranscriptSection(let name):
                return "No \(TranscriptIndex.heading) section in \(name) — nothing this pipeline wrote"
            }
        }
    }

    public static func replace(
        in file: String,
        transcript: [Utterance],
        labels: SpeakerLabels,
        named name: String
    ) throws -> String {
        var lines = file.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == TranscriptIndex.heading
        }) else { throw Failure.noTranscriptSection(name) }

        var head = Array(lines[...heading])
        let participants = ParticipantsLine.key + " ["
            + labels.participants.map(Frontmatter.listValue).joined(separator: ", ") + "]"
        if let index = head.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(ParticipantsLine.key)
        }) {
            head[index] = participants
        } else if head.first?.trimmingCharacters(in: .whitespaces) == "---",
            let close = head.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            }), !labels.order.isEmpty {
            head.insert(participants, at: close)
        }

        var out = head
        out.append("")
        for utterance in transcript {
            out.append(
                "[\(MeetingMarkdown.timestamp(utterance.start))] "
                    + "\(labels.label(for: utterance.speaker)): \(utterance.text)"
            )
        }
        out.append("")
        lines = out
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 6: Implement the command**

```swift
// CLI/MeetingCommands.swift
/// `nohands meeting diarize` — размечает голоса на дорожке собеседников.
///
/// Читает и сжатые дорожки тоже: и Parakeet, и диаризатор открывают файл через `AVAudioFile`.
/// Это и делает команду инструментом подбора порога — размечать можно любую встречу архива, а
/// не только ту, чьи сырые дорожки ещё не удалены.
///
/// По умолчанию ничего не пишет. Подбирать порог на архиве, который сам же и правишь, нельзя:
/// первая же неудачная попытка испортила бы то, с чем сравниваешь.
func runMeetingDiarize(_ folder: URL, threshold: Double?, write: Bool) async throws {
    var config = try MeetingsConfig.loadOrCreate()
    if let threshold { config.voiceMatchThreshold = threshold }
    let language = (try? DictationConfig.loadOrCreate())?.language

    let system = trackURL(in: folder, named: MeetingAudioRecorder.systemFileName)
    guard let system else {
        fail("В папке нет дорожки собеседников — ни system.wav, ни system.m4a")
    }

    let diarizer = try await FluidDiarizer.load()
    let voices = VoiceClustering.voices(
        from: try await diarizer.segments(of: system),
        threshold: Float(config.voiceMatchThreshold)
    )
    note("порог: \(config.voiceMatchThreshold), голосов: \(voices.count)")

    let store = VoiceStore()
    var book = try await store.book()
    for voice in voices {
        let known = book.match(voice.print, threshold: Float(config.voiceMatchThreshold))
        let name = known.flatMap(\.name) ?? (known == nil ? "новый голос" : "без имени")
        note(
            String(
                format: "  %@: %.0f с речи, %d сегментов — %@",
                voice.id, voice.speechSeconds, voice.segments.count, name
            )
        )
    }
    // Косинусы между голосами встречи: это то число, по которому подбирается порог.
    for (index, left) in voices.enumerated() {
        for right in voices[(index + 1)...] {
            note(
                String(
                    format: "  %@ ~ %@: %.3f", left.id, right.id,
                    VoicePrint.cosine(left.print, right.print)
                )
            )
        }
    }

    guard write else {
        note("ничего не записано — добавьте --write, чтобы переписать транскрипт и базу")
        return
    }

    let transcriber = try await ParakeetTranscriber.load(language: language)
    let words = try await transcriber.transcribeTimed(audio: system)
    let resolution = MeetingVoices.resolve(
        voices: voices, meeting: folder.lastPathComponent, book: &book, config: config
    )
    let theirs = Utterance.split(
        assigned: VoiceAssignment.assign(words: words, to: voices),
        gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
    )

    let microphone = trackURL(in: folder, named: MeetingAudioRecorder.microphoneFileName)
    var mine: [Utterance] = []
    if let microphone {
        let all = Utterance.split(
            words: try await transcriber.transcribeTimed(audio: microphone),
            speaker: .me, gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
        )
        mine = try PhraseLevel.passing(all, thresholdDBFS: Float(config.micThresholdDBFS)) {
            try PhraseLevel.peakDBFS(of: microphone, from: $0.start, to: $0.end)
        }
    }

    let metadata = try MeetingMetadata.read(
        from: folder.appendingPathComponent(MeetingMetadata.fileName)
    )
    let merged = MeetingTranscript.merge(
        mine: mine, theirs: theirs,
        microphoneStartedAt: metadata.microphoneStartedAt,
        systemStartedAt: metadata.systemStartedAt
    )
    let labels = SpeakerLabels.make(transcript: merged, names: resolution.names)

    let file = MeetingFolder.archiveURL.appendingPathComponent(folder.lastPathComponent + ".md")
    let existing = try String(contentsOf: file, encoding: .utf8)
    let updated = try TranscriptSection.replace(
        in: existing,
        transcript: merged,
        labels: labels,
        named: file.lastPathComponent
    )
    try Data(updated.utf8).write(to: file, options: .atomic)

    // Те же строки, что пишет очередь, и по тому же правилу: позиции берутся из шапки файла,
    // а не из списка голосов диаризатора — иначе проход по архиву прочитал бы нетронутый файл
    // как переименование.
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: labels.order.enumerated().map { position, voice in
                MeetingLabels.Label(
                    position: position + 1,
                    voiceId: resolution.identities[voice],
                    renderedName: labels.label(for: .voice(voice))
                )
            }
        )
    )
    try await store.save(book)
    note("переписано: \(file.lastPathComponent), участников \(labels.participants.count)")
}

/// Сырая дорожка, а если её уже нет — сжатая.
private func trackURL(in folder: URL, named name: String) -> URL? {
    let raw = folder.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: raw.path) { return raw }
    let compressed = raw.deletingPathExtension().appendingPathExtension("m4a")
    return FileManager.default.fileExists(atPath: compressed.path) ? compressed : nil
}
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter 'TranscriptSectionTests|MeetingArgumentsTests'`
Expected: PASS

- [ ] **Step 8: Run the whole suite and commit**

```bash
swift test
git add Core CLI Tests
git commit -m "Команда nohands meeting diarize и замена секции транскрипта"
```

---

### Task 9: Живая проверка

Тестов здесь нет: проверяется то, чего тесты не видят — настоящий звук, настоящий архив, собранное приложение.

- [ ] **Step 1: Собрать и прогнать всё**

```bash
swift build && swift test
```

- [ ] **Step 2: Переразбор шести встреч по копиям, без записи**

```bash
for m in 2026-09-04-1053-telemost 2026-09-07-1009-telemost 2026-09-07-1600-telemost \
         2026-09-08-1101-telemost 2026-09-08-1245-telemost 2026-09-09-0941-telemost; do
  ./.build/debug/nohands meeting diarize ~/Meetings/.queue/$m
done
```

Смотреть на две вещи: сколько голосов и косинусы между ними. Голоса, стоящие друг к другу ближе 0,7, но не склеенные, означают, что порог высок; голоса на 0,5–0,6 друг от друга, которые на слух один человек, означают то же.

- [ ] **Step 3: Подобрать порог, если раскладка не сходится**

```bash
./.build/debug/nohands meeting diarize ~/Meetings/.queue/2026-09-08-1245-telemost --threshold 0.65
```

Итоговое значение вписать в `voiceMatchThreshold` в `config.json` и в `MeetingsConfig.default`, а рядом — комментарий с числами, на которых оно выбрано.

- [ ] **Step 4: Записать разметку в архив для одной встречи**

```bash
./.build/debug/nohands meeting diarize ~/Meetings/.queue/2026-09-09-0941-telemost --write
```

Проверить в файле: `participants` появился, метки в репликах сменились, разделы конспекта на месте, таймкоды решений по-прежнему указывают на существующие строки.

- [ ] **Step 5: Назвать человека руками**

Открыть файл, заменить в `participants` одну метку на имя, запустить приложение и убедиться, что метки в репликах сменились, а `~/Meetings/.voices.json` получил имя.

- [ ] **Step 6: Живая встреча**

Пересобрать приложение (`Scripts/make-app.sh`), перезапустить, провести настоящий созвон. Проверить путь целиком: запись → расшифровка → разметка голосов → конспект → узнавание названного человека без единой команды.

- [ ] **Step 7: Записать итоги фазы**

Дописать в `docs/DECISIONS.md` запись «Итоги фазы 2г»: числа прогонов, выбранный порог, что нашлось живой проверкой и чего фаза не проверила. Правки `docs/` коммитятся и пушатся отдельным коммитом сразу.
