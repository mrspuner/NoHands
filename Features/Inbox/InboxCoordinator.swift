import Foundation

/// Performs one capture and holds its folder open for attachments.
///
/// Everything system-facing arrives as a closure — the keystroke, the frontmost application, the
/// panel, the clock — for the same reason `DictationCoordinator` takes the panel that way: the
/// rules are worth testing and the system calls are not reachable from a test.
@MainActor
public final class InboxCoordinator {
    public enum Sound: Equatable, Sendable {
        case done
        case error
    }

    /// How long the strip stays a target after a capture. Two minutes: long enough to find the
    /// file in Telegram, wait for it to download and drag it over; short enough that the strip
    /// is not taking the mouse over a full-screen call for the rest of the day.
    public static let dropWindow: TimeInterval = 120
    /// A refusal is read, not answered.
    public static let failureDwell: TimeInterval = 5

    private let root: URL
    private let capture: @MainActor () async throws -> String
    private let readSource: @MainActor () -> InboxSource
    private let now: () -> Date
    private let dropWindow: TimeInterval
    private let showPanel: (InboxPanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let play: (Sound) -> Void

    /// The folder of the last capture, for as long as files may still be dropped on it, plus
    /// what the panel is currently saying about it. Cleared by `expiry` rather than by the panel
    /// collapsing: the two clocks are the same length, but only one of them belongs here.
    private var target: URL?
    private var attachments = 0
    private var lines = 0
    private var appName: String?
    private var expiry: DispatchWorkItem?
    private var work: Task<Void, Never>?

    public init(
        root: URL = InboxFolder.rootURL,
        capture: @escaping @MainActor () async throws -> String
            = { try await InboxCapture().selection() },
        readSource: @escaping @MainActor () -> InboxSource = { FrontmostSource.read() },
        now: @escaping () -> Date = Date.init,
        dropWindow: TimeInterval = InboxCoordinator.dropWindow,
        showPanel: @escaping (InboxPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        play: @escaping (Sound) -> Void
    ) {
        self.root = root
        self.capture = capture
        self.readSource = readSource
        self.now = now
        self.dropWindow = dropWindow
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.play = play
    }

    /// fn+C. The previous capture's task is cancelled rather than queued behind: two hotkeys in
    /// a row mean the owner wants the second selection, and the first is already history.
    public func captureRequested() {
        work?.cancel()
        work = Task { [weak self] in await self?.perform() }
    }

    /// Waits for the capture in flight. Internal rather than public: it exists for the tests,
    /// which have to see the folder after the task that writes it, and `@testable` is enough.
    func settle() async {
        await work?.value
    }

    private func perform() async {
        var createdFolder: URL?
        do {
            // Capture before asking who is frontmost — not the other way round. `readSource()`
            // may ask a browser for its address over AppleScript, and the very first such ask
            // raises the macOS automation consent dialog. That dialog blocks the main actor until
            // it is answered, and answering it moves focus: a Cmd+C sent afterwards would land on
            // whatever ended up frontmost, not on what the owner was looking at when fn+C was
            // pressed. Capturing first keeps the dialog off the one step that has to hit the
            // right window. Do not reorder this back — it looks tidier the other way and it is
            // the reason the first capture from a browser used to be silently wrong.
            //
            // This does not make a wedged browser harmless: `readSource()` below can still block
            // the main actor for as long as the dialog, or an unresponsive AppleScript target,
            // takes to answer — only now after the text is already safe. The known remedy is
            // running `osascript` as a subprocess with a timeout, the way `MLXSummaryRunner` runs
            // its model subprocess; that is separate work, out of scope here.
            let text = try await capture()
            let at = now()
            let source = readSource()

            // Cancellation is cooperative: `Task.cancel()` alone does not stop work already in
            // flight, and `InboxCapture.selection()`'s own wait loop swallows the resulting
            // `CancellationError`. This is the one place after the only suspension point that can
            // still honour it before any side effect happens — a superseded capture must be
            // silent, so it returns rather than falling through to create a folder, touch state,
            // or play anything.
            guard !Task.isCancelled else { return }

            let folder = try InboxFolder.create(in: root, capturedAt: at, slug: source.slug)
            createdFolder = folder
            let note = InboxNote.render(
                capturedAt: at,
                appName: source.appName,
                bundleID: source.bundleID,
                url: source.url,
                text: text
            )
            try note.write(
                to: folder.appendingPathComponent(InboxNote.fileName),
                atomically: true,
                encoding: .utf8
            )
            target = folder
            attachments = 0
            lines = InboxNote.lineCount(text)
            appName = source.appName
            play(.done)
            announce()
        } catch {
            // Nothing is left behind on the way out. The folder is made only once there is text
            // to put in it; if it was created but the write after it failed, remove it here too
            // — `target` is not set until after the write succeeds, so no dropped file can have
            // landed inside it yet, which is what makes the removal safe. An empty folder would
            // look exactly like a capture that happened.
            //
            // Cleanup stays unconditional — it is about the disk, and this attempt owns whatever
            // it left there regardless of who won the race. Reporting is about the panel, and
            // belongs only to the attempt that is still current: a cancelled first capture whose
            // `capture()` throws (`nothingCopied` is the ordinary case — two quick fn+C presses,
            // the first with nothing selected) must not flash `.failure` over a second capture
            // that has already shown `.captured` and armed its own dwell.
            if let createdFolder {
                try? FileManager.default.removeItem(at: createdFolder)
            }
            guard !Task.isCancelled else { return }
            reportFailure(error)
        }
    }

    /// - Returns: false when there is nothing to attach to, so the panel can leave the drag to
    ///   whoever else wants it rather than swallowing it.
    @discardableResult
    public func drop(_ urls: [URL]) -> Bool {
        guard let folder = target, !urls.isEmpty else { return false }
        do {
            for url in urls {
                try InboxFolder.copyAttachment(url, into: folder)
                attachments += 1
            }
            play(.done)
        } catch {
            reportFailure(error)
            return true
        }
        announce()
        return true
    }

    /// Reports a refusal the same way regardless of which step it broke in: sound, panel, dwell.
    private func reportFailure(_ error: Error) {
        play(.error)
        showPanel(.failure(error.localizedDescription))
        hidePanel(Self.failureDwell)
    }

    /// Shows the strip and re-arms both clocks — the panel's and the target's — so a file
    /// dropped at the end of the window buys another one for the next file beside it.
    private func announce() {
        showPanel(.captured(app: appName, lines: lines, attachments: attachments))
        hidePanel(dropWindow)
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.target = nil }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dropWindow, execute: work)
    }
}
