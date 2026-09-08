import Foundation
import Testing
@testable import Inbox

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

/// Everything the coordinator can reach that a test cannot: the keystroke, the frontmost
/// application, the panel and the clock. Nothing else is faked — the folder and the file are the
/// real ones, in a temporary directory.
@MainActor
private final class Harness {
    let root: URL
    var text: Result<String, Error> = .success("> Натали:\nтекст")
    var source = InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil)
    private(set) var shown: [InboxPanelState] = []
    private(set) var hidden: [TimeInterval] = []
    private(set) var sounds: [InboxCoordinator.Sound] = []
    /// Implicitly unwrapped so the closures below may capture `self`: every other stored
    /// property has a default, so `self` is fully initialised by the time they are built.
    var coordinator: InboxCoordinator!

    init(root: URL, dropWindow: TimeInterval = 120) {
        self.root = root
        coordinator = InboxCoordinator(
            root: root,
            capture: { [weak self] in
                guard let self else { throw InboxCapture.Failure.nothingCopied }
                return try self.text.get()
            },
            readSource: { [weak self] in
                self?.source ?? InboxSource(appName: nil, bundleID: nil, url: nil)
            },
            now: { noon },
            dropWindow: dropWindow,
            showPanel: { [weak self] in self?.shown.append($0) },
            hidePanel: { [weak self] in self?.hidden.append($0) },
            play: { [weak self] in self?.sounds.append($0) }
        )
    }

    /// The capture runs in a task of its own — same shape as every other coordinator here.
    func capture() async {
        coordinator.captureRequested()
        await coordinator.settle()
    }

    var folders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }
}

@MainActor
@Test func aCaptureWritesOneFolderWithANoteAndSaysSo() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)

    await harness.capture()

    // The exact name depends on the machine's time zone — `MeetingFolderTests` checks the shape
    // for the same reason and in the same way.
    #expect(harness.folders.count == 1)
    #expect(harness.folders[0].hasSuffix("-telegram"))
    let note = root.appendingPathComponent(harness.folders[0]).appendingPathComponent("note.md")
    let contents = try String(contentsOf: note, encoding: .utf8)
    #expect(contents.contains("app: \"Telegram\""))
    #expect(contents.hasSuffix("> Натали:\nтекст\n"))
    #expect(harness.shown == [.captured(app: "Telegram", lines: 2, attachments: 0)])
    #expect(harness.sounds == [.done])
}

// An empty folder looks exactly like a capture that happened. This one did not.
@MainActor
@Test func aRefusedCaptureLeavesNothingOnDisk() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    harness.text = .failure(InboxCapture.Failure.nothingCopied)

    await harness.capture()

    #expect(harness.folders.isEmpty)
    #expect(harness.sounds == [.error])
    if case .failure = harness.shown.first {} else {
        Issue.record("панель должна назвать причину: \(harness.shown)")
    }
}

@MainActor
@Test func aDroppedFileLandsInTheFolderOfTheLastCapture() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()

    // Somewhere else on disk, the way a real drag comes from somebody else's folder.
    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let file = elsewhere.appendingPathComponent("источник.txt")
    try "данные".write(to: file, atomically: true, encoding: .utf8)

    #expect(harness.coordinator.drop([file]))

    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("источник.txt").path))
    #expect(harness.shown.last == .captured(app: "Telegram", lines: 2, attachments: 1))
}

// The target closes by itself. A file dropped after it has is refused rather than landing in a
// folder the owner has long forgotten about.
@MainActor
@Test func aDropAfterTheTargetClosedIsRefused() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root, dropWindow: 0.05)
    await harness.capture()
    try await Task.sleep(for: .milliseconds(150))

    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let file = elsewhere.appendingPathComponent("поздно.txt")
    try "данные".write(to: file, atomically: true, encoding: .utf8)

    #expect(!harness.coordinator.drop([file]))
    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("поздно.txt").path))
}

@MainActor
@Test func theTargetStaysOpenForTheWholeWindowAndTheDwellIsToldToThePanel() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()
    #expect(harness.hidden == [120])
}

@MainActor
@Test func twoCapturesInTheSameMinuteMakeTwoFolders() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    await harness.capture()
    await harness.capture()
    #expect(harness.folders.count == 2)
}
