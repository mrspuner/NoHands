import Foundation

/// Asks the transcript whether a quote is really in it.
///
/// The measure is the longest **contiguous** run of the quote's words found in the transcript,
/// as a share of the quote's length. Measured on real material before it was chosen: quotes the
/// model gave under genuine decisions scored 65–100%, a fabricated decision 12%, a phrase from a
/// different meeting 14%, generic filler 18%. The share of words present anywhere in the text —
/// the metric phase 0 used — scored 0–40% on a *correct* summary and had to be abandoned.
///
/// What it cannot do: a real quote attached to the wrong decision passes. That happened twice in
/// five in the probe, which is why the timecode goes into the file next to the decision — the
/// owner checks the claim in a second, and no number can do that part.
public enum QuoteMatch {
    public struct Result: Equatable, Sendable {
        public var ratio: Double
        /// Index into `TranscriptIndex.lines` where the longest run starts.
        public var line: Int?
    }

    public static func find(quote: String, in index: TranscriptIndex) -> Result {
        let needle = SummaryText.words(quote)
        guard !needle.isEmpty, !index.words.isEmpty else { return Result(ratio: 0, line: nil) }

        // Positions by word, so extending a candidate run costs a lookup instead of a scan.
        var positions: [String: [Int]] = [:]
        for (position, indexed) in index.words.enumerated() {
            positions[indexed.word, default: []].append(position)
        }

        var bestLength = 0
        var bestPosition: Int?
        for start in needle.indices {
            for position in positions[needle[start]] ?? [] {
                var length = 0
                while start + length < needle.count,
                    position + length < index.words.count,
                    needle[start + length] == index.words[position + length].word {
                    length += 1
                }
                if length > bestLength {
                    bestLength = length
                    bestPosition = position
                }
            }
        }

        guard let bestPosition, bestLength > 0 else { return Result(ratio: 0, line: nil) }
        return Result(
            ratio: Double(bestLength) / Double(needle.count),
            line: index.words[bestPosition].line
        )
    }

    /// Keeps every decision and marks the ones that failed. Dropping them would decide for the
    /// owner on a measure that is admittedly coarse — a real agreement retold entirely in other
    /// words can fail — and a missing line in the archive cannot be noticed, while a marked one
    /// can.
    public static func check(
        _ decisions: [MeetingSummary.Decision],
        against index: TranscriptIndex,
        threshold: Double
    ) -> [CheckedDecision] {
        decisions.map { decision in
            let result = find(quote: decision.quote, in: index)
            let passed = result.ratio >= threshold
            return CheckedDecision(
                text: decision.text,
                ratio: result.ratio,
                timecode: passed ? result.line.map { index.lines[$0].timecode } : nil
            )
        }
    }

    /// The same check the decisions get. Kept as a second method rather than a generic one: the
    /// two results carry different fields, and a protocol to unify them would cost more than the
    /// six lines it saves.
    public static func check(
        tasks: [MeetingSummary.Task],
        against index: TranscriptIndex,
        threshold: Double
    ) -> [CheckedTask] {
        tasks.map { task in
            let result = find(quote: task.quote, in: index)
            let passed = result.ratio >= threshold
            return CheckedTask(
                text: task.text,
                owner: task.owner,
                due: task.due,
                ratio: result.ratio,
                timecode: passed ? result.line.map { index.lines[$0].timecode } : nil
            )
        }
    }
}
