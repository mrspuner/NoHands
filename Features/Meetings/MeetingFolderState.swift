import Foundation

/// What is going on in one folder of the queue, told by what is in it.
///
/// No database and no locks, for the same reason the hand-off from phase 2а is a rename: the
/// file system already knows all of this, and a second copy of the knowledge is a second thing
/// that can be wrong.
public enum MeetingFolderState: Equatable, Sendable {
    /// The name starts with a dot — phase 2а is still writing into it.
    case recording
    /// Ready and untouched.
    case waiting
    /// Processing went wrong, with the reason it went wrong. The audio stays and is spared by
    /// rotation: a recording that failed is worth more than the disk space it costs.
    case failed(String)
    /// Done, at the moment recorded in `processed.json`.
    case processed(Date)

    public static func of(_ folder: URL, fileManager: FileManager = .default) -> MeetingFolderState {
        if folder.lastPathComponent.hasPrefix(MeetingFolder.draftPrefix) { return .recording }
        if let reason = MeetingErrorFile.read(in: folder, fileManager: fileManager) {
            return .failed(reason)
        }
        let record = folder.appendingPathComponent(ProcessedRecord.fileName)
        if let processed = try? ProcessedRecord.read(from: record) {
            return .processed(processed.processedAt)
        }
        return .waiting
    }
}

/// The reason a folder could not be processed, written next to the audio it is about.
///
/// A file rather than a field in `meeting.json`: that file belongs to phase 2а and describes
/// the recording, while this describes an attempt to read it. Keeping them apart means a failed
/// attempt can be dropped by deleting one file, which is exactly what a retry does.
public enum MeetingErrorFile {
    public static let fileName = "error.txt"

    public static func write(_ reason: String, at date: Date, to folder: URL) throws {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: date))\n\(reason)\n"
        try Data(line.utf8).write(to: folder.appendingPathComponent(fileName))
    }

    /// The reason without the timestamp line, or `nil` when the folder carries no error.
    public static func read(in folder: URL, fileManager: FileManager = .default) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func remove(in folder: URL, fileManager: FileManager = .default) throws {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
