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

/// The per-test queue directory, so a test can clean up after itself the way every other test
/// file in this target does.
private func queueRoot(of folder: URL) -> URL {
    folder.deletingLastPathComponent()
}

@Test func aDottedFolderIsStillBeingRecorded() throws {
    let folder = try makeFolder(".draft-2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    #expect(MeetingFolderState.of(folder) == .recording)
}

@Test func wavAndNothingElseMeansWaiting() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    try Data().write(to: folder.appendingPathComponent("system.wav"))
    #expect(MeetingFolderState.of(folder) == .waiting)
}

@Test func anErrorFileWins() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    try Data().write(to: folder.appendingPathComponent("system.wav"))
    try MeetingErrorFile.write("модель не поднялась", at: Date(), to: folder)
    #expect(MeetingFolderState.of(folder) == .failed("модель не поднялась"))
}

@Test func anErrorFileCanBeRemovedBeforeARetry() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    try MeetingErrorFile.write("сеть", at: Date(), to: folder)
    try MeetingErrorFile.remove(in: folder)
    #expect(MeetingErrorFile.read(in: folder) == nil)
    #expect(MeetingFolderState.of(folder) == .waiting)
}

@Test func processedIsRecognisedByItsRecord() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
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
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    let url = folder.appendingPathComponent(ProcessedRecord.fileName)
    let record = ProcessedRecord(
        processedAt: Date(timeIntervalSince1970: 1_788_500_000), elapsedSeconds: 21,
        meetingDurationSeconds: 254, transcriptPath: "/tmp/a.md"
    )
    try record.write(to: url)
    #expect(try ProcessedRecord.read(from: url) == record)
}

// The case the whole type exists to prevent: a folder that failed must never look like a folder
// that is merely waiting. An error file holding bytes that are not text is the realistic way
// that happens — the file gets written when something has already gone wrong.
@Test func anUnreadableErrorFileStillReadsAsAFailure() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    try Data([0xFF, 0xFE, 0xFF]).write(to: folder.appendingPathComponent(MeetingErrorFile.fileName))

    #expect(MeetingFolderState.of(folder) == .failed(MeetingErrorFile.unreadableReason))
}

// A failure with no explanation is still a failure, and saying so beats retrying in silence.
@Test func anEmptyErrorFileStillReadsAsAFailure() throws {
    let folder = try makeFolder("2026-09-04-1053-telemost")
    defer { try? FileManager.default.removeItem(at: queueRoot(of: folder)) }
    try Data().write(to: folder.appendingPathComponent(MeetingErrorFile.fileName))

    #expect(MeetingFolderState.of(folder) == .failed(MeetingErrorFile.unreadableReason))
}

// The archive is the folder above the queue — the same one Obsidian opens.
@Test func theArchiveIsTheFolderAboveTheQueue() {
    #expect(MeetingFolder.archiveURL == MeetingFolder.queueURL.deletingLastPathComponent())
}
