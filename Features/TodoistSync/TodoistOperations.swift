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

public struct UpdateTaskResult: Equatable, Sendable {
    public let projectID: String
    public let moved: Bool
    public let createdProjects: [String]
    public let warning: String?
}

public struct OperationResult: Equatable, Sendable {
    /// Todoist was already in the requested state: the task gone, the project (un)archived.
    public let already: Bool
    public let warning: String?
}

public struct EnsureProjectResult: Equatable, Sendable {
    public let id: String
    public let created: Bool
    public let warning: String?
}

public enum OperationError: Error, Equatable, LocalizedError {
    case taskNotFound(String)
    case projectNotFound(String)
    case ignoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Todoist has no task \(id); it was probably deleted there"
        case .projectNotFound(let name):
            return "Todoist has no project called \"\(name)\" at this level"
        case .ignoreUnavailable:
            return "Declined projects cannot be stored: the inbound sync is not set up"
        }
    }
}

public protocol TodoistOperating: Sendable {
    func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult
    func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult
    func close(id: String) async throws -> OperationResult
    func delete(id: String) async throws -> OperationResult
    func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult
    func archiveProject(_ request: ProjectRequest) async throws -> OperationResult
    func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult
    func ignoreProject(_ request: ProjectRequest) async throws -> String
}

/// Every change NoHands makes in Todoist, behind one queue. Finds or creates the area and
/// project by name, then creates, updates, closes or deletes tasks and archives projects.
///
/// An actor with an explicit queue rather than a plain actor: actor methods interleave at every
/// `await`, so two requests for a new area would both see it missing and both create it.
public actor TodoistOperations: TodoistOperating {
    private let api: any TodoistAPI
    private let journal: ActionJournal
    private let ignoredStore: (any IgnoredProjectsStore)?
    private var tail: Task<Void, Never>?

    public init(api: any TodoistAPI, journal: ActionJournal, ignoredStore: (any IgnoredProjectsStore)? = nil) {
        self.api = api
        self.journal = journal
        self.ignoredStore = ignoredStore
    }

    /// One queue for every operation: actor methods interleave at each `await`, so without it
    /// two requests touching a new area would both see it missing and both create it.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task { () throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    public func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        try await enqueue { try await self.perform(request) }
    }

    public func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        try await enqueue { try await self.performUpdate(id: id, request) }
    }

    public func close(id: String) async throws -> OperationResult {
        try await enqueue { try await self.performGone(id: id, action: ActionJournal.Action.taskClosed) { try await $0.closeTask(id: id) } }
    }

    public func delete(id: String) async throws -> OperationResult {
        try await enqueue { try await self.performGone(id: id, action: ActionJournal.Action.taskDeleted) { try await $0.deleteTask(id: id) } }
    }

    public func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        try await enqueue { try await self.performEnsure(request) }
    }

    public func archiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try await enqueue { try await self.performArchive(request, archive: true) }
    }

    public func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try await enqueue { try await self.performArchive(request, archive: false) }
    }

    public func ignoreProject(_ request: ProjectRequest) async throws -> String {
        try await enqueue { try await self.performIgnore(request) }
    }

    private func performIgnore(_ request: ProjectRequest) async throws -> String {
        guard let ignoredStore else { throw OperationError.ignoreUnavailable }
        let active = try await api.projects()
        guard let area = try Self.find(request.area, parentID: nil, in: active) else {
            throw OperationError.projectNotFound(request.area)
        }
        guard let project = try Self.find(request.project, parentID: area.id, in: active) else {
            throw OperationError.projectNotFound(request.project)
        }
        try await ignoredStore.ignore(projectID: project.id)
        return project.id
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

    private func performUpdate(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        let current: TodoistTaskInfo
        do {
            current = try await api.task(id: id)
        } catch TodoistError.notFound {
            throw OperationError.taskNotFound(id)
        }
        var progress = Progress(projects: try await api.projects())
        let area = try await resolve(request.area, parentID: nil, progress: &progress)
        var target = area
        if let name = request.project { target = try await resolve(name, parentID: area.id, progress: &progress) }

        do {
            try await api.updateTask(id: id, TaskUpdate(
                content: request.title, description: request.description, dueDate: request.due
            ))
        } catch TodoistError.notFound {
            throw OperationError.taskNotFound(id)
        }
        await note(ActionJournal.Action.taskUpdated, id: id, name: nil, into: &progress.warnings)

        var moved = false
        if current.projectID != target.id {
            try await api.moveTask(id: id, toProject: target.id)
            moved = true
            await note(ActionJournal.Action.taskMoved, id: id, name: target.name, into: &progress.warnings)
        }
        return UpdateTaskResult(
            projectID: target.id,
            moved: moved,
            createdProjects: progress.created,
            warning: progress.warnings.isEmpty ? nil : progress.warnings.joined(separator: "; ")
        )
    }

    /// Close and delete: the task leaves Todoist. Already gone counts as done, and is not
    /// journaled — NoHands did nothing.
    private func performGone(
        id: String,
        action: String,
        _ call: @Sendable (any TodoistAPI) async throws -> Void
    ) async throws -> OperationResult {
        do {
            try await call(api)
        } catch TodoistError.notFound {
            return OperationResult(already: true, warning: nil)
        }
        var warnings: [String] = []
        await note(action, id: id, name: nil, into: &warnings)
        return OperationResult(already: false, warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    private func performEnsure(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        var progress = Progress(projects: try await api.projects())
        let area = try await resolve(request.area, parentID: nil, progress: &progress)
        let createdBefore = progress.created.count
        let project = try await resolve(request.project, parentID: area.id, progress: &progress)
        return EnsureProjectResult(
            id: project.id,
            created: progress.created.count > createdBefore,
            warning: progress.warnings.isEmpty ? nil : progress.warnings.joined(separator: "; ")
        )
    }

    /// Finds, never creates: archiving something that does not exist is a mistake to name.
    private func performArchive(_ request: ProjectRequest, archive: Bool) async throws -> OperationResult {
        let active = try await api.projects()
        guard let area = try Self.find(request.area, parentID: nil, in: active) else {
            throw OperationError.projectNotFound(request.area)
        }
        let activeProject = try Self.find(request.project, parentID: area.id, in: active)
        var warnings: [String] = []

        if archive {
            guard let project = activeProject else {
                let archived = try await api.archivedProjects()
                if try Self.findArchived(request.project, in: archived) != nil {
                    return OperationResult(already: true, warning: nil)
                }
                throw OperationError.projectNotFound(request.project)
            }
            try await api.archiveProject(id: project.id)
            await note(ActionJournal.Action.projectArchived, id: project.id, name: project.name, into: &warnings)
        } else {
            if activeProject != nil { return OperationResult(already: true, warning: nil) }
            let archived = try await api.archivedProjects()
            guard let project = try Self.findArchived(request.project, in: archived) else {
                throw OperationError.projectNotFound(request.project)
            }
            try await api.unarchiveProject(id: project.id)
            await note(ActionJournal.Action.projectUnarchived, id: project.id, name: project.name, into: &warnings)
            // Unarchiving restores a root project; put it back under its area. A failure here
            // must not throw: the unarchive happened, and a retry would answer already:true.
            do {
                try await api.moveProject(id: project.id, toParent: area.id)
                await note(ActionJournal.Action.projectMoved, id: project.id, name: area.name, into: &warnings)
            } catch {
                warnings.append("project was unarchived but left at the top level: \(error.localizedDescription)")
            }
        }
        return OperationResult(already: false, warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    /// Archiving drops a project's parent, so an archived project is told apart by name among
    /// the top-level entries; the area it came from is no longer recorded.
    private static func findArchived(_ name: String, in projects: [TodoistProject]) throws -> TodoistProject? {
        try find(name, parentID: nil, in: projects)
    }

    private static func find(_ name: String, parentID: String?, in projects: [TodoistProject]) throws -> TodoistProject? {
        let matches = projects.filter { $0.parentID == parentID && same($0.name, name) }
        if matches.count > 1 { throw ResolveError.ambiguousProject(name) }
        return matches.first
    }

    private func resolve(_ name: String, parentID: String?, progress: inout Progress) async throws -> TodoistProject {
        if let found = try Self.find(name, parentID: parentID, in: progress.projects) { return found }
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
