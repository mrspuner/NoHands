import Foundation
import Testing
@testable import Inbox

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func theSlugIsTheLastComponentOfTheBundleIdentifier() {
    #expect(InboxFolder.slug(forBundleID: "ru.keepcoder.Telegram") == "telegram")
    #expect(InboxFolder.slug(forBundleID: "com.apple.Safari") == "safari")
}

// `NSRunningApplication.bundleIdentifier` is optional, and a folder whose name ends in a dash
// would be the visible shape of that fact.
@Test func anApplicationWithoutAnIdentifierStillGetsASlug() {
    #expect(InboxFolder.slug(forBundleID: "") == "app")
}

@Test func theFolderIsNamedByDateTimeAndSlug() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    #expect(folder.lastPathComponent.hasSuffix("-telegram"))
    #expect(folder.lastPathComponent == InboxFolder.baseName(capturedAt: noon, slug: "telegram"))
    #expect(FileManager.default.fileExists(atPath: folder.path))
}

// Two captures out of the same chat inside one minute is the ordinary case, not the exotic one.
@Test func aSecondCaptureInTheSameMinuteGetsASuffix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let second = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    #expect(second.lastPathComponent == first.lastPathComponent + "-2")
    #expect(FileManager.default.fileExists(atPath: second.path))
}

@Test func theRootIsInboxInTheHomeDirectory() {
    #expect(InboxFolder.rootURL.lastPathComponent == "Inbox")
    #expect(InboxFolder.rootURL.deletingLastPathComponent().path
        == FileManager.default.homeDirectoryForCurrentUser.path)
}
