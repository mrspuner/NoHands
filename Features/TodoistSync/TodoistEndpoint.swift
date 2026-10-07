import Foundation

/// Turns one local HTTP request into one answer. Every failure becomes a status code and a
/// sentence the agent can repeat to the owner; nothing falls back silently.
public struct TodoistEndpoint: Sendable {
    private let create: @Sendable (CreateTaskRequest) async throws -> CreateTaskResult

    public init(create: @escaping @Sendable (CreateTaskRequest) async throws -> CreateTaskResult) {
        self.create = create
    }

    public func respond(method: String, path: String, body: Data) async -> HTTPResponse {
        switch (method, path) {
        case ("GET", "/health"):
            return .json(200, ["ok": true])
        case ("POST", "/tasks"):
            return await createTask(body)
        case (_, "/tasks"), (_, "/health"):
            return .json(405, ["error": "Method \(method) is not allowed on \(path)"])
        default:
            return .json(404, ["error": "No such endpoint: \(path)"])
        }
    }

    private func createTask(_ body: Data) async -> HTTPResponse {
        let request: CreateTaskRequest
        do {
            request = try CreateTaskRequest.decode(body)
        } catch {
            return .json(400, ["error": error.localizedDescription])
        }
        do {
            let result = try await create(request)
            var answer: [String: Any] = [
                "id": result.id,
                "project_id": result.projectID,
                "created_projects": result.createdProjects,
            ]
            if let warning = result.warning { answer["warning"] = warning }
            return .json(201, answer)
        } catch let error as TodoistError {
            switch error {
            case .tokenMissing, .keychain:
                return .json(503, ["error": error.localizedDescription])
            case .requestFailed(let status, _):
                return .json(502, ["error": error.localizedDescription, "todoist_status": status])
            case .unexpectedResponse:
                return .json(502, ["error": error.localizedDescription])
            }
        } catch let error as TaskCreateError {
            return .json(504, ["error": error.localizedDescription, "outcome": "unknown"])
        } catch let error as ResolveError {
            return .json(409, ["error": error.localizedDescription])
        } catch {
            return .json(500, ["error": error.localizedDescription])
        }
    }
}
