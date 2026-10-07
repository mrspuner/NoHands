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

/// The three calls the first slice needs. A protocol so `TaskCreator` can be tested against a
/// fake account instead of the owner's real one.
public protocol TodoistAPI: Sendable {
    func projects() async throws -> [TodoistProject]
    func createProject(name: String, parentID: String?) async throws -> TodoistProject
    /// - Returns: the id of the created task, taken from the response and only from it.
    func createTask(_ task: NewTodoistTask) async throws -> String
}

public enum TodoistError: Error, Equatable, LocalizedError {
    case tokenMissing
    /// The Keychain refused the query; the text is `KeychainError`'s description.
    case keychain(String)
    case requestFailed(status: Int, message: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Todoist token is missing from the Keychain (service nohands-todoist, account api-token)"
        case .keychain(let message):
            return message
        case .requestFailed(let status, let message):
            return "Todoist answered \(status): \(message)"
        case .unexpectedResponse(let detail):
            return "Todoist response could not be read: \(detail)"
        }
    }
}
