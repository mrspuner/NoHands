import AppKit
import Foundation
import Testing
@testable import Dictation

private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("nohands-test-\(UUID().uuidString)"))
}

@MainActor
@Test func snapshotRestoresAString() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("что было", forType: .string)

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.string(forType: .string) == "что было")
}

// The owner may have copied something that is not text at all. Restoring only the string would
// quietly destroy it.
@MainActor
@Test func snapshotRestoresNonTextTypesToo() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    let type = NSPasteboard.PasteboardType("com.nohands.test")
    pasteboard.clearContents()
    pasteboard.setData(Data([1, 2, 3]), forType: type)

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.data(forType: type) == Data([1, 2, 3]))
}

@MainActor
@Test func emptyPasteboardRestoresAsEmpty() {
    let pasteboard = scratchPasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()

    let snapshot = PasteboardSnapshot.capture(pasteboard)
    pasteboard.setString("что вставили", forType: .string)
    snapshot.restore(to: pasteboard)

    #expect(pasteboard.string(forType: .string) == nil)
}

@Test func restoreHappensWhenNobodyElseWrote() {
    #expect(PasteboardSnapshot.shouldRestore(writtenChangeCount: 7, currentChangeCount: 7))
}

// Somebody copied something in the moment between the paste and the restore. Putting the old
// contents back now would throw away what they just copied.
@Test func restoreIsSkippedWhenSomebodyElseWrote() {
    #expect(!PasteboardSnapshot.shouldRestore(writtenChangeCount: 7, currentChangeCount: 8))
}
