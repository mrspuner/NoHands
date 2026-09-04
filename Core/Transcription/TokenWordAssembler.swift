import FluidAudio
import Foundation

/// Turns Parakeet's subword tokens into whole words.
///
/// Lives next to the transcriber rather than with `TimedWord` because this is the one place
/// that knows FluidAudio's token conventions. `TimedWord` itself stays free of the library.
///
/// FluidAudio has the same assembly internally (`VocabularyRescorer.buildWordTimings`) but does
/// not export it, so this is a deliberate twenty-line copy of a rule, not a duplicated
/// implementation of an algorithm.
public enum TokenWordAssembler {
    /// The decoder's own markers. They carry timings like any other token and would otherwise
    /// become words made of angle brackets.
    static let ignoredTokens: Set<String> = ["<blank>", "<pad>"]

    /// SentencePiece's word boundary. `AsrManager.normalizedTimingToken` replaces it with a
    /// plain space before the timing leaves the library, so in practice tokens arrive
    /// space-prefixed — both forms are accepted because relying on that replacement staying in
    /// place costs nothing to avoid.
    static let boundaryMarker = "\u{2581}"

    public static func words(from timings: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidenceSum: Float = 0
        var pieces = 0

        func flush() {
            defer {
                text = ""
                confidenceSum = 0
                pieces = 0
            }
            guard pieces > 0 else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(
                TimedWord(
                    text: trimmed,
                    start: start,
                    end: end,
                    confidence: confidenceSum / Float(pieces)
                )
            )
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || ignoredTokens.contains(token) { continue }
            if token.hasPrefix(" ") || token.hasPrefix(boundaryMarker) { flush() }
            if pieces == 0 { start = timing.startTime }
            text += token.replacingOccurrences(of: boundaryMarker, with: " ")
            end = timing.endTime
            confidenceSum += timing.confidence
            pieces += 1
        }
        flush()
        return words
    }
}
