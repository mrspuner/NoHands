import Foundation

/// The meeting file itself: front matter and a transcript, as `DESIGN.md` draws it.
///
/// Phase 2в will insert `## Саммари` and `## Решения` above the transcript, and 2г will replace
/// `Собеседник` with names and add `participants`. Neither needs this renderer to change, which
/// is why it writes only what phase 2б actually knows.
public enum MeetingMarkdown {
    public static func timestamp(_ seconds: TimeInterval) -> String {
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
        if let appName { lines.append("app: \(appName)") }
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
