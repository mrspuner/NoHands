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
    /// Ids of tasks known to be inside areas; a deleted task arrives without its project.
    public var workItems: [String]

    public static let empty = SyncState(syncToken: nil, projects: [:], ignored: [], workItems: [])

    public init(syncToken: String?, projects: [String: ProjectInfo], ignored: [String], workItems: [String] = []) {
        self.syncToken = syncToken; self.projects = projects; self.ignored = ignored; self.workItems = workItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncToken = try c.decodeIfPresent(String.self, forKey: .syncToken)
        projects = try c.decode([String: ProjectInfo].self, forKey: .projects)
        ignored = try c.decode([String].self, forKey: .ignored)
        workItems = try c.decodeIfPresent([String].self, forKey: .workItems) ?? []
    }
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

    /// Replaces the token, the project map and the work-item set, keeping the ignored list as it is on disk now.
    public func saveSync(token: String, projects: [String: ProjectInfo], workItems: Set<String>) throws {
        var state = try load()
        state.syncToken = token
        state.projects = projects
        state.workItems = workItems.sorted()
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
