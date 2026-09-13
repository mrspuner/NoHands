import Foundation

/// Cuts a transcript into pieces small enough for the model to hold at once.
///
/// Five minutes is not a calculation either. Fifteen minutes was the earlier default, justified by
/// the length of the meeting that ran on the owner's machine on 2026-09-07 and produced the best
/// summary of that day, while the sixty-eight-minute meeting on the same prompt produced a table
/// of contents and, on the second attempt, was killed by the system for taking ten gigabytes. That
/// justification held only until completeness could be measured: on the only meeting checked
/// against a hand-written reference list — sixteen minutes, four people, thirteen things actually
/// said — a fifteen-minute cut scored 1 of 13 against five minutes' 5 of 13. One meeting and one
/// reference list is a thin sample, and the model's own judgment of what counts as a match is
/// known to wobble.
///
/// Neither number was the whole rule on its own, which is why a third limit joins the other two:
/// the same sixteen-minute meeting on 2026-09-11, cut at the old fifteen-minute clock, put 59
/// speaker turns in one chunk and produced one point out of thirteen, while five-minute chunks
/// of the same meeting produced five. What separated the good chunks from the bad one was not
/// time and not word count — a slower meeting elsewhere had made fifteen minutes work — but how
/// many times the speaker changed. So the third limit is how many speaker turns one chunk may
/// hold. Combined with the five-minute clock it changed nothing on this meeting — the clock
/// still trips first — but it is now a ceiling for stretches denser than five minutes can hold,
/// which is what it did on the archive's longer meetings: closing chunks on turns rather than on
/// time. A monologue has no turns to spend and is still cut by the clock.
///
/// Three limits are live at once and the first to trip wins: the span in seconds, the number of
/// characters, and the number of speaker turns.
public enum TranscriptChunks {
    /// One chunk, with the two numbers the cut was made on. They travel with the text because
    /// `nohands meeting summarize` prints them for tuning, and recomputing them from the rendered
    /// lines would be a second implementation that could disagree with the one that cut.
    public struct Chunk: Equatable, Sendable {
        public var text: String
        /// From the first line's timecode to the last's. Zero for a chunk of one line.
        public var seconds: TimeInterval
        public var turns: Int

        public init(text: String, seconds: TimeInterval, turns: Int) {
            self.text = text
            self.seconds = seconds
            self.turns = turns
        }
    }

    /// - Parameter maxTurns: how many speaker turns one chunk may hold. A **turn** is a line whose
    ///   speaker differs from the previous line's *within the same chunk*; the chunk's first line
    ///   opens the first turn. The chunk closes before the line that would open turn `maxTurns + 1`,
    ///   which gives this limit a property the other two lack: a chunk closed by the budget always
    ///   ends on a boundary between speakers rather than inside somebody's speech.
    ///
    ///   Measured on 2026-09-11, and it is the reason this parameter exists: a sixteen-minute
    ///   meeting cut at fifteen minutes put 59 turns in one chunk and produced 1 point out of 13,
    ///   while five-minute chunks — 22, 13 and 25 turns — produced 5. The chunks that worked
    ///   elsewhere in the archive carry 12–29. Density cannot be measured in lines or words: lines
    ///   per minute is a property of whoever transcribed the meeting, and the failing meeting was
    ///   *slower* in words per minute than one where fifteen minutes worked.
    ///
    ///   Files written before phase 2г, and other people's transcripts, are cut by the same rule
    ///   on whatever labels they carry. Their turns are undercounted — every interlocutor is one
    ///   «Собеседник» — so their chunks come out larger, but never longer than `maxSeconds`, which
    ///   is what they get today.
    /// - Returns: chunks in meeting order, each one whole reply lines joined by newlines. Every
    ///   reply in `index.lines` appears in exactly one chunk, in meeting order, and none is split
    ///   across two — that is the property that guarantees nothing was dropped. This is not the
    ///   same as reproducing `index.body` byte for byte: each line here is rebuilt from the
    ///   parsed `timecode`, `speaker` and `text`, which `TranscriptIndex.parse` trims, while
    ///   `body` keeps the raw source line untouched. A file with irregular whitespace — an extra
    ///   space after `]`, two spaces after the speaker's colon, a trailing space — round-trips to
    ///   text that reads the same but is not necessarily identical to `index.body`.
    public static func split(
        _ index: TranscriptIndex,
        maxSeconds: TimeInterval,
        maxCharacters: Int,
        maxTurns: Int
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [String] = []
        var currentCharacters = 0
        var chunkStart: TimeInterval = 0
        var chunkEnd: TimeInterval = 0
        var turns = 0
        var lastSpeaker: String?

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(
                Chunk(
                    text: current.joined(separator: "\n"),
                    seconds: chunkEnd - chunkStart,
                    turns: turns
                )
            )
            current = []
            currentCharacters = 0
            turns = 0
            lastSpeaker = nil
        }

        for line in index.lines {
            let rendered = "[\(MeetingMarkdown.timestamp(line.timecode))] \(line.speaker): \(line.text)"
            if current.isEmpty {
                chunkStart = line.timecode
                turns = 1
                lastSpeaker = line.speaker
            } else {
                let opensTurn = line.speaker != lastSpeaker
                let turnsWouldExceed = opensTurn && turns + 1 > maxTurns
                let spanWouldExceed = line.timecode - chunkStart >= maxSeconds
                let sizeWouldExceed = currentCharacters + rendered.count > maxCharacters
                if turnsWouldExceed || spanWouldExceed || sizeWouldExceed {
                    flush()
                    chunkStart = line.timecode
                    turns = 1
                    lastSpeaker = line.speaker
                } else if opensTurn {
                    turns += 1
                    lastSpeaker = line.speaker
                }
            }
            current.append(rendered)
            chunkEnd = line.timecode
            // Newline included, so the sum matches what `joined(separator:)` will produce.
            currentCharacters += rendered.count + 1
        }
        flush()
        return chunks
    }
}
