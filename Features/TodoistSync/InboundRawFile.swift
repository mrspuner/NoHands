import Foundation

/// The files NoHands drops into BigHead's `raw/`. Plain text the BigHead agent reads; never
/// rewritten once written — `raw/` is BigHead's source of truth.
public enum InboundRawFile {
    public static func renderTasks(_ events: [InboundEvent], polledAt: Date) -> String {
        var text = header(kind: "todoist", polledAt: polledAt)
        for event in events {
            let (name, s): (String, TaskSnapshot)
            switch event {
            case .closed(let snapshot): (name, s) = ("closed", snapshot)
            case .deleted(let snapshot): (name, s) = ("deleted", snapshot)
            case .changed(let snapshot): (name, s) = ("changed", snapshot)
            }
            text += "- event: \(name)\n"
            text += field("id", s.id) + field("title", s.title) + field("description", s.description)
            text += field("due", s.due) + field("area", s.area) + field("project", s.project)
            text += field("added_at", s.addedAt) + field("updated_at", s.updatedAt) + "\n"
        }
        return text
    }

    public static func renderProjects(_ projects: [ProjectAdded], polledAt: Date) -> String {
        var text = header(kind: "todoist-project", polledAt: polledAt)
        for project in projects {
            text += "- event: project_added\n" + field("id", project.id) + field("area", project.area)
            text += field("name", project.name) + "\n"
        }
        return text
    }

    public static func fileName(kind: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HHmmss"
        return "\(day)-\(kind)-\(formatter.string(from: date)).md"
    }

    /// A second file in the same second gets `-2`, `-3`…: nothing in `raw/` is ever overwritten.
    public static func write(_ text: String, kind: String, at date: Date, rawDirectory: URL) throws -> URL {
        let base = fileName(kind: kind, at: date)
        var url = rawDirectory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rawDirectory.appendingPathComponent(base.replacingOccurrences(of: ".md", with: "-\(suffix).md"))
            suffix += 1
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    private static func header(kind: String, polledAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "---\nkind: \(kind)\npolled_at: \(formatter.string(from: polledAt))\n---\n\n"
    }

    private static func field(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "  \(name): \(value.replacingOccurrences(of: "\n", with: "\n    "))\n"
    }
}
