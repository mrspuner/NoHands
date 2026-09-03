import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Puts dictated text wherever focus is right now: pasteboard, Cmd+V, pasteboard back.
@MainActor
public struct TextInserter: Sendable {
    public enum InsertionError: Error, Equatable, LocalizedError {
        case accessibilityDenied
        case eventSourceUnavailable

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is not granted, so the text cannot be pasted; " +
                    "it is on the clipboard — paste it with Cmd+V"
            case .eventSourceUnavailable:
                return "Could not synthesize the paste keystroke; the text is on the clipboard — " +
                    "paste it with Cmd+V"
            }
        }
    }

    /// `kVK_ANSI_V`
    private static let vKeyCode: CGKeyCode = 9
    /// How long the receiving application is given to read the pasteboard before the previous
    /// contents go back.
    private static let readDelay = Duration.milliseconds(300)

    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes into whatever has focus right now.
    ///
    /// There is no target to bring forward: the text goes where the owner is looking at the
    /// moment it lands, which is the rule as of 2026-09-03. Everything else about the paste is
    /// unchanged — the clipboard is borrowed and given back.
    public func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        copy(text)
        let written = pasteboard.changeCount

        // The text reaches the pasteboard before the permission is checked, and stays there if
        // the check fails. Without the permission nothing can be pasted anyway, and throwing
        // first would lose the dictation outright.
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityDenied }

        try postPaste()

        // The receiving application reads the pasteboard asynchronously, after the keystroke.
        // Putting the old contents back on the next line pastes the old contents instead.
        try? await Task.sleep(for: Self.readDelay)
        if PasteboardSnapshot.shouldRestore(
            writtenChangeCount: written, currentChangeCount: pasteboard.changeCount
        ) {
            snapshot.restore(to: pasteboard)
        }
    }

    private func postPaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            throw InsertionError.eventSourceUnavailable
        }
        // Assigned, not merged: whatever the owner still happens to be holding — Shift, Option —
        // would otherwise ride along and turn Cmd+V into a different command.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
