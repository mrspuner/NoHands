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
    /// Answers for the earliest outstanding calls to `capture`, consumed in call order; once
    /// exhausted, `text` answers every call after. Empty by default, so every existing test's
    /// single `text` keeps answering every call unchanged — this only matters to a test that
    /// needs the first and second capture of a pair to behave differently.
    var textQueue: [Result<String, Error>] = []
    var source = InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil)
    /// How long the `capture` closure suspends before answering. Zero by default, so every
    /// existing test's closure returns without ever yielding. Set to simulate a capture still in
    /// flight when a second `captureRequested()` supersedes it.
    var captureDelay: Duration = .zero
    private(set) var shown: [InboxPanelState] = []
    private(set) var hidden: [TimeInterval] = []
    private(set) var sounds: [InboxCoordinator.Sound] = []
    /// Records "capture" and "source" in the order the coordinator actually calls them, so a
    /// test can pin that order down without reaching into private state.
    private(set) var callOrder: [String] = []
    /// Implicitly unwrapped so the closures below may capture `self`: every other stored
    /// property has a default, so `self` is fully initialised by the time they are built.
    var coordinator: InboxCoordinator!

    init(root: URL, dropWindow: TimeInterval = 120, failureDwell: TimeInterval = 5) {
        self.root = root
        coordinator = InboxCoordinator(
            root: root,
            capture: { [weak self] in
                guard let self else { throw InboxCapture.Failure.nothingCopied }
                self.callOrder.append("capture")
                if self.captureDelay > .zero {
                    try? await Task.sleep(for: self.captureDelay)
                }
                if !self.textQueue.isEmpty {
                    return try self.textQueue.removeFirst().get()
                }
                return try self.text.get()
            },
            readSource: { [weak self] in
                self?.callOrder.append("source")
                return self?.source ?? InboxSource(appName: nil, bundleID: nil, url: nil)
            },
            now: { noon },
            dropWindow: dropWindow,
            failureDwell: failureDwell,
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

// The source is read after the text is captured, never before: `FrontmostSource.read()` can
// raise the macOS automation consent dialog on a browser's first ask, and answering that dialog
// moves focus away from whatever the Cmd+C was meant to reach. Pinned here so a future "tidy
// this up" cannot swap the two calls back without a test noticing.
@MainActor
@Test func theSourceIsReadAfterTheCaptureNotBefore() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)

    await harness.capture()

    #expect(harness.callOrder == ["capture", "source"])
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
        Issue.record("the panel should have named the cause: \(harness.shown)")
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

// `captureRequested()`'s doc comment says a second request is ignored while one is in flight,
// not cancelled: cancelling cannot undo a Cmd+C already sent, so a second fn+C pressed a
// fraction of a second after the first must do nothing rather than start a competing attempt.
// This pins that down: two hotkeys close together still produce exactly one folder, one
// `.captured`, one `.done`.
@MainActor
@Test func aSecondHotkeyWhileACaptureIsInFlightIsIgnored() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    harness.captureDelay = .milliseconds(50)

    harness.coordinator.captureRequested()
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    #expect(harness.folders.count == 1)
    #expect(harness.shown.count == 1)
    if case .captured = harness.shown.first {} else {
        Issue.record("expected a single .captured from the one capture that ran: \(harness.shown)")
    }
    #expect(harness.sounds == [.done])
}

// The second press is ignored outright, not queued behind the first: if the one attempt that
// runs fails, no second attempt should have started at all. `textQueue` holds only one answer —
// a failure — while `text` defaults to success, so a wrongly-started second attempt would show
// up unmistakably as a folder and a `.captured` that should not exist.
@MainActor
@Test func aSecondHotkeyDuringAFailingCaptureStartsNoSecondAttempt() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root)
    harness.captureDelay = .milliseconds(50)
    harness.textQueue = [.failure(InboxCapture.Failure.nothingCopied)]

    harness.coordinator.captureRequested()
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    #expect(harness.folders.isEmpty)
    #expect(harness.sounds == [.error])
    let failureCount = harness.shown.filter { if case .failure = $0 { true } else { false } }.count
    #expect(failureCount == 1)
    let capturedCount = harness.shown.filter { if case .captured = $0 { true } else { false } }.count
    #expect(capturedCount == 0)
}

// A drop is a promise of more time, not just of a copied file: the design lets a file dropped at
// the end of the window buy another one for the next file beside it.
//
// Margins are wide (a 500 ms window, not the 50 ms other tests use) because this one, unlike
// `aDropAfterTheTargetClosedIsRefused`, has to land the second drop inside a narrow band — past
// the original window's expiry, short of the re-armed one — rather than merely after both. The
// first drop sits near the end of the original window (400 of 500 ms) rather than in its middle,
// so the band the second drop must land in is (500, 900) around a 650 ms target: 150 ms of margin
// below, 250 ms above. Only the upper margin is fragile — a `Task.sleep` overshoot under load
// pushes the second drop past the re-armed expiry — so that is the number that may not shrink;
// the lower bound is self-correcting, since a late first sleep delays the re-arm by the same
// amount it delays the first drop.
@MainActor
@Test func aSuccessfulDropRearmsTheTargetsOwnExpiry() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root, dropWindow: 0.5)
    await harness.capture()

    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }

    try await Task.sleep(for: .milliseconds(400))
    let first = elsewhere.appendingPathComponent("первый.txt")
    try "данные".write(to: first, atomically: true, encoding: .utf8)
    #expect(harness.coordinator.drop([first]))

    // Cumulative 650 ms: past the original 500 ms window, but the drop above re-armed it for
    // another 500 ms starting from its own moment (400 + 500 = 900 ms).
    try await Task.sleep(for: .milliseconds(250))
    let second = elsewhere.appendingPathComponent("второй.txt")
    try "данные".write(to: second, atomically: true, encoding: .utf8)
    #expect(harness.coordinator.drop([second]))

    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("первый.txt").path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("второй.txt").path))
}

// The owner said they were done: the strip goes at once and the folder stops taking files.
// Anything dropped after that has nowhere to go, and the panel must not pretend otherwise.
@MainActor
@Test func doneClosesTheWindowImmediately() async throws {
    let root = try temporaryRoot()
    let harness = Harness(root: root)
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    harness.coordinator.doneRequested()

    #expect(harness.hidden.last == 0)
    #expect(harness.coordinator.drop([root.appendingPathComponent("whatever.txt")]) == false)
}

// Ten minutes, not two: the timer stopped being the way this row ends and became the guard
// against a row nobody closed. It cannot be infinite — a strip that takes the mouse sits over
// the mute button of a full-screen call.
@MainActor
@Test func theDropWindowIsTenMinutes() {
    #expect(InboxCoordinator.dropWindow == 600)
}

// A drop still buys another full window: files arrive in batches, and the second batch must not
// find the target gone. What changed is that the window is no longer how this ends.
@MainActor
@Test func aDropKeepsTheWindowOpen() async throws {
    let root = try temporaryRoot()
    // The window is passed explicitly rather than left at the harness default of 120: this test
    // is about the drop re-arming whatever window it was given, and the harness default is not
    // the constant.
    let harness = Harness(root: root, dropWindow: 600)
    harness.coordinator.captureRequested()
    await harness.coordinator.settle()

    let file = root.appendingPathComponent("attachment.txt")
    try Data("x".utf8).write(to: file)
    #expect(harness.coordinator.drop([file]) == true)

    #expect(harness.hidden.last == 600)
}

// A refusal used to close the whole inbox row: `reportFailure` re-arms `hidePanel` for its own
// short dwell, and `PanelWindow.hideInbox` cancels whatever hide was pending — including the
// two-minute one a successful capture had just armed. The spec promises two minutes and `target`
// still agrees; only the panel disagreed, and the owner could no longer see anywhere to drop a
// file even though `target` was still open. Once the failure has been read, the row has to come
// back with whatever is left of its own window.
@MainActor
@Test func aFailureDuringTheDropWindowLeavesTheTargetReachableAfterItsDwell() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = Harness(root: root, dropWindow: 0.4, failureDwell: 0.05)
    await harness.capture()

    harness.text = .failure(InboxCapture.Failure.nothingCopied)
    await harness.capture()

    // Past the failure's own dwell, short of the drop window's.
    try await Task.sleep(for: .milliseconds(120))

    #expect(harness.shown.last == .captured(app: "Telegram", lines: 2, attachments: 0))

    let elsewhere = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let file = elsewhere.appendingPathComponent("после-отказа.txt")
    try "данные".write(to: file, atomically: true, encoding: .utf8)

    #expect(harness.coordinator.drop([file]))
    let folder = root.appendingPathComponent(harness.folders[0])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("после-отказа.txt").path))
}
