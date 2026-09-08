import Core
import Foundation

/// The `note.md` of one captured item: front matter and the clipboard text.
///
/// The body is written byte for byte. Nothing is cleaned, normalised or parsed — the four
/// sources format their clipboard differently and will keep doing so, and a parser per source
/// would break on the first update of somebody else's application while buying nothing. What a
/// model says about this text at review time has to stay checkable against what was copied.
public enum InboxNote {
    public static let fileName = "note.md"

    public static func render(
        capturedAt: Date,
        appName: String?,
        bundleID: String?,
        url: String?,
        text: String
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("captured: \(format(capturedAt))")
        if let appName { lines.append("app: \(Frontmatter.quoted(appName))") }
        // Unquoted on purpose: a bundle identifier is issued by the system and cannot hold a
        // space, a colon or a newline. The display name right above it can hold all three.
        if let bundleID { lines.append("bundle: \(bundleID)") }
        if let url { lines.append("url: \(Frontmatter.quoted(url))") }
        lines.append("---")
        lines.append("")
        var out = lines.joined(separator: "\n") + "\n"
        out += text
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Lines of content, blank ones not counted: every one of the four sources separates
    /// messages with a blank line, so counting those would report the shape of the paste rather
    /// than how much was captured.
    public static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// Local time, matching `InboxFolder.baseName` and the meeting archive: read by a human who
    /// remembers when it happened.
    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
