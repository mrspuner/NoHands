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
