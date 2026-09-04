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

@Test func quietMicrophoneUtterancesDoNotReachTheFile() async throws {
    let fixture = try makeMeetingFolder()
    defer { try? FileManager.default.removeItem(at: fixture.archive) }
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
