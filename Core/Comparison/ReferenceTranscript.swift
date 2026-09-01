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

    public static func spokenText(from raw: String) -> String {
        raw
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                guard let match = timestampPattern.firstMatch(in: trimmed, range: range),
                      let matchRange = Range(match.range, in: trimmed)
                else {
                    return nil
                }
                let speech = String(trimmed[matchRange.upperBound...])
                return speech.isEmpty ? nil : speech
            }
            .joined(separator: " ")
    }
}
