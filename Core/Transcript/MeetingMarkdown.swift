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

    public static func render(
        transcript: [Utterance],
        startedAt: Date,
        durationSeconds: TimeInterval,
        appName: String?
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(format(startedAt, as: "yyyy-MM-dd"))")
        lines.append("started: \(format(startedAt, as: "HH:mm"))")
        lines.append("duration: \(Int((durationSeconds / 60).rounded()))m")
        if let appName { lines.append("app: \(quoted(appName))") }
        lines.append("---")
        lines.append("")
        lines.append("## Транскрипт")
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
