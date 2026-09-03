import Foundation

/// Names, creates and hands over the folder of one meeting.
///
/// The whole hand-off to phase 2б is a rename. A folder whose name starts with a dot is still
/// being written; renaming it is atomic, so the queue never has to guess whether a file is
/// finished, and Obsidian — which reads the same `~/Meetings` — never sees the unfinished ones.
public enum MeetingFolder {
    static let draftPrefix = ".draft-"

    public static var queueURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
            .appendingPathComponent(".queue")
    }

    /// `2026-09-03-1430-telemost`. Local time on purpose: the archive is read by a human who
    /// remembers when the meeting was, not by a machine reconciling time zones.
    public static func baseName(startedAt: Date, slug: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(formatter.string(from: startedAt))-\(slug)"
    }

    public static func createDraft(
        in queue: URL,
        startedAt: Date,
        slug: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: queue, withIntermediateDirectories: true)
        let base = baseName(startedAt: startedAt, slug: slug)
        var candidate = base
        var suffix = 1
        while fileManager.fileExists(atPath: queue.appendingPathComponent(candidate).path)
            || fileManager.fileExists(atPath: queue.appendingPathComponent(draftPrefix + candidate).path) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        let draft = queue.appendingPathComponent(draftPrefix + candidate)
        try fileManager.createDirectory(at: draft, withIntermediateDirectories: false)
        return draft
    }

    /// Atomic hand-off: after this returns, phase 2б may pick the folder up.
    @discardableResult
    public static func promote(_ draft: URL, fileManager: FileManager = .default) throws -> URL {
        let name = draft.lastPathComponent
        guard name.hasPrefix(draftPrefix) else { return draft }
        let final = draft.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropFirst(draftPrefix.count)))
        try fileManager.moveItem(at: draft, to: final)
        return final
    }

    /// Folders left behind by an application that died mid-recording.
    public static func drafts(in queue: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: queue.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: queue, includingPropertiesForKeys: nil, options: []
        )
        return entries
            .filter { $0.lastPathComponent.hasPrefix(draftPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
