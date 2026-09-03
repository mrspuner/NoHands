import Foundation
import Testing
@testable import Meetings

private func temporaryQueue() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func aDraftFolderIsNamedByDateTimeAndSlugAndStartsWithADot() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let draft = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    #expect(draft.lastPathComponent.hasPrefix(".draft-"))
    #expect(draft.lastPathComponent.hasSuffix("-telemost"))
    #expect(FileManager.default.fileExists(atPath: draft.path))
}

// The leading dot is the sign of unfinished work: phase 2б picks up folders without a dot and
// needs neither locks nor reading metadata to tell whether one is done.
@Test func promotingDropsTheDotAndKeepsTheRest() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let draft = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "zoom")
    let final = try MeetingFolder.promote(draft)
    #expect(final.lastPathComponent == String(draft.lastPathComponent.dropFirst(".draft-".count)))
    #expect(FileManager.default.fileExists(atPath: final.path))
    #expect(!FileManager.default.fileExists(atPath: draft.path))
}

@Test func twoMeetingsStartedInTheSameMinuteGetDifferentFolders() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let first = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    _ = try MeetingFolder.promote(first)
    let second = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "telemost")
    #expect(second.lastPathComponent != first.lastPathComponent)
    #expect(second.lastPathComponent.hasSuffix("-2"))
}

@Test func onlyDraftsAreListedAsUnfinished() throws {
    let queue = try temporaryQueue()
    defer { try? FileManager.default.removeItem(at: queue) }
    let done = try MeetingFolder.createDraft(in: queue, startedAt: noon, slug: "zoom")
    _ = try MeetingFolder.promote(done)
    let live = try MeetingFolder.createDraft(
        in: queue, startedAt: noon.addingTimeInterval(3600), slug: "telemost"
    )
    let drafts = try MeetingFolder.drafts(in: queue)
    #expect(drafts.map(\.lastPathComponent) == [live.lastPathComponent])
}
