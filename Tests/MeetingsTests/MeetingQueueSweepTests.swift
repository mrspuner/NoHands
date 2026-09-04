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
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
    let old = try makeFolder(root.queue, "2026-08-20-1000-telemost", startedAt: now.addingTimeInterval(-8 * 86400))
    try markProcessed(old, at: now.addingTimeInterval(-8 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test func aFreshProcessedFolderStays() async throws {
    let root = try makeQueueRoot()
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
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
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
    let broken = try makeFolder(root.queue, "2026-08-01-1000-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    try MeetingErrorFile.write("битый файл", at: now, to: broken)
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: broken.path))
}

// An unprocessed folder is never swept: rotation discards a copy of the audio, not the meeting.
@Test func anUnprocessedFolderIsNeverSwept() async throws {
    let root = try makeQueueRoot()
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
    let waiting = try makeFolder(root.queue, "2026-08-01-1100-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: waiting.path))
}

@Test func aDraftIsNeverSwept() async throws {
    let root = try makeQueueRoot()
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
    let draft = try makeFolder(root.queue, ".draft-2026-08-01-1200-telemost", startedAt: now.addingTimeInterval(-30 * 86400))
    let queue = makeQueue(root, seen: Seen())

    await queue.sweep(now: now)

    #expect(FileManager.default.fileExists(atPath: draft.path))
}

// Enqueuing a finished folder must change nothing. Without the guard it would be re-processed,
// find its tracks already compressed, and leave a good meeting marked as failed.
@Test func enqueuingAFinishedFolderLeavesItAlone() async throws {
    let root = try makeQueueRoot()
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
    let done = try makeFolder(root.queue, "2026-09-04-1200-c", startedAt: now)
    try markProcessed(done, at: now)
    let seen = Seen()
    let queue = makeQueue(root, seen: seen)

    await queue.enqueue(done)

    #expect(seen.all.isEmpty)
    #expect(MeetingErrorFile.read(in: done) == nil)
    #expect(MeetingFolderState.of(done) == .processed(now))
}

@Test func scanPicksUpWaitingAndFailedFoldersButNotDraftsOrProcessed() async throws {
    let root = try makeQueueRoot()
    defer { try? FileManager.default.removeItem(at: root.queue.deletingLastPathComponent()) }
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
