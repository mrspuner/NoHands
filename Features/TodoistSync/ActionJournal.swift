import Foundation

/// Every change NoHands itself makes in Todoist, one JSON object per line.
///
/// Written now, read by the second slice: the poll returns the owner's changes and NoHands's own
/// alike, and only this file can tell them apart. Lives outside the repository, like the meeting
/// archive and the voice book.
public actor ActionJournal {
    public enum Action {
        public static let projectCreated = "project.created"
        public static let taskCreated = "task.created"
        public static let taskUpdated = "task.updated"
        public static let taskMoved = "task.moved"
        public static let taskClosed = "task.closed"
        public static let taskDeleted = "task.deleted"
        public static let projectArchived = "project.archived"
        public static let projectUnarchived = "project.unarchived"
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let time: String
        public let action: String
        public let todoistID: String
        public let name: String?

        public init(time: String, action: String, todoistID: String, name: String?) {
            self.time = time
            self.action = action
            self.todoistID = todoistID
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case time, action, name
            case todoistID = "todoist_id"
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/todoist-actions.jsonl")
    }

    private let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    public func record(action: String, todoistID: String, name: String?) throws {
        let entry = Entry(
            time: ISO8601DateFormatter().string(from: now()),
            action: action,
            todoistID: todoistID,
            name: name
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
