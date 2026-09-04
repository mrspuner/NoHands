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

    /// What a folder says when its error file is there but says nothing usable.
    ///
    /// In Russian because the owner reads it: this line ends up on the panel and in the file,
    /// it is not a diagnostic for a log.
    public static let unreadableReason = "Файл ошибки не читается — причина прошлого отказа потеряна"

    /// Written atomically. A crash halfway through an ordinary write leaves a truncated file,
    /// and a truncated file here is worse than no file: it is the record of why a recording
    /// failed.
    public static func write(_ reason: String, at date: Date, to folder: URL) throws {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: date))\n\(reason)\n"
        try Data(line.utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    /// The reason without its timestamp line, or `nil` when the folder carries no error file.
    ///
    /// A file that is present but unreadable — invalid bytes, an empty reason — comes back as a
    /// reason too, a generic one. Returning `nil` there would make a broken error file
    /// indistinguishable from no error at all, and the folder would go back to looking as if it
    /// were merely waiting: retried on every launch, failing every time, with the owner never
    /// told why. That is exactly the silent fallback this project refuses to write.
    public static func read(in folder: URL, fileManager: FileManager = .default) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return unreadableReason }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let reason = lines.count > 1
            ? lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? unreadableReason : reason
    }

    public static func remove(in folder: URL, fileManager: FileManager = .default) throws {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
