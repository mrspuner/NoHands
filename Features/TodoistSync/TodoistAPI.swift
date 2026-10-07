import Foundation

public struct TodoistProject: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let parentID: String?

    public init(id: String, name: String, parentID: String?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parent_id"
    }
}

public struct NewTodoistTask: Equatable, Sendable {
    public let content: String
    public let description: String?
    /// `YYYY-MM-DD`, sent as `due_date`.
    public let dueDate: String?
    public let projectID: String

    public init(content: String, description: String?, dueDate: String?, projectID: String) {
        self.content = content
        self.description = description
        self.dueDate = dueDate
        self.projectID = projectID
    }
}

public struct TodoistTaskInfo: Equatable, Sendable, Decodable {
    public let id: String
    public let projectID: String

    public init(id: String, projectID: String) {
        self.id = id
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
    }
}

/// The whole editable state of a task. Sent whole on every update, so a retry is harmless and
/// an absent field means "empty", not "unchanged".
public struct TaskUpdate: Equatable, Sendable {
    public let content: String
    public let description: String?
    public let dueDate: String?

    public init(content: String, description: String?, dueDate: String?) {
        self.content = content
        self.description = description
        self.dueDate = dueDate
    }
}

/// The calls the Todoist sync needs. A protocol so `TodoistOperations` can be tested against a
/// fake account instead of the owner's real one.
public protocol TodoistAPI: Sendable {
    func projects() async throws -> [TodoistProject]
    func createProject(name: String, parentID: String?) async throws -> TodoistProject
    /// - Returns: the id of the created task, taken from the response and only from it.
    func createTask(_ task: NewTodoistTask) async throws -> String
    func task(id: String) async throws -> TodoistTaskInfo
    func updateTask(id: String, _ update: TaskUpdate) async throws
    func moveTask(id: String, toProject projectID: String) async throws
    func closeTask(id: String) async throws
    func deleteTask(id: String) async throws
    func archivedProjects() async throws -> [TodoistProject]
    func archiveProject(id: String) async throws
    func unarchiveProject(id: String) async throws
    /// Nests a project under `parentID`. Only the Sync API can: REST rejects `parent_id` on update
    /// and has no project move (verified 2026-10-07).
    func moveProject(id: String, toParent parentID: String) async throws
}

public struct SyncItem: Equatable, Sendable, Decodable {
    public let id: String
    public let content: String
    /// Nil for an empty description: an empty string and no description mean the same to BigHead.
    public let description: String?
    /// The calendar date of the due, `YYYY-MM-DD`; a due with a time keeps only its date.
    public let dueDate: String?
    public let projectID: String
    public let checked: Bool
    public let isDeleted: Bool
    public let addedAt: String?
    public let updatedAt: String?

    public init(id: String, content: String, description: String?, dueDate: String?, projectID: String,
                checked: Bool, isDeleted: Bool, addedAt: String?, updatedAt: String?) {
        self.id = id; self.content = content; self.description = description; self.dueDate = dueDate
        self.projectID = projectID; self.checked = checked; self.isDeleted = isDeleted
        self.addedAt = addedAt; self.updatedAt = updatedAt
    }

    private struct Due: Decodable { let date: String }
    private enum CodingKeys: String, CodingKey {
        case id, content, description, due, checked
        case projectID = "project_id", isDeleted = "is_deleted", addedAt = "added_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let description = try c.decodeIfPresent(String.self, forKey: .description)
        let due = try c.decodeIfPresent(Due.self, forKey: .due)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
            description: (description?.isEmpty ?? true) ? nil : description,
            dueDate: due.map { String($0.date.prefix(10)) },
            projectID: try c.decode(String.self, forKey: .projectID),
            checked: try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false,
            isDeleted: try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false,
            addedAt: try c.decodeIfPresent(String.self, forKey: .addedAt),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt)
        )
    }
}

public struct SyncProject: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let isArchived: Bool
    public let isDeleted: Bool

    public init(id: String, name: String, parentID: String?, isArchived: Bool, isDeleted: Bool) {
        self.id = id; self.name = name; self.parentID = parentID
        self.isArchived = isArchived; self.isDeleted = isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parent_id", isArchived = "is_archived", isDeleted = "is_deleted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            parentID: try c.decodeIfPresent(String.self, forKey: .parentID),
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            isDeleted: try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        )
    }
}

public struct SyncResponse: Equatable, Sendable, Decodable {
    public let syncToken: String
    public let fullSync: Bool
    public let items: [SyncItem]
    public let projects: [SyncProject]

    public init(syncToken: String, fullSync: Bool, items: [SyncItem], projects: [SyncProject]) {
        self.syncToken = syncToken; self.fullSync = fullSync; self.items = items; self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case items, projects
        case syncToken = "sync_token", fullSync = "full_sync"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            syncToken: try c.decode(String.self, forKey: .syncToken),
            fullSync: try c.decodeIfPresent(Bool.self, forKey: .fullSync) ?? false,
            items: try c.decodeIfPresent([SyncItem].self, forKey: .items) ?? [],
            projects: try c.decodeIfPresent([SyncProject].self, forKey: .projects) ?? []
        )
    }
}

/// The poll, separate from `TodoistAPI` so the poller can be tested against its own fake.
public protocol TodoistSyncing: Sendable {
    func sync(token: String) async throws -> SyncResponse
}

public enum TodoistError: Error, Equatable, LocalizedError {
    case tokenMissing
    /// The Keychain refused the query; the text is `KeychainError`'s description.
    case keychain(String)
    case requestFailed(status: Int, message: String)
    case unexpectedResponse(String)
    /// HTTP 404: Todoist has no such task or project (deleted, or never existed).
    case notFound

    public var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Todoist token is missing from the Keychain (service nohands-todoist, account api-token)"
        case .keychain(let message):
            return message
        case .requestFailed(let status, let message):
            return "Todoist answered \(status): \(message)"
        case .notFound:
            return "Todoist has no such task or project"
        case .unexpectedResponse(let detail):
            return "Todoist response could not be read: \(detail)"
        }
    }
}
