import AppKit
import Foundation

/// Puts dictated text where it was aimed.
///
/// In this task it only reaches the pasteboard; `insert(_:into:)` — activation, Cmd+V and
/// putting the pasteboard back — arrives with the accessibility work in the next task.
@MainActor
public struct TextInserter {
    public init() {}

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
