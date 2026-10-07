import Foundation
import os
import Testing
@testable import TodoistSync

/// Records every request and answers from a queue, so no test ever reaches api.todoist.com.
private final class FakeTransport: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (requests: [URLRequest](), answers: [(Int, String)]()))

    init(_ answers: [(Int, String)]) {
        lock.withLock { $0.answers = answers }
    }

    var requests: [URLRequest] { lock.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (status, body) = lock.withLock { state -> (Int, String) in
            state.requests.append(request)
            return state.answers.isEmpty ? (500, "no answer queued") : state.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private func client(_ transport: FakeTransport, token: String? = "secret") -> TodoistClient {
    TodoistClient(lookup: { token }, transport: { try await transport.send($0) })
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    guard let httpBody = request.httpBody else { throw NSError(domain: "", code: 0) }
    return try JSONSerialization.jsonObject(with: httpBody) as! [String: Any]
}

@Test func projectsFollowTheCursorUntilItRunsOut() async throws {
    let transport = FakeTransport([
        (200, #"{"results":[{"id":"a","name":"Сколково","parent_id":null}],"next_cursor":"c1"}"#),
        (200, #"{"results":[{"id":"b","name":"Хибины","parent_id":"a"}],"next_cursor":null}"#),
    ])
    let projects = try await client(transport).projects()

    #expect(projects == [
        TodoistProject(id: "a", name: "Сколково", parentID: nil),
        TodoistProject(id: "b", name: "Хибины", parentID: "a"),
    ])
    let urls = transport.requests.map { $0.url!.absoluteString }
    #expect(urls[0] == "https://api.todoist.com/api/v1/projects?limit=200")
    #expect(urls[1] == "https://api.todoist.com/api/v1/projects?limit=200&cursor=c1")
}

@Test func everyRequestCarriesTheBearerToken() async throws {
    let transport = FakeTransport([(200, #"{"results":[],"next_cursor":null}"#)])
    _ = try await client(transport).projects()
    #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
}

@Test func createProjectSendsNameAndParent() async throws {
    let transport = FakeTransport([(200, #"{"id":"p1","name":"Хибины","parent_id":"a"}"#)])
    let project = try await client(transport).createProject(name: "Хибины", parentID: "a")

    #expect(project == TodoistProject(id: "p1", name: "Хибины", parentID: "a"))
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/projects")
    let body = try json(request)
    #expect(body["name"] as? String == "Хибины")
    #expect(body["parent_id"] as? String == "a")
}

@Test func aRootProjectIsSentWithoutAParent() async throws {
    let transport = FakeTransport([(200, #"{"id":"a","name":"Сколково","parent_id":null}"#)])
    _ = try await client(transport).createProject(name: "Сколково", parentID: nil)
    #expect(try json(transport.requests[0])["parent_id"] == nil)
}

// `due_date`, never `due_string`: the string is parsed by language and silently lands on the
// wrong day for a Russian phrase.
@Test func createTaskSendsDueDateAndReturnsTheId() async throws {
    let transport = FakeTransport([(200, #"{"id":"6hRvqqQ89g3prC7Q","content":"T"}"#)])
    let id = try await client(transport).createTask(
        NewTodoistTask(content: "T", description: "D", dueDate: "2026-10-10", projectID: "p1")
    )

    #expect(id == "6hRvqqQ89g3prC7Q")
    let request = transport.requests[0]
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks")
    let body = try json(request)
    #expect(body["content"] as? String == "T")
    #expect(body["description"] as? String == "D")
    #expect(body["due_date"] as? String == "2026-10-10")
    #expect(body["project_id"] as? String == "p1")
    #expect(body["due_string"] == nil)
}

@Test func absentOptionalTaskFieldsAreNotSent() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    _ = try await client(transport).createTask(
        NewTodoistTask(content: "T", description: nil, dueDate: nil, projectID: "p1")
    )
    let body = try json(transport.requests[0])
    #expect(body["description"] == nil)
    #expect(body["due_date"] == nil)
}

// A response without an id means no task was created. Inventing one would confirm a task
// that does not exist — the same rule `inbox-review` follows for `card.md`.
@Test func aTaskResponseWithoutAnIdIsAnError() async {
    let transport = FakeTransport([(200, #"{"content":"T"}"#)])
    await #expect(throws: TodoistError.self) {
        _ = try await client(transport).createTask(
            NewTodoistTask(content: "T", description: nil, dueDate: nil, projectID: "p1")
        )
    }
}

@Test func aTodoistErrorKeepsItsStatusAndBody() async {
    let transport = FakeTransport([(403, "Forbidden")])
    await #expect(throws: TodoistError.requestFailed(status: 403, message: "Forbidden")) {
        _ = try await client(transport).projects()
    }
}

@Test func aLongErrorBodyIsCut() async throws {
    let transport = FakeTransport([(500, String(repeating: "x", count: 2000))])
    do {
        _ = try await client(transport).projects()
        Issue.record("expected a failure")
    } catch let TodoistError.requestFailed(_, message) {
        #expect(message.count == 501)
        #expect(message.hasSuffix("…"))
    }
}

@Test func aMissingTokenIsNamedAndNothingIsSent() async {
    let transport = FakeTransport([])
    await #expect(throws: TodoistError.tokenMissing) {
        _ = try await client(transport, token: nil).projects()
    }
    #expect(transport.requests.isEmpty)
}

// The first read of a Keychain item placed from Terminal raises an authorization dialog; doing
// that on every request would put a dialog in front of every task the agent creates.
@Test func theTokenIsReadOnce() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let transport = FakeTransport([
        (200, #"{"results":[],"next_cursor":null}"#),
        (200, #"{"results":[],"next_cursor":null}"#),
    ])
    let client = TodoistClient(
        lookup: { reads.withLock { $0 += 1 }; return "secret" },
        transport: { try await transport.send($0) }
    )
    _ = try await client.projects()
    _ = try await client.projects()
    #expect(reads.withLock { $0 } == 1)
}

@Test func warmingUpSwallowsAMissingToken() async {
    let client = TodoistClient(lookup: { nil }, transport: { _ in throw URLError(.badURL) })
    await client.warmUp()
}

// MARK: - Slice 2 calls

@Test func a404BecomesNotFound() async {
    let transport = FakeTransport([(404, "Not found")])
    await #expect(throws: TodoistError.notFound) {
        _ = try await client(transport).task(id: "t1")
    }
}

@Test func taskReadsItsProject() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1","project_id":"p9","content":"x"}"#)])
    let info = try await client(transport).task(id: "t1")
    #expect(info == TodoistTaskInfo(id: "t1", projectID: "p9"))
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
    #expect(transport.requests[0].httpMethod == "GET")
}

@Test func updateSendsTheWholeTask() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    try await client(transport).updateTask(id: "t1", TaskUpdate(content: "T", description: "D", dueDate: "2026-10-10"))
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
    let body = try json(request)
    #expect(body["content"] as? String == "T")
    #expect(body["description"] as? String == "D")
    #expect(body["due_date"] as? String == "2026-10-10")
    #expect(body["due_string"] == nil)
}

// Verified live: `due_date: null` is silently ignored; only `due_string: "no date"` clears it.
// An update sends the whole task, so an absent due date means "no due date".
@Test func anUpdateWithoutDueClearsIt() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    try await client(transport).updateTask(id: "t1", TaskUpdate(content: "T", description: nil, dueDate: nil))
    let body = try json(transport.requests[0])
    #expect(body["due_string"] as? String == "no date")
    #expect(body["due_date"] == nil)
    #expect(body["description"] as? String == "")
}

// Verified live: `project_id` in an update is silently ignored; moving is its own call.
@Test func moveUsesTheMoveEndpoint() async throws {
    let transport = FakeTransport([(200, "{}")])
    try await client(transport).moveTask(id: "t1", toProject: "p2")
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1/move")
    #expect(try json(request)["project_id"] as? String == "p2")
}

@Test func closeAcceptsAnEmpty204() async throws {
    let transport = FakeTransport([(204, "")])
    try await client(transport).closeTask(id: "t1")
    #expect(transport.requests[0].httpMethod == "POST")
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1/close")
}

@Test func deleteUsesDELETE() async throws {
    let transport = FakeTransport([(204, "")])
    try await client(transport).deleteTask(id: "t1")
    #expect(transport.requests[0].httpMethod == "DELETE")
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
}

@Test func archivedProjectsFollowTheCursor() async throws {
    let transport = FakeTransport([
        (200, #"{"results":[{"id":"a","name":"A","parent_id":null}],"next_cursor":"c"}"#),
        (200, #"{"results":[{"id":"b","name":"B","parent_id":"a"}],"next_cursor":null}"#),
    ])
    let projects = try await client(transport).archivedProjects()
    #expect(projects.map(\.id) == ["a", "b"])
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/projects/archived?limit=200")
    #expect(transport.requests[1].url!.absoluteString == "https://api.todoist.com/api/v1/projects/archived?limit=200&cursor=c")
}

@Test func archiveAndUnarchiveHitTheirEndpoints() async throws {
    let transport = FakeTransport([(200, "{}"), (200, "{}")])
    let client = client(transport)
    try await client.archiveProject(id: "p1")
    try await client.unarchiveProject(id: "p1")
    #expect(transport.requests.map { $0.url!.absoluteString } == [
        "https://api.todoist.com/api/v1/projects/p1/archive",
        "https://api.todoist.com/api/v1/projects/p1/unarchive",
    ])
    #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" })
}

@Test(arguments: [
    ("a/b?c", "a%2Fb%3Fc"), ("..", "%2E%2E"), ("a#b", "a%23b"), ("a%2Fb", "a%252Fb"), ("ид", "%D0%B8%D0%B4"), ("t1", "t1"),
])
func anIdCannotEscapeItsPathSegment(id: String, encoded: String) async throws {
    let transport = FakeTransport([(200, #"{"id":"t1","project_id":"p9"}"#)])
    _ = try await client(transport).task(id: id)
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/\(encoded)")
}

@Test func aProjectIdIsEncodedToo() async throws {
    let transport = FakeTransport([(200, "{}")])
    try await client(transport).archiveProject(id: "a/b?c")
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/projects/a%2Fb%3Fc/archive")
}

/// Answers a sync call the way Todoist does: `sync_status` keyed by the uuid the request carried.
private func syncClient(status: String, record: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> TodoistClient {
    TodoistClient(lookup: { "secret" }, transport: { request in
        record(request)
        let commands = try json(request)["commands"] as! [[String: Any]]
        let uuid = commands[0]["uuid"] as! String
        let body = status.isEmpty ? #"{"sync_status":{}}"# : #"{"sync_status":{"\#(uuid)":\#(status)}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    })
}

@Test func moveProjectSendsAProjectMoveSyncCommand() async throws {
    let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())
    try await syncClient(status: #""ok""#) { request in seen.withLock { $0.append(request) } }
        .moveProject(id: "b", toParent: "a")

    let request = try #require(seen.withLock { $0.first })
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/sync")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let command = (try json(request)["commands"] as! [[String: Any]])[0]
    #expect(command["type"] as? String == "project_move")
    #expect(!(command["uuid"] as! String).isEmpty)
    let args = command["args"] as! [String: Any]
    #expect(args["id"] as? String == "b")
    #expect(args["parent_id"] as? String == "a")
}

@Test func moveProjectThrowsOnANonOkSyncStatus() async {
    await #expect(throws: TodoistError.self) {
        try await syncClient(status: #"{"error_code":22,"error":"Invalid parent"}"#)
            .moveProject(id: "b", toParent: "a")
    }
}

@Test func moveProjectThrowsWhenTheStatusIsMissing() async {
    await #expect(throws: TodoistError.self) {
        try await syncClient(status: "").moveProject(id: "b", toParent: "a")
    }
}
