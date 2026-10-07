import Core
import Foundation

/// Talks to Todoist API v1. The only place in this application that holds the Todoist token.
public actor TodoistClient: TodoistAPI {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    fileprivate static let base = URL(string: "https://api.todoist.com/api/v1/")!
    /// Error bodies are passed on to the agent and from there to the owner's chat; several KB of
    /// HTML from a proxy would bury the one line worth reading.
    private static let messageLimit = 500
    private static let timeout: TimeInterval = 20

    private let lookup: @Sendable () throws -> String?
    private let transport: Transport
    private var cachedToken: String?

    /// A dedicated session: `URLSession.shared`'s request timeout only measures idle time, so a
    /// slowly trickling response could hold a call open indefinitely.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    public init() {
        self.init(
            lookup: {
                try Keychain.password(service: Keychain.todoistService, account: Keychain.todoistAccount)
            },
            transport: { try await Self.session.data(for: $0) }
        )
    }

    init(lookup: @escaping @Sendable () throws -> String?, transport: @escaping Transport) {
        self.lookup = lookup
        self.transport = transport
    }

    /// Reads the token at launch, so the Keychain authorization dialog appears while the owner is
    /// at the machine rather than in the middle of an agent's request. Never throws: a missing
    /// token is a request-time failure with its own status code.
    public func warmUp() {
        _ = try? resolvedToken()
    }

    public func projects() async throws -> [TodoistProject] {
        try await pagedProjects(path: "projects")
    }

    public func archivedProjects() async throws -> [TodoistProject] {
        try await pagedProjects(path: "projects/archived")
    }

    private func pagedProjects(path: String) async throws -> [TodoistProject] {
        struct Page: Decodable {
            let results: [TodoistProject]
            let nextCursor: String?
            enum CodingKeys: String, CodingKey {
                case results
                case nextCursor = "next_cursor"
            }
        }
        var all: [TodoistProject] = []
        var cursor: String?
        repeat {
            var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let data = try await send(method: "GET", url: components.url!, body: nil)
            let page = try Self.decode(Page.self, from: data)
            all += page.results
            // A repeated or empty cursor would loop forever on a Todoist bug.
            guard page.nextCursor != cursor, page.nextCursor?.isEmpty != true else { break }
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func createProject(name: String, parentID: String?) async throws -> TodoistProject {
        var body: [String: Any] = ["name": name]
        if let parentID { body["parent_id"] = parentID }
        let data = try await send(method: "POST", url: Self.base.appendingPathComponent("projects"), body: body)
        return try Self.decode(TodoistProject.self, from: data)
    }

    public func createTask(_ task: NewTodoistTask) async throws -> String {
        var body: [String: Any] = ["content": task.content, "project_id": task.projectID]
        if let description = task.description { body["description"] = description }
        if let dueDate = task.dueDate { body["due_date"] = dueDate }
        let data = try await send(method: "POST", url: Self.base.appendingPathComponent("tasks"), body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            throw TodoistError.unexpectedResponse("task response has no id")
        }
        return id
    }

    public func task(id: String) async throws -> TodoistTaskInfo {
        let data = try await send(method: "GET", url: Self.taskURL(id), body: nil)
        return try Self.decode(TodoistTaskInfo.self, from: data)
    }

    public func updateTask(id: String, _ update: TaskUpdate) async throws {
        var body: [String: Any] = ["content": update.content, "description": update.description ?? ""]
        if let dueDate = update.dueDate {
            body["due_date"] = dueDate
        } else {
            // The only way to clear a due date; `due_date: null` is ignored (verified 2026-10-07).
            // `due_string` is never used to set a date: it is parsed by language.
            body["due_string"] = "no date"
        }
        _ = try await send(method: "POST", url: Self.taskURL(id), body: body)
    }

    public func moveTask(id: String, toProject projectID: String) async throws {
        _ = try await send(method: "POST", url: Self.taskURL(id, "move"), body: ["project_id": projectID])
    }

    public func closeTask(id: String) async throws {
        _ = try await send(method: "POST", url: Self.taskURL(id, "close"), body: nil)
    }

    public func deleteTask(id: String) async throws {
        _ = try await send(method: "DELETE", url: Self.taskURL(id), body: nil)
    }

    public func archiveProject(id: String) async throws {
        _ = try await send(method: "POST", url: Self.projectURL(id, "archive"), body: nil)
    }

    public func unarchiveProject(id: String) async throws {
        _ = try await send(method: "POST", url: Self.projectURL(id, "unarchive"), body: nil)
    }

    /// `project_move` through the Sync API. Unarchiving restores a project at the top level, and
    /// this is the only call that puts it back under its area. A 200 does not mean success: the
    /// outcome of the command is in `sync_status`, keyed by the command's uuid.
    public func moveProject(id: String, toParent parentID: String) async throws {
        let uuid = UUID().uuidString
        let command: [String: Any] = [
            "type": "project_move",
            "uuid": uuid,
            "args": ["id": id, "parent_id": parentID],
        ]
        let data = try await send(
            method: "POST",
            url: Self.base.appendingPathComponent("sync"),
            body: ["commands": [command]]
        )
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (object?["sync_status"] as? [String: Any])?[uuid]
        guard let text = status as? String, text == "ok" else {
            let detail = status.map { Self.cut(String(describing: $0)) } ?? "no status"
            throw TodoistError.unexpectedResponse("project_move: \(detail)")
        }
    }

    /// ASCII letters and digits pass; everything else, `.` included, is percent-encoded, so an id
    /// can never add, drop or reinterpret a path segment.
    private static let segmentAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )

    private static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: segmentAllowed)?
            .replacingOccurrences(of: ".", with: "%2E") ?? id
    }

    private static func taskURL(_ id: String, _ action: String? = nil) -> URL {
        let path = "tasks/\(segment(id))" + (action.map { "/\($0)" } ?? "")
        return URL(string: base.absoluteString + path)!
    }

    private static func projectURL(_ id: String, _ action: String) -> URL {
        URL(string: base.absoluteString + "projects/\(segment(id))/\(action)")!
    }

    fileprivate func send(method: String, url: URL, body: [String: Any]?) async throws -> Data {
        let token = try resolvedToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw TodoistError.unexpectedResponse("no HTTP response")
        }
        if http.statusCode == 404 {
            throw TodoistError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw TodoistError.requestFailed(status: http.statusCode, message: Self.cut(message))
        }
        return data
    }

    /// Only success is cached: a token added while the app runs starts working without a restart.
    func resolvedToken() throws -> String {
        if let cachedToken { return cachedToken }
        let found: String?
        do {
            found = try lookup()
        } catch {
            throw TodoistError.keychain(error.localizedDescription)
        }
        guard let found, !found.isEmpty else { throw TodoistError.tokenMissing }
        cachedToken = found
        return found
    }

    fileprivate static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TodoistError.unexpectedResponse(String(describing: error))
        }
    }

    static func cut(_ text: String) -> String {
        text.count > messageLimit ? String(text.prefix(messageLimit)) + "…" : text
    }
}

extension TodoistClient: TodoistSyncing {
    public func sync(token: String) async throws -> SyncResponse {
        let data = try await send(
            method: "POST",
            url: Self.base.appendingPathComponent("sync"),
            body: ["sync_token": token, "resource_types": ["items", "projects"]]
        )
        return try Self.decode(SyncResponse.self, from: data)
    }
}
