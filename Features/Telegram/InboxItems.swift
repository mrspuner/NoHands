import Foundation

/// One thing in BigHead's `wiki/inbox.md` that is addressed to the owner.
public struct InboxItem: Equatable, Sendable {
    /// Stable identifier of the item: the block heading, or `Сбой: <line>` for a failure line.
    public let ref: String
    public let text: String

    public init(ref: String, text: String) {
        self.ref = ref
        self.text = text
    }
}

public enum InboxItems {
    /// `### ` blocks under `## Ждёт ответа` and non-empty lines under `## Сбои`, in file order.
    /// Anything outside those two sections is ignored.
    public static func parse(_ markdown: String) -> [InboxItem] {
        enum Section { case none, waiting, failures }
        var section = Section.none
        var items: [InboxItem] = []
        var block: (ref: String, lines: [String])?

        func flush() {
            guard let b = block else { return }
            let text = b.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(InboxItem(ref: b.ref, text: text))
            block = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                switch line.dropFirst(3).trimmingCharacters(in: .whitespaces) {
                case "Ждёт ответа": section = .waiting
                case "Сбои": section = .failures
                default: section = .none
                }
                continue
            }
            switch section {
            case .none:
                continue
            case .waiting:
                if line.hasPrefix("### ") {
                    flush()
                    let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                    block = (ref, [line])
                } else if block != nil {
                    block?.lines.append(line)
                }
            case .failures:
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { items.append(InboxItem(ref: "Сбой: \(text)", text: text)) }
            }
        }
        flush()
        return items
    }
}
