import Foundation

public struct CreateTaskResult: Equatable, Sendable {
    public let id: String
    public let projectID: String
    /// Names of projects created on the way, area first.
    public let createdProjects: [String]
    /// Set when the task was created but something after it was not recorded.
    public let warning: String?
}

public enum ResolveError: Error, Equatable, LocalizedError {
    case ambiguousProject(String)

    public var errorDescription: String? {
        switch self {
        case .ambiguousProject(let name):
            return "More than one Todoist project is called \"\(name)\" at this level; rename one of them"
        }
    }
}

/// The task request left the machine but we cannot tell whether Todoist stored the task.
/// A retry could create a duplicate, so this must never look like a plain, retryable failure.
public enum TaskCreateError: Error, Equatable, LocalizedError {
    case outcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .outcomeUnknown(let detail):
            return "Todoist may have created the task: \(detail). Check Todoist before retrying."
        }
    }
}

/// Finds or creates the area and project by name, then creates the task.
///
/// An actor with an explicit queue rather than a plain actor: actor methods interleave at every
/// `await`, so two requests for a new area would both see it missing and both create it.
public actor TaskCreator {
    private let api: any TodoistAPI
    private let journal: ActionJournal
    private var tail: Task<Void, Never>?

    public init(api: any TodoistAPI, journal: ActionJournal) {
        self.api = api
        self.journal = journal
    }

    public func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        let previous = tail
        let work = Task { () throws -> CreateTaskResult in
            await previous?.value
            return try await self.perform(request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private struct Progress {
        var projects: [TodoistProject]
        var created: [String] = []
        var warnings: [String] = []
    }

    private func perform(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        var progress = Progress(projects: try await api.projects())

        let area = try await resolve(request.area, parentID: nil, progress: &progress)
        var target = area
        if let name = request.project { target = try await resolve(name, parentID: area.id, progress: &progress) }
        let id: String
        do {
            id = try await api.createTask(NewTodoistTask(
                content: request.title,
                description: request.description,
                dueDate: request.due,
                projectID: target.id
            ))
        } catch let error as TodoistError {
            switch error {
            case .requestFailed(let status, _) where (400..<500).contains(status):
                throw error  // Todoist refused: the task does not exist.
            case .notFound:
                throw error  // The target project vanished; Todoist refused the task.
            case .tokenMissing, .keychain:
                throw error  // Nothing was sent.
            case .requestFailed, .unexpectedResponse:
                throw TaskCreateError.outcomeUnknown(error.localizedDescription)
            }
        } catch {
            throw TaskCreateError.outcomeUnknown(error.localizedDescription)
        }
        await note(ActionJournal.Action.taskCreated, id: id, name: nil, into: &progress.warnings)

        return CreateTaskResult(
            id: id,
            projectID: target.id,
            createdProjects: progress.created,
            warning: progress.warnings.isEmpty ? nil : progress.warnings.joined(separator: "; ")
        )
    }

    private func resolve(_ name: String, parentID: String?, progress: inout Progress) async throws -> TodoistProject {
        let matches = progress.projects.filter { $0.parentID == parentID && Self.same($0.name, name) }
        if matches.count > 1 { throw ResolveError.ambiguousProject(name) }
        if let found = matches.first { return found }
        let project = try await api.createProject(name: name, parentID: parentID)
        progress.projects.append(project)
        progress.created.append(name)
        await note(ActionJournal.Action.projectCreated, id: project.id, name: name, into: &progress.warnings)
        return project
    }

    /// A journal failure never fails the request: what it would have recorded has already
    /// happened in Todoist, and an error here would make the agent retry it.
    private func note(_ action: String, id: String, name: String?, into warnings: inout [String]) async {
        do {
            try await journal.record(action: action, todoistID: id, name: name)
        } catch {
            warnings.append("action journal not written for \(action) \(id): \(error.localizedDescription)")
        }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let normalize = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalize(a) == normalize(b)
    }
}
