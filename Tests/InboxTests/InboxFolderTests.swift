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

private func temporaryFile(named name: String, contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(name)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}

// Copied, never moved: the source is somebody else's folder — the Telegram cache, Downloads —
// and taking a file out of it is not this application's business.
@Test func anAttachmentIsCopiedAndTheSourceStaysWhereItWas() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let source = try temporaryFile(named: "лендинг.html", contents: "<html>")
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

    let copy = try InboxFolder.copyAttachment(source, into: folder)

    #expect(copy.lastPathComponent == "лендинг.html")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "<html>")
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func aSecondAttachmentWithTheSameNameGetsASuffixAndKeepsItsExtension() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let first = try temporaryFile(named: "отчёт.pdf", contents: "один")
    let second = try temporaryFile(named: "отчёт.pdf", contents: "два")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    _ = try InboxFolder.copyAttachment(first, into: folder)
    let copy = try InboxFolder.copyAttachment(second, into: folder)

    #expect(copy.lastPathComponent == "отчёт-2.pdf")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "два")
}

@Test func aFileWithoutAnExtensionAlsoGetsASuffix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try InboxFolder.create(in: root, capturedAt: noon, slug: "telegram")
    let first = try temporaryFile(named: "README", contents: "один")
    let second = try temporaryFile(named: "README", contents: "два")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    _ = try InboxFolder.copyAttachment(first, into: folder)
    #expect(try InboxFolder.copyAttachment(second, into: folder).lastPathComponent == "README-2")
}
