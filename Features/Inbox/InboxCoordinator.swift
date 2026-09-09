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

    /// How long the strip stays a target when nobody closes it. Thirty seconds, and it is a
    /// backstop rather than the way this ends: the owner closes the row with «Готово» the moment
    /// everything is brought over. It cannot be long — the row draws over the meeting layer
    /// beneath it, so a wide window here is a start-of-call or end-of-call prompt with nothing
    /// left to answer it: fn+C at the start of a meeting used to be able to swallow both the
    /// start prompt and the stop prompt whole, for the ten minutes this used to be. Thirty
    /// seconds keeps this a backstop rather than a second timer competing with those two.
    public static let dropWindow: TimeInterval = 30
    /// A refusal is read, not answered.
    public static let failureDwell: TimeInterval = 5

    private let root: URL
    private let capture: @MainActor () async throws -> String
    private let readSource: @MainActor () -> InboxSource
    private let now: () -> Date
    private let dropWindow: TimeInterval
    private let failureDwell: TimeInterval
    private let showPanel: (InboxPanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let play: (Sound) -> Void

    /// The folder of the last capture, for as long as files may still be dropped on it, plus
    /// what the panel is currently saying about it. Cleared by `expiry` rather than by the panel
    /// collapsing: the two clocks are the same length, but only one of them belongs here.
    private var target: URL?
    /// When the current `target`'s drop window runs out — the real wall clock, not the injected
    /// `now`, because this is compared against as time actually passes while the app runs, the
    /// same way `expiry` below is already scheduled against the real clock rather than `now`.
    /// Read back by `reportFailure` to decide whether the row a failure just hid is still worth
    /// bringing back.
    private var targetExpiresAt: Date?
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
        failureDwell: TimeInterval = InboxCoordinator.failureDwell,
        showPanel: @escaping (InboxPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        play: @escaping (Sound) -> Void
    ) {
        self.root = root
        self.capture = capture
        self.readSource = readSource
        self.now = now
        self.dropWindow = dropWindow
        self.failureDwell = failureDwell
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.play = play
    }

    /// fn+C. A capture already in flight ignores a new request rather than being cancelled —
    /// only one borrow of the pasteboard at a time.
    ///
    /// `Task.cancel()` cannot undo a Cmd+C already posted to the foreground application: the
    /// cancelled task's own `Task.sleep` calls throw and are swallowed by `try?`, so it races to
    /// the end of its wait loop and gives up in microseconds, but the application under us still
    /// answers the keystroke eventually. A second capture started in the meantime borrows the
    /// same pasteboard again, and when the first capture's belated answer to Cmd+C #1 lands, the
    /// second capture reads it as its own selection and restores the snapshot from under it — the
    /// clipboard is then left holding the captured text permanently, with nothing left to give it
    /// back. Ignoring the second request avoids the double borrow instead of racing to undo it.
    ///
    /// The cost is silent and small: a second fn+C pressed while the first is still out does
    /// nothing at all, not even a sound. That is a debounce, not a failure — the whole capture
    /// takes a fraction of a second, and the panel row for the one that ran appears right after.
    public func captureRequested() {
        guard work == nil else { return }
        work = Task { [weak self] in
            await self?.perform()
            self?.work = nil
        }
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
            // Reporting is unconditional too, unlike before: captures no longer race each other
            // — `captureRequested()` ignores a new request while one is in flight — so whichever
            // attempt is running here is always the current one, and its failure is always worth
            // telling the panel about.
            if let createdFolder {
                try? FileManager.default.removeItem(at: createdFolder)
            }
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
            // Whatever copied before the failure is real and the count is not lost — `attachments`
            // already includes it — so the panel is told about it before it is told why the rest
            // did not arrive, rather than the successful ones vanishing behind the failure message.
            announce()
            reportFailure(error)
            return true
        }
        announce()
        return true
    }

    /// «Готово» on the panel. Closes both the row and the folder it was pointing at.
    ///
    /// Nothing is undone and nothing is deleted: the capture and every file already dropped on
    /// it stay where they are. This says only that no more files are coming.
    public func doneRequested() {
        expiry?.cancel()
        expiry = nil
        target = nil
        targetExpiresAt = nil
        hidePanel(0)
    }

    /// Reports a refusal the same way regardless of which step it broke in: sound, panel, dwell.
    ///
    /// `hidePanel` collapses the whole inbox row on this dwell — it does not know there might be
    /// a drop target underneath still good for another thirty seconds. `target` and
    /// `targetExpiresAt` are untouched here, so once the failure has been read, the row is worth
    /// bringing back with whatever time is actually left on the window a successful capture or
    /// drop already promised.
    private func reportFailure(_ error: Error) {
        play(.error)
        showPanel(.failure(error.localizedDescription))
        hidePanel(failureDwell)

        guard let failedTarget = target, targetExpiresAt != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + failureDwell) { [weak self] in
            // Read now, not captured above: «Готово» and a later drop both change what is left
            // on the window while this failure is being read, and a snapshot taken at the start
            // would bring the row back for a target that is already closed — or hide it early.
            guard let self, self.target == failedTarget,
                  let expiresAt = self.targetExpiresAt else { return }
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return }
            self.showPanel(.captured(app: self.appName, lines: self.lines, attachments: self.attachments))
            self.hidePanel(remaining)
        }
    }

    /// Shows the strip and re-arms both clocks — the panel's and the target's — so a file
    /// dropped at the end of the window buys another one for the next file beside it.
    private func announce() {
        showPanel(.captured(app: appName, lines: lines, attachments: attachments))
        hidePanel(dropWindow)
        expiry?.cancel()
        targetExpiresAt = Date().addingTimeInterval(dropWindow)
        let work = DispatchWorkItem { [weak self] in
            self?.target = nil
            self?.targetExpiresAt = nil
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dropWindow, execute: work)
    }
}
