import Foundation

/// Turns a dictation into one line short enough to read from a menu.
///
/// Two rules, both learned from what dictated text actually looks like: it contains newlines
/// once cleanup has punctuated it, and a newline inside an `NSMenuItem` title breaks the row's
/// layout; and a cut that lands mid-phrase can leave a trailing space before the ellipsis,
/// which reads as a typo rather than as a truncation.
public enum MenuTitle {
    public static func short(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return flat.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
