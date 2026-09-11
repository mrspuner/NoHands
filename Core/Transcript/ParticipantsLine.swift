import Foundation

/// The `participants:` line of a meeting file — read, rewritten, and used to rename labels.
///
/// This is the one line of the archive the owner is expected to edit, so everything here works
/// on the text of the file rather than on a parsed model of it: the file is the archive, it
/// outlives every process, and rewriting it from parsed values would quietly discard whatever
/// else was typed into it.
public enum ParticipantsLine {
    public static let key = "participants:"

    /// - Returns: the names, or `nil` when the file has no such line at all. An empty list is a
    ///   different answer from a missing line and is returned as an empty array.
    public static func parse(_ markdown: String) -> [String]? {
        guard let line = markdown.components(separatedBy: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(key)
        }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces).dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return split(String(trimmed.dropFirst().dropLast()))
    }

    public static func replace(in markdown: String, with participants: [String]) -> String {
        let rendered = key + " [" + participants.map(Frontmatter.listValue).joined(separator: ", ") + "]"
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(key)
        }) else { return markdown }
        lines[index] = rendered
        return lines.joined(separator: "\n")
    }

    /// Renames the label of every reply that carries it, and touches nothing else.
    ///
    /// A label is what stands between `] ` and the first colon of a reply line — the same shape
    /// `TranscriptIndex` parses. The text after that colon is left alone even when it contains
    /// the old name, because the owner writes in that text and the archive is not ours to edit.
    public static func rename(in markdown: String, from old: String, to new: String) -> String {
        markdown.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
            let rest = line[line.index(after: close)...]
            let leading = rest.prefix { $0 == " " }
            let body = rest.dropFirst(leading.count)
            guard let colon = body.firstIndex(of: ":") else { return line }
            guard String(body[..<colon]) == old else { return line }
            return String(line[...close]) + leading + new + String(body[colon...])
        }.joined(separator: "\n")
    }

    /// Splits on commas that are not inside quotes, and unquotes what `Frontmatter.listValue`
    /// quoted on the way out.
    private static func split(_ body: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quoted:
                escaped = true
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !values.isEmpty { values.append(last) }
        return values.filter { !$0.isEmpty }
    }
}
