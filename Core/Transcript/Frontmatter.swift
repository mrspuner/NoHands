import Foundation

/// Escaping for one value inside a YAML front matter line.
///
/// Written first for the display name of whatever application held the audio devices, and
/// pulled out here because the inbox writes the same kind of value into the same kind of block:
/// a name straight from `NSRunningApplication`, an address straight from a browser. One archive,
/// one escaping rule.
public enum Frontmatter {
    /// A colon or a newline in the value would break the `---` block for Obsidian and for
    /// anything that re-reads the file. Quoted and escaped rather than trusted — the archive
    /// outlives every assumption about what applications are called.
    public static func quoted(_ value: String) -> String {
        var cleaned = ""
        for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            cleaned.append(Character(scalar))
        }
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A value inside a `[a, b]` list. Quoted only when it has to be: a plain name reads better
    /// unquoted, and a name with a comma, a bracket, a quote, or a control character in it would
    /// otherwise break the list — or the `---` block itself, in the case of a raw newline — for
    /// everything that re-reads the file, including this application's own pass over the archive.
    ///
    /// Routed through `quoted` for the unsafe case, same as every other front-matter value.
    /// `quoted` *strips* control characters rather than escaping them, so a name containing one
    /// loses it on the round trip through this function too — that is `quoted`'s own design, not
    /// a bug to fix here.
    public static func listValue(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: ",[]\"\\:#").union(.controlCharacters)
        let plain = value.rangeOfCharacter(from: disallowed) == nil
            && !value.hasPrefix(" ") && !value.hasSuffix(" ") && !value.isEmpty
        return plain ? value : quoted(value)
    }
}
