import Foundation

public struct ProjectInfo: Codable, Equatable, Sendable {
    public let name: String
    public let parentID: String?

    public init(name: String, parentID: String?) {
        self.name = name
        self.parentID = parentID
    }
}

/// What the poll needs to remember between ticks. Lives outside the repository.
public struct SyncState: Codable, Equatable, Sendable {
    public var syncToken: String?
    /// Every known Todoist project, id → name and parent, kept current from each sync.
    public var projects: [String: ProjectInfo]
    /// Projects the owner declined; their tasks and subprojects never reach BigHead.
    public var ignored: [String]

    public static let empty = SyncState(syncToken: nil, projects: [:], ignored: [])
}

public protocol IgnoredProjectsStore: Sendable {
    func ignore(projectID: String) async throws
}

public actor SyncStateStore: IgnoredProjectsStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/todoist-sync-state.json")
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
    }

    /// Replaces the token and the project map, keeping the ignored list as it is on disk now.
    public func saveSync(token: String, projects: [String: ProjectInfo]) throws {
        var state = try load()
        state.syncToken = token
        state.projects = projects
        try write(state)
    }

    public func ignore(projectID: String) throws {
        var state = try load()
        guard !state.ignored.contains(projectID) else { return }
        state.ignored.append(projectID)
        try write(state)
    }

    private func write(_ state: SyncState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
