import Foundation

/// Extracts what was actually said from a transcript produced by a third-party service.
///
/// The file interleaves a header, speaker labels such as "Иван Петров (голос 1):" and
/// timestamped lines. Only the timestamped lines carry speech, so keeping just those
/// drops everything else without a rule per element.
public enum ReferenceTranscript {
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^\[\d{1,2}:\d{2}:\d{2}\]\s*"#
    )

    /// Speech plus how much of the file it came from.
    ///
    /// The counts are the point: dropping lines is how this parser works, so a format it does
    /// not recognise — a wrapped line without its own timestamp, or `[ММ:СС]` in the first
    /// hour — shrinks the reference silently and moves the error rate for a reason that has
    /// nothing to do with either engine. Reporting both numbers makes that visible at a glance.
    public struct Parsed: Equatable, Sendable {
        /// Everything said, joined into one string.
        public let text: String
        /// Lines a timestamp was found on and speech taken from.
        public let spokenLines: Int
        /// Lines in the file with anything on them at all. Always larger than `spokenLines`:
        /// the header and the speaker labels are non-empty and legitimately dropped.
        public let nonEmptyLines: Int
    }

    public static func parse(_ raw: String) -> Parsed {
        var speech: [String] = []
        var nonEmptyLines = 0

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            nonEmptyLines += 1

            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = timestampPattern.firstMatch(in: trimmed, range: range),
                  let matchRange = Range(match.range, in: trimmed)
            else {
                continue
            }
            let said = String(trimmed[matchRange.upperBound...])
            guard !said.isEmpty else { continue }
            speech.append(said)
        }

        return Parsed(
            text: speech.joined(separator: " "),
            spokenLines: speech.count,
            nonEmptyLines: nonEmptyLines
        )
    }
}
