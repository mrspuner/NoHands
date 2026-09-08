import Foundation

/// The meeting file itself: front matter and a transcript, as `DESIGN.md` draws it.
///
/// Phase 2в will insert `## Саммари` and `## Решения` above the transcript, and 2г will replace
/// `Собеседник` with names and add `participants`. Neither needs this renderer to change, which
/// is why it writes only what phase 2б actually knows.
public enum MeetingMarkdown {
    public static func timestamp(_ seconds: TimeInterval) -> String {
        // Clamped rather than allowed negative: merging two tracks could in principle hand this
        // a start before zero, and `%02d` on a negative renders a malformed stamp. The clamp
        // makes such a bug show up as replies stacked at 00:00:00 instead of as broken text.
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// - Parameter trailingMicrophoneSilenceSeconds: how long the owner's own track had been
    ///   exactly zero when the recording ended, or `nil` when it had not been silent long enough
    ///   to be worth saying. The caller applies that threshold, because it is the same one the
    ///   panel uses while the meeting runs and it lives with the panel.
    ///
    ///   This is the only reason the archive knows anything about the microphone. The number is
    ///   also written into `meeting.json`, but `MeetingQueue.sweep` removes that folder whole
    ///   once the meeting is older than `audioRetentionDays` — seven days — and the question
    ///   "why is there no «Я» in this file" is asked much later than that. The markdown is what
    ///   is still here in a year.
    ///
    ///   Only when there was silence: a key on every ordinary meeting would be a claim about
    ///   every ordinary meeting, and this file is meant to hold only what is known.
    public static func render(
        transcript: [Utterance],
        startedAt: Date,
        durationSeconds: TimeInterval,
        appName: String?,
        trailingMicrophoneSilenceSeconds: TimeInterval?
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(format(startedAt, as: "yyyy-MM-dd"))")
        lines.append("started: \(format(startedAt, as: "HH:mm"))")
        lines.append("duration: \(minutes(durationSeconds))m")
        if let appName { lines.append("app: \(quoted(appName))") }
        if let silence = trailingMicrophoneSilenceSeconds, silence > 0 {
            // Quoted and escaped like `app`, though nothing here comes from outside: the value is
            // a Russian sentence with a colon's worth of punctuation in it, and the front matter
            // has one rule for values rather than one per key.
            lines.append("microphone: \(quoted("замолчал в конце — \(silenceLength(silence)) тишины"))")
        }
        lines.append("---")
        lines.append("")
        lines.append(TranscriptIndex.heading)
        lines.append("")
        for utterance in transcript {
            lines.append("[\(timestamp(utterance.start))] \(label(utterance.speaker)): \(utterance.text)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The one value in the front matter that comes from outside this code: the display name of
    /// whatever process was holding the audio devices, straight from `NSRunningApplication`.
    /// A colon or a newline in it would break the `---` block for Obsidian and for phase 2г,
    /// which re-reads this file to pick up edited speaker names. Quoted and escaped rather than
    /// trusted — the archive outlives every assumption about what applications are called.
    static func quoted(_ value: String) -> String {
        var cleaned = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                // Skip control characters entirely
                continue
            } else {
                cleaned.append(Character(scalar))
            }
        }
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Same rule as `MeetingContent.length` in `PanelView` and `MeetingNotice.length`: a meeting
    /// that was in fact recorded must never round down to `0m` in the archive's own front matter
    /// — that would answer "how long was this" wrongly, permanently, in the file the owner keeps.
    /// Unlike the two panel-facing versions this stays numeric rather than switching to words,
    /// because the field is `duration: <N>m`, not a sentence: clamping to one minute keeps the
    /// same shape a longer meeting has instead of inventing a second spelling for the front
    /// matter to parse.
    private static func minutes(_ durationSeconds: TimeInterval) -> Int {
        guard durationSeconds > 0 else { return 0 }
        return max(1, Int((durationSeconds / 60).rounded()))
    }

    /// The same rule as `MeetingNotice.length`, which says this sentence on the panel while the
    /// meeting is still running: under a minute becomes a word, because the gate above is ten
    /// seconds and rounding takes anything under thirty down to zero. "0 мин тишины" would deny
    /// the silence and call the track incomplete in one line — permanently, in the file the owner
    /// keeps. A third copy of a two-line rule rather than a shared one: `MeetingNotice` lives in
    /// `Meetings`, which depends on this module and not the other way round.
    private static func silenceLength(_ seconds: TimeInterval) -> String {
        let whole = Int((seconds / 60).rounded())
        return whole < 1 ? "меньше минуты" : "\(whole) мин"
    }

    private static func label(_ speaker: Utterance.Speaker) -> String {
        switch speaker {
        case .me: return "Я"
        case .others: return "Собеседник"
        }
    }

    /// Local time on purpose, matching `MeetingFolder.baseName`: the archive is read by a human
    /// who remembers when the meeting was.
    private static func format(_ date: Date, as template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
