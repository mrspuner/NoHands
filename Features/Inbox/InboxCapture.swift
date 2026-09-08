import AppKit
import ApplicationServices
import Core
import CoreGraphics
import Foundation

/// Reads the current selection the only way the sources allow: by pressing Cmd+C for the owner.
///
/// The spike of 7 September established there is no cheaper path. Telegram selects *messages*,
/// not text inside a field, so the system Services — which work on a text selection — never see
/// anything to act on. The clipboard is borrowed and given back exactly the way `TextInserter`
/// borrows it to paste.
@MainActor
public struct InboxCapture {
    public enum Failure: Error, Equatable, LocalizedError {
        case accessibilityDenied
        case eventSourceUnavailable
        case nothingCopied

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is not granted, so the selection cannot be copied"
            case .eventSourceUnavailable:
                return "Could not synthesize the copy keystroke"
            case .nothingCopied:
                return "Nothing was selected, or the application did not answer Cmd+C"
            }
        }
    }

    /// How often the clipboard is asked whether it has changed, and how long that goes on.
    /// The application under us reads the selection and writes it asynchronously, so there is
    /// nothing to wait on except the change counter itself.
    private static let pollInterval = Duration.milliseconds(10)
    private static let limit = Duration.milliseconds(400)

    private let postCopy: @MainActor () throws -> Void

    /// The keystroke is injected rather than called directly so the whole rule above it — wait,
    /// read, put the clipboard back, refuse when nothing arrived — is testable without pressing
    /// Cmd+C into whatever window happens to have focus.
    public init(postCopy: @escaping @MainActor () throws -> Void = InboxCapture.pressCommandC) {
        self.postCopy = postCopy
    }

    public func selection(from pasteboard: NSPasteboard = .general) async throws -> String {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        try postCopy()

        // Polled on the text, not on the counter. `clearContents()` bumps the change counter by
        // itself and the application under us writes the data a moment afterwards, so a wait
        // that stopped at the counter would come back empty roughly whenever the ten-millisecond
        // tick landed inside that gap. Checked before the first sleep, so the ordinary case
        // costs nothing.
        var waited = Duration.zero
        var copied: String?
        while waited < Self.limit {
            if pasteboard.changeCount != before,
               let text = pasteboard.string(forType: .string),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copied = text
                break
            }
            try? await Task.sleep(for: Self.pollInterval)
            waited += Self.pollInterval
        }

        // Nothing was written at all, so there is nothing to put back either: the clipboard was
        // never touched. Refusing here rather than returning an empty string is the rule the
        // rest of the project lives by — a named failure instead of a silent fallback.
        guard pasteboard.changeCount != before else { throw Failure.nothingCopied }

        // Unguarded, unlike the paste: `TextInserter` waits 300 ms for the receiving application
        // to read the pasteboard, and `shouldRestore` is what keeps it from overwriting a copy
        // the owner made inside that window. Here the read and the restore are two statements
        // with no suspension between them, so there is no window to guard.
        snapshot.restore(to: pasteboard)

        guard let copied else { throw Failure.nothingCopied }
        return copied
    }

    public static func pressCommandC() throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
        /// `kVK_ANSI_C`
        let cKeyCode: CGKeyCode = 8
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else {
            throw Failure.eventSourceUnavailable
        }
        // Assigned, never merged — and here that is not the same caution `TextInserter` takes
        // against a stray Shift. fn is *physically held* at this instant: it is what produced
        // the hotkey. An event carrying it would reach the application underneath as fn+Cmd+C,
        // which is a different command or none at all.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
