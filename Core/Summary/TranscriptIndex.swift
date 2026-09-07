import Foundation

/// Normalisation shared by the transcript and by the quotes checked against it.
///
/// Both sides must be folded the same way or the comparison measures the folding instead of the
/// text: `ё`/`е` alone splits half the Russian vocabulary in two.
public enum SummaryText {
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased().replacingOccurrences(of: "ё", with: "е") {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// The meeting file read back into the replies phase 2б wrote.
///
/// Parsed rather than kept alongside: the file is the archive, it outlives every process, and
/// the owner edits it by hand. Anything derived from it has to be derived from the file itself.
public struct TranscriptIndex: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var timecode: TimeInterval
        public var speaker: String
        public var text: String

        public init(timecode: TimeInterval, speaker: String, text: String) {
            self.timecode = timecode
            self.speaker = speaker
            self.text = text
        }
    }

    /// One normalised word plus the reply it came from. The quote search runs over this array,
    /// so a match immediately knows its timecode.
    public struct IndexedWord: Equatable, Sendable {
        public var word: String
        public var line: Int
    }

    public static let heading = "## Транскрипт"

    public var lines: [Line]
    public var words: [IndexedWord]
    /// The transcript exactly as the model gets it: reply lines, nothing above them.
    public var body: String

    public static func parse(_ markdown: String) -> TranscriptIndex {
        let all = markdown.components(separatedBy: "\n")
        guard
            let headingIndex = all.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == heading
            })
        else { return TranscriptIndex(lines: [], words: [], body: "") }

        var lines: [Line] = []
        var body: [String] = []
        for raw in all[all.index(after: headingIndex)...] {
            guard let line = parseLine(raw) else { continue }
            lines.append(line)
            body.append(raw)
        }

        var words: [IndexedWord] = []
        for (number, line) in lines.enumerated() {
            for word in SummaryText.words(line.text) {
                words.append(IndexedWord(word: word, line: number))
            }
        }
        return TranscriptIndex(lines: lines, words: words, body: body.joined(separator: "\n"))
    }

    /// `[00:03:12] Я: текст`. Anything else is not a reply — a blank line, a heading a later
    /// phase adds, or a note the owner left in the file.
    private static func parseLine(_ raw: String) -> Line? {
        guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
        let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
        guard stamp.count == 3,
            let hours = Int(stamp[0]), let minutes = Int(stamp[1]), let seconds = Int(stamp[2])
        else { return nil }
        let rest = raw[raw.index(after: close)...].drop { $0 == " " }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return Line(
            timecode: TimeInterval(hours * 3600 + minutes * 60 + seconds),
            speaker: String(rest[..<colon]).trimmingCharacters(in: .whitespaces),
            text: String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        )
    }
}
