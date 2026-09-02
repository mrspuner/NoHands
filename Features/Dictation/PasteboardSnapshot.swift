import AppKit
import Foundation

/// What was in the pasteboard before dictation borrowed it.
///
/// Pasting through the pasteboard is more reliable than synthesizing the text keystroke by
/// keystroke, especially in Cyrillic — but it means taking something that belongs to the owner
/// and putting it back afterwards, exactly as it was, including the types that are not text.
public struct PasteboardSnapshot: Equatable, Sendable {
    private let items: [[String: Data]]

    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    stored[type.rawValue] = data
                }
            }
            return stored
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Only put the old contents back if nothing else has written since. A copy that happened
    /// in the window between the paste and the restore belongs to the owner, not to us.
    public static func shouldRestore(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
        writtenChangeCount == currentChangeCount
    }
}
