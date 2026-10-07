import Foundation

/// Turns one local HTTP request into one answer. Every failure becomes a status code and a
/// sentence the agent can repeat to the owner; nothing falls back silently.
public struct TodoistEndpoint: Sendable {
    private let operations: any TodoistOperating

    public init(operations: any TodoistOperating) {
        self.operations = operations
    }

    enum Route: Equatable {
        case health
        case createTask
        case updateTask(String)
        case closeTask(String)
        case deleteTask(String)
        case ensureProject
        case archiveProject
        case unarchiveProject
    }

    enum Resolution: Equatable {
        case route(Route)
        case methodNotAllowed
        case notFound
    }

    static func resolve(method: String, path: String) -> Resolution {
        let parts = path.split(separator: "/").map(String.init)
        func allow(_ expected: String, _ route: Route) -> Resolution {
            method == expected ? .route(route) : .methodNotAllowed
        }
        switch parts.count {
        case 1 where parts[0] == "health": return allow("GET", .health)
        case 1 where parts[0] == "tasks": return allow("POST", .createTask)
        case 1 where parts[0] == "projects": return allow("POST", .ensureProject)
        case 2 where parts[0] == "tasks":
            switch method {
            case "PUT": return .route(.updateTask(parts[1]))
            case "DELETE": return .route(.deleteTask(parts[1]))
            default: return .methodNotAllowed
            }
        case 2 where parts[0] == "projects" && parts[1] == "archive": return allow("POST", .archiveProject)
        case 2 where parts[0] == "projects" && parts[1] == "unarchive": return allow("POST", .unarchiveProject)
        case 3 where parts[0] == "tasks" && parts[2] == "close": return allow("POST", .closeTask(parts[1]))
        default: return .notFound
        }
    }

    public func respond(method: String, path: String, body: Data) async -> HTTPResponse {
        switch Self.resolve(method: method, path: path) {
        case .notFound:
            return .json(404, ["error": "No such endpoint: \(path)"])
        case .methodNotAllowed:
            return .json(405, ["error": "Method \(method) is not allowed on \(path)"])
        case .route(let route):
            do {
                return try await handle(route, body: body)
            } catch {
                return Self.failure(error)
            }
        }
    }

    private func handle(_ route: Route, body: Data) async throws -> HTTPResponse {
        switch route {
        case .health:
            return .json(200, ["ok": true])

        case .createTask:
            let result = try await operations.create(try CreateTaskRequest.decode(body))
            return .json(201, Self.withWarning([
                "id": result.id,
                "project_id": result.projectID,
                "created_projects": result.createdProjects,
            ], result.warning))

        case .updateTask(let id):
            try Self.check(id)
            let result = try await operations.update(id: id, try CreateTaskRequest.decode(body))
            return .json(200, Self.withWarning([
                "project_id": result.projectID,
                "moved": result.moved,
                "created_projects": result.createdProjects,
            ], result.warning))

        case .closeTask(let id):
            try Self.check(id)
            return Self.gone(try await operations.close(id: id))

        case .deleteTask(let id):
            try Self.check(id)
            return Self.gone(try await operations.delete(id: id))

        case .ensureProject:
            let result = try await operations.ensureProject(try ProjectRequest.decode(body))
            return .json(result.created ? 201 : 200, Self.withWarning([
                "id": result.id,
                "created": result.created,
            ], result.warning))

        case .archiveProject:
            return Self.gone(try await operations.archiveProject(try ProjectRequest.decode(body)))

        case .unarchiveProject:
            return Self.gone(try await operations.unarchiveProject(try ProjectRequest.decode(body)))
        }
    }

    /// The id goes into a Todoist URL path; anything but ASCII letters and digits is refused.
    private static func check(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw InvalidID()
        }
    }

    private struct InvalidID: Error, LocalizedError {
        var errorDescription: String? { "Task id must be ASCII letters and digits only" }
    }

    private static func gone(_ result: OperationResult) -> HTTPResponse {
        .json(200, withWarning(["already": result.already], result.warning))
    }

    private static func withWarning(_ answer: [String: Any], _ warning: String?) -> [String: Any] {
        var answer = answer
        if let warning { answer["warning"] = warning }
        return answer
    }

    static func failure(_ error: any Error) -> HTTPResponse {
        switch error {
        case let error as RequestError:
            return .json(400, ["error": error.localizedDescription])
        case let error as InvalidID:
            return .json(400, ["error": error.localizedDescription])
        case let error as TodoistError:
            switch error {
            case .tokenMissing, .keychain:
                return .json(503, ["error": error.localizedDescription])
            case .notFound:
                return .json(404, ["error": error.localizedDescription])
            case .requestFailed(let status, _):
                return .json(502, ["error": error.localizedDescription, "todoist_status": status])
            case .unexpectedResponse:
                return .json(502, ["error": error.localizedDescription])
            }
        case let error as OperationError:
            return .json(404, ["error": error.localizedDescription])
        case let error as TaskCreateError:
            return .json(504, ["error": error.localizedDescription, "outcome": "unknown"])
        case let error as ResolveError:
            return .json(409, ["error": error.localizedDescription])
        default:
            return .json(500, ["error": error.localizedDescription])
        }
    }
}
