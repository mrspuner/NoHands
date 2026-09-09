import AppKit
import Foundation
import Testing
@testable import Inbox

// Never `NSPasteboard.general`: a test suite that borrows the owner's clipboard is a test suite
// that loses it. The seam that makes this reachable at all is `postCopy` — the real one presses
// Cmd+C, and no test may do that to whatever window happens to have focus.
private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("nohands-inbox-test-\(UUID().uuidString)"))
}

@MainActor
@Test func theCopiedTextComesBackAndTheClipboardIsPutBack() async throws {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        pasteboard.setString("> Натали:\nвыделенное", forType: .string)
    }

    #expect(try await capture.selection(from: pasteboard) == "> Натали:\nвыделенное")
    #expect(pasteboard.string(forType: .string) == "что было")
}

// The exact race the wait exists for: `clearContents()` bumps the change counter on its own, and
// the application under us writes the data a moment later. A capture that stopped at the counter
// would come back empty whenever the poll landed inside that gap.
@MainActor
@Test func theTextIsWaitedForEvenWhenTheCounterMovesFirst() async throws {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            pasteboard.setString("догнало", forType: .string)
        }
    }

    #expect(try await capture.selection(from: pasteboard) == "догнало")
    #expect(pasteboard.string(forType: .string) == "что было")
}

// Nothing selected, or an application that does not answer Cmd+C. Named refusal, and — checked
// by the coordinator's own tests — no folder: an empty folder looks exactly like a capture that
// happened, and this one did not.
@MainActor
@Test func aCopyThatChangesNothingIsARefusal() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {}

    await #expect(throws: InboxCapture.Failure.nothingCopied) {
        try await capture.selection(from: pasteboard)
    }
    #expect(pasteboard.string(forType: .string) == "что было")
}

@MainActor
@Test func copyingNothingButWhitespaceIsAlsoARefusalAndTheClipboardComesBack() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let capture = InboxCapture {
        pasteboard.clearContents()
        pasteboard.setString("   \n  ", forType: .string)
    }

    await #expect(throws: InboxCapture.Failure.nothingCopied) {
        try await capture.selection(from: pasteboard)
    }
    #expect(pasteboard.string(forType: .string) == "что было")
}

@MainActor
@Test func aFailureToPressTheKeysIsReportedAsItself() async {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    let capture = InboxCapture { throw InboxCapture.Failure.eventSourceUnavailable }

    await #expect(throws: InboxCapture.Failure.eventSourceUnavailable) {
        try await capture.selection(from: pasteboard)
    }
}
