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
