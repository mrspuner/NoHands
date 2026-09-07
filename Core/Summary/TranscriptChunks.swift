import Foundation

/// Cuts a transcript into pieces small enough for the model to hold at once.
///
/// Fifteen minutes is not a calculation. It is the length of the meeting that ran on the owner's
/// machine on 2026-09-07 and produced the best summary of that day — names, a condition and a
/// deadline — while the sixty-eight-minute meeting on the same prompt produced a table of
/// contents and, on the second attempt, was killed by the system for taking ten gigabytes.
///
/// Two limits are live at once and the first to trip wins: the span in seconds, and the number of
/// characters. The clock is what makes a chunk a coherent stretch of conversation; the character
/// budget is the guard for dense speech, where fifteen minutes can still overflow the model's
/// window.
public enum TranscriptChunks {
    /// - Returns: chunks in meeting order, each one whole reply lines joined by newlines, in the
    ///   same form they have in the meeting file. Concatenating them with newlines reproduces
    ///   `index.body` exactly — that is the property that guarantees nothing was dropped.
    public static func split(
        _ index: TranscriptIndex,
        maxSeconds: TimeInterval,
        maxCharacters: Int
    ) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentCharacters = 0
        var chunkStart: TimeInterval = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(current.joined(separator: "\n"))
            current = []
            currentCharacters = 0
        }

        for line in index.lines {
            let rendered = "[\(MeetingMarkdown.timestamp(line.timecode))] \(line.speaker): \(line.text)"
            if current.isEmpty {
                chunkStart = line.timecode
            } else {
                let spanWouldExceed = line.timecode - chunkStart >= maxSeconds
                let sizeWouldExceed = currentCharacters + rendered.count > maxCharacters
                if spanWouldExceed || sizeWouldExceed {
                    flush()
                    chunkStart = line.timecode
                }
            }
            current.append(rendered)
            // Newline included, so the sum matches what `joined(separator:)` will produce.
            currentCharacters += rendered.count + 1
        }
        flush()
        return chunks
    }
}
