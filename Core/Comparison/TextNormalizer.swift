import Foundation

/// Reduces text to a bare sequence of words so that two transcripts can be compared
/// without drowning in differences nobody cares about: casing, punctuation, "ё" versus "е".
public enum TextNormalizer {
    public static func words(from text: String) -> [String] {
        let folded = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")

        let separated = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }

        return String(separated)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
