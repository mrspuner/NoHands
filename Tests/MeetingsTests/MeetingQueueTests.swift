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
private func makeMeetingFolder(
    name: String = "2026-09-04-1053-telemost",
    trailingMicrophoneSilenceSeconds: TimeInterval? = nil,
    microphoneSawAudio: Bool? = nil
) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mq-\(UUID().uuidString)")
    let archive = root
    let queue = root.appendingPathComponent(".queue")
    let folder = queue.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for track in ["system.wav", "mic.wav"] {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        )!
        // `AVAudioFile(forWriting:settings:)` alone opens the file in the standard format
        // (deinterleaved Float32) no matter what `settings` says, and writing an Int16 buffer
        // into it traps inside AudioToolbox instead of throwing — documented on
        // `RecordingChecks.openForWriting`. Pass the format explicitly, as
        // `AudioCompressorTests` does.
        let file = try AVAudioFile(
            forWriting: folder.appendingPathComponent(track), settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        try file.write(from: buffer)
    }

    let metadata = MeetingMetadata(
        startedAt: Date(timeIntervalSince1970: 1_788_500_000), stoppedAt: nil,
        app: MeetingMetadata.App(bundleID: "ru.yandex.desktop.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000, channelCount: 1, inputDevice: nil, stopReason: .manual,
        excludedApps: [], gaps: [], systemStartedAt: 100, microphoneStartedAt: 100,
        trailingMicrophoneSilenceSeconds: trailingMicrophoneSilenceSeconds,
        microphoneSawAudio: microphoneSawAudio
    )
    try metadata.write(to: folder.appendingPathComponent(MeetingMetadata.fileName))
    return Fixture(queue: queue, archive: archive, folder: folder)
}

private func word(_ text: String, _ start: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: start + 0.4, confidence: 1)
}

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

private func makeQueue(
    _ fixture: Fixture,
    transcriber: StubTranscriber,
    level: @escaping @Sendable (URL, TimeInterval, TimeInterval) throws -> Float = { _, _, _ in 0 },
    diarizer: any Diarizing = FakeDiarizer(),
    store: VoiceStore? = nil,
    outcomes: @escaping @Sendable (MeetingQueue.Outcome) -> Void
) -> MeetingQueue {
    MeetingQueue(
        queue: fixture.queue,
        archive: fixture.archive,
        config: .default,
        makeTranscriber: { transcriber },
        makeDiarizer: { diarizer },
        voiceStore: store ?? VoiceStore(url: fixture.archive.appendingPathComponent(".voices.json")),
        measureLevel: level,
        compress: { _, destination, _ in try Data("aac".utf8).write(to: destination) },
        report: outcomes
    )
}

@Test func aGoodFolderProducesMarkdownAndCompressedTracks() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
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

// Число из `meeting.json` обязано доехать до архива: `sweep` сносит папку очереди целиком через
// `audioRetentionDays`, а вопрос «почему в файле нет «Я»» задают позже.
@Test func aSilentMicrophoneTrackIsExplainedInTheArchivedFile() async throws {
    let fixture = try makeMeetingFolder(
        trailingMicrophoneSilenceSeconds: 600, microphoneSawAudio: true
    )
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: ["system.wav": [word("привет", 3)]])
    let queue = makeQueue(fixture, transcriber: transcriber) { _ in }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains(#"microphone: "замолчал в конце — 10 мин тишины, дорожка неполная""#))
}

// Второй признак из `meeting.json` обязан доехать до архива вместе с числом: без него очередь
// выбирает формулировку из одного числа, а одного числа хватает ровно на ту ложь, ради которой
// заведена ветка, — «замолчал в конце» о дорожке, которой не было вовсе.
@Test func aTrackThatNeverCarriedAudioIsCalledEmptyInTheArchivedFile() async throws {
    let fixture = try makeMeetingFolder(
        trailingMicrophoneSilenceSeconds: 5580, microphoneSawAudio: false
    )
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: ["system.wav": [word("привет", 3)]])
    let queue = makeQueue(fixture, transcriber: transcriber) { _ in }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains(#"microphone: "молчал всю запись — дорожка пустая""#))
}

// Тот же порог, что у панели: разрыв короче — это разрыв между буферами, и утверждать о нём в
// архиве нечего.
@Test func aGapShorterThanTheThresholdSaysNothingInTheArchivedFile() async throws {
    let fixture = try makeMeetingFolder(trailingMicrophoneSilenceSeconds: 9)
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: ["system.wav": [word("привет", 3)]])
    let queue = makeQueue(fixture, transcriber: transcriber) { _ in }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(!text.contains("microphone:"))
}

@Test func quietMicrophoneUtterancesDoNotReachTheFile() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: [
        "system.wav": [word("вопрос", 1)],
        "mic.wav": [word("комната", 5)],
    ])
    let box = OutcomeBox()
    // The default threshold is -40; return -45 for every microphone query.
    let queue = makeQueue(fixture, transcriber: transcriber, level: { _, _, _ in -45 }) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains("вопрос"))
    #expect(!text.contains("комната"))
}

// `merged.isEmpty` has two different causes, and the message must tell them apart: here the
// microphone track did produce words, every one of them measured below the threshold, and the
// system track produced none at all. Reporting this the same way as genuine silence would send
// the owner listening to a recording that in fact has speech on it, instead of at the setting
// that discarded it.
@Test func aThresholdThatAteEverythingNamesItself() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: ["mic.wav": [word("комната", 1)]])
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber, level: { _, _, _ in -45 }) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let reason = try #require(MeetingErrorFile.read(in: fixture.folder))
    #expect(reason.contains("micThresholdDBFS"))
    #expect(!reason.contains("No words were recognised in either track"))
}

// Both tracks without a single word is a failure, not an empty file: something is wrong with the
// audio, and it needs to be kept so it can be listened to.
@Test func twoSilentTracksAreAFailureAndKeepTheAudio() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
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
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    var transcriber = StubTranscriber(words: [:])
    transcriber.failureMessage = "нет модели"
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let reason = try #require(MeetingErrorFile.read(in: fixture.folder))
    #expect(reason.contains("нет модели"))
}

// The exact shape a previous attempt leaves behind when it dies between deleting one track and
// the other. Recomputing the track list from the WAVs that remain would read this as a one-track
// meeting, rewrite the archive without a single "Собеседник" line, and report success.
@Test func aHalfDeletedFolderIsAFailureRatherThanAOneTrackMeeting() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let fileManager = FileManager.default
    try fileManager.removeItem(at: fixture.folder.appendingPathComponent("system.wav"))
    try Data("aac".utf8).write(to: fixture.folder.appendingPathComponent("system.m4a"))

    let box = OutcomeBox()
    let transcriber = StubTranscriber(words: ["mic.wav": [word("моя реплика", 1)]])
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    #expect(box.all.first?.failure != nil)
    #expect(!fileManager.fileExists(
        atPath: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md").path
    ))
    // The track that survived is still there to retry with once the folder is sorted out.
    #expect(fileManager.fileExists(atPath: fixture.folder.appendingPathComponent("mic.wav").path))
}

// A folder whose tracks are all compressed is a different situation from a folder with no tracks
// at all, and the owner needs to be told which one they have: in the first the audio still
// exists, just not in a form this step reads.
@Test func aFullyCompressedFolderSaysSoRatherThanClaimingNoTracks() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let fileManager = FileManager.default
    for name in ["system", "mic"] {
        try fileManager.removeItem(at: fixture.folder.appendingPathComponent("\(name).wav"))
        try Data("aac".utf8).write(to: fixture.folder.appendingPathComponent("\(name).m4a"))
    }

    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: StubTranscriber(words: [:])) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let reason = try #require(MeetingErrorFile.read(in: fixture.folder))
    #expect(reason.contains("already compressed"))
}

@Test func aRetryClearsThePreviousError() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    try MeetingErrorFile.write("прошлый раз не вышло", at: Date(), to: fixture.folder)
    let transcriber = StubTranscriber(words: ["system.wav": [word("да", 1)]])
    let box = OutcomeBox()
    let queue = makeQueue(fixture, transcriber: transcriber) { box.append($0) }

    await queue.enqueue(fixture.folder)

    #expect(MeetingErrorFile.read(in: fixture.folder) == nil)
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
    // Labels and a diarization failure are mutually exclusive at this call site: a successful
    // run must never also carry the sentence a failed one would have written.
    #expect(!text.contains("speakers:"))
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
    if case .processed = MeetingFolderState.of(fixture.folder) {
    } else {
        Issue.record("expected the folder to be processed, got \(MeetingFolderState.of(fixture.folder))")
    }
}

/// A track with no speech at all is a legitimate outcome — the interlocutors said nothing while
/// the owner talked — not a broken model, so the file must say so in plain words rather than in
/// the diarizer's own vocabulary for the case.
private struct NoSpeechDiarizer: Diarizing {
    func segments(of audio: URL) async throws -> [VoiceSegment] { throw DiarizationError.noSpeech }
}

@Test func noSpeechOnTheInterlocutorsTrackIsNamedPlainly() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
    let transcriber = StubTranscriber(words: ["mic.wav": [word("здравствуйте", 1)]])
    let box = OutcomeBox()
    let queue = makeQueue(
        fixture, transcriber: transcriber, diarizer: NoSpeechDiarizer()
    ) { box.append($0) }

    await queue.enqueue(fixture.folder)

    let text = try String(
        contentsOf: fixture.archive.appendingPathComponent("2026-09-04-1053-telemost.md"),
        encoding: .utf8
    )
    #expect(text.contains(#"speakers: "не размечено — на дорожке собеседников не найдено речи""#))
    #expect(!text.contains("participants:"))
    #expect(box.all.first?.failure == nil)
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
