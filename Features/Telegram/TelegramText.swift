import Foundation

/// Converts BigHead's markdown into the HTML subset Telegram accepts and splits it into messages.
public enum TelegramText {
    /// `& < >` are escaped first, so everything below works on already-safe text.
    /// Supported: `**bold**`, `` `code` ``, `[[link]]` (brackets dropped), `# heading` (bold line).
    public static func html(fromMarkdown markdown: String) -> String {
        var text = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        text = text.replacingOccurrences(
            of: #"(?m)^#+[ \t]+(.+?)[ \t]*$"#, with: "<b>$1</b>", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"`([^`\n]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\[\[(.+?)\]\]"#, with: "$1", options: .regularExpression)
        return text
    }

    /// Splits at paragraph boundaries (`\n\n`); an oversized paragraph is split by lines, an oversized
    /// line by characters. Length is counted in Swift `Character`s, not Telegram's UTF-16 count after
    /// parsing, so callers pass `TelegramBot.partLimit` (4000), kept below Telegram's 4096 as margin.
    public static func chunks(_ html: String, limit: Int) -> [String] {
        precondition(limit > 0)
        var result: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { result.append(current); current = "" }
        }
        func add(_ piece: String, separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= limit {
                current += separator + piece
            } else {
                flush()
                current = piece
            }
        }

        for paragraph in html.components(separatedBy: "\n\n") {
            if paragraph.count <= limit {
                add(paragraph, separator: "\n\n")
                continue
            }
            flush()
            for line in paragraph.components(separatedBy: "\n") {
                if line.count <= limit {
                    add(line, separator: "\n")
                } else {
                    flush()
                    result.append(contentsOf: hardSplit(line, limit: limit))
                }
            }
            flush()
        }
        flush()
        return result
    }

    /// Cuts by characters, but never inside an `&…;` entity or a `<…>` tag.
    private static func hardSplit(_ line: String, limit: Int) -> [String] {
        var rest = Array(line)
        var parts: [String] = []
        while rest.count > limit {
            var cut = limit
            let head = rest[0..<limit]
            for (open, close) in [(Character("&"), Character(";")), (Character("<"), Character(">"))] {
                if let i = head.lastIndex(of: open), !head[i...].contains(close), i > 0 {
                    cut = min(cut, i)
                }
            }
            parts.append(String(rest[0..<cut]))
            rest.removeFirst(cut)
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    /// Cuts the `<!-- кнопки … -->` block out of the markdown; each non-empty line inside is a button.
    public static func extractButtons(_ markdown: String) -> (body: String, buttons: [String]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<!--[ \t]*кнопки[ \t]*\n(.*?)-->"#, options: [.dotMatchesLineSeparators]),
            let match = regex.firstMatch(
                in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
            let whole = Range(match.range, in: markdown),
            let inner = Range(match.range(at: 1), in: markdown)
        else {
            return (markdown, [])
        }
        let buttons = markdown[inner]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var body = markdown
        body.removeSubrange(whole)
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), buttons)
    }
}
