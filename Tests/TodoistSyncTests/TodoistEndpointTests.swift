import Foundation
import Testing
@testable import TodoistSync

/// Records the call and answers with a canned result or error.
private actor FakeOperations: TodoistOperating {
    var calls: [String] = []
    var error: (any Error)?
    var already = false
    var created = true

    init(error: (any Error)? = nil, already: Bool = false, created: Bool = true) {
        self.error = error
        self.already = already
        self.created = created
    }

    private func record(_ call: String) throws {
        calls.append(call)
        if let error { throw error }
    }

    func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        try record("create \(request.title)")
        return CreateTaskResult(id: "6hRv", projectID: "p1", createdProjects: ["Хибины"], warning: nil)
    }

    func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        try record("update \(id) \(request.title)")
        return UpdateTaskResult(projectID: "p2", moved: true, createdProjects: [], warning: nil)
    }

    func close(id: String) async throws -> OperationResult {
        try record("close \(id)")
        return OperationResult(already: already, warning: nil)
    }

    func delete(id: String) async throws -> OperationResult {
        try record("delete \(id)")
        return OperationResult(already: already, warning: nil)
    }

    func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        try record("ensure \(request.area)/\(request.project)")
        return EnsureProjectResult(id: "p9", created: created, warning: nil)
    }

    func archiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try record("archive \(request.area)/\(request.project)")
        return OperationResult(already: already, warning: "journal")
    }

    func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try record("unarchive \(request.area)/\(request.project)")
        return OperationResult(already: already, warning: nil)
    }
}

private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private let taskBody = Data(#"{"title":"T","area":"Сколково","project":"Хибины"}"#.utf8)
private let projectBody = Data(#"{"area":"RooX","project":"ИНДИД"}"#.utf8)

@Test func healthAnswers200() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations()).respond(method: "GET", path: "/health", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["ok"] as? Bool == true)
}

@Test func aCreatedTaskAnswers201WithItsId() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations()).respond(method: "POST", path: "/tasks", body: taskBody)
    #expect(response.status == 201)
    let json = try object(response)
    #expect(json["id"] as? String == "6hRv")
    #expect(json["created_projects"] as? [String] == ["Хибины"])
}

@Test func anUpdateAnswers200WithItsProjectAndMove() async throws {
    let fake = FakeOperations()
    let response = await TodoistEndpoint(operations: fake).respond(method: "PUT", path: "/tasks/t1", body: taskBody)
    #expect(response.status == 200)
    let json = try object(response)
    #expect(json["project_id"] as? String == "p2")
    #expect(json["moved"] as? Bool == true)
    #expect(await fake.calls == ["update t1 T"])
}

@Test func closeAndDeleteRouteByMethodAndPath() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1/close", body: Data()).status == 200)
    #expect(await endpoint.respond(method: "DELETE", path: "/tasks/t1", body: Data()).status == 200)
    #expect(await fake.calls == ["close t1", "delete t1"])
}

@Test func alreadyGoneIsPassedOn() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(already: true))
        .respond(method: "POST", path: "/tasks/t1/close", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["already"] as? Bool == true)
}

@Test func ensureProjectAnswers201WhenCreatedAnd200WhenFound() async throws {
    let created = await TodoistEndpoint(operations: FakeOperations(created: true))
        .respond(method: "POST", path: "/projects", body: projectBody)
    #expect(created.status == 201)
    #expect(try object(created)["id"] as? String == "p9")
    let found = await TodoistEndpoint(operations: FakeOperations(created: false))
        .respond(method: "POST", path: "/projects", body: projectBody)
    #expect(found.status == 200)
    #expect(try object(found)["created"] as? Bool == false)
}

@Test func archiveAndUnarchiveRoute() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    let archived = await endpoint.respond(method: "POST", path: "/projects/archive", body: projectBody)
    #expect(archived.status == 200)
    #expect(try object(archived)["warning"] as? String == "journal")
    #expect(await endpoint.respond(method: "POST", path: "/projects/unarchive", body: projectBody).status == 200)
    #expect(await fake.calls == ["archive RooX/ИНДИД", "unarchive RooX/ИНДИД"])
}

@Test func aBadBodyIs400AndNeverReachesTodoist() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    #expect(await endpoint.respond(method: "POST", path: "/tasks", body: Data(#"{"area":"A"}"#.utf8)).status == 400)
    #expect(await endpoint.respond(method: "PUT", path: "/tasks/t1", body: Data("[]".utf8)).status == 400)
    #expect(await endpoint.respond(method: "POST", path: "/projects", body: Data(#"{"area":"A"}"#.utf8)).status == 400)
    #expect(await fake.calls.isEmpty)
}

// The id goes into a Todoist URL; only plain ASCII letters and digits are let through.
@Test(arguments: ["a%2Fb", "t-1", "..", "ид"])
func aStrangeIdIs400(id: String) async {
    let fake = FakeOperations()
    let response = await TodoistEndpoint(operations: fake).respond(method: "DELETE", path: "/tasks/\(id)", body: Data())
    #expect(response.status == 400)
    #expect(await fake.calls.isEmpty)
}

@Test func errorsMapToStatusCodes() async {
    let cases: [(any Error, Int)] = [
        (RequestError.missingField("x"), 400),
        (OperationError.taskNotFound("t1"), 404),
        (OperationError.projectNotFound("P"), 404),
        (TodoistError.notFound, 404),
        (ResolveError.ambiguousProject("P"), 409),
        (TodoistError.requestFailed(status: 429, message: "slow"), 502),
        (TodoistError.unexpectedResponse("x"), 502),
        (TodoistError.tokenMissing, 503),
        (TodoistError.keychain("denied"), 503),
        (TaskCreateError.outcomeUnknown("x"), 504),
        (URLError(.timedOut), 500),
    ]
    for (error, status) in cases {
        let response = await TodoistEndpoint(operations: FakeOperations(error: error))
            .respond(method: "PUT", path: "/tasks/t1", body: taskBody)
        #expect(response.status == status, "\(error)")
    }
}

@Test func aTodoistFailureCarriesItsStatus() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(error: TodoistError.requestFailed(status: 429, message: "slow")))
        .respond(method: "POST", path: "/tasks/t1/close", body: Data())
    #expect(try object(response)["todoist_status"] as? Int == 429)
}

@Test func anUnknownOutcomeSaysSo() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(error: TaskCreateError.outcomeUnknown("x")))
        .respond(method: "POST", path: "/tasks", body: taskBody)
    #expect(try object(response)["outcome"] as? String == "unknown")
}

@Test func theWrongMethodIs405() async {
    let endpoint = TodoistEndpoint(operations: FakeOperations())
    #expect(await endpoint.respond(method: "GET", path: "/tasks", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "GET", path: "/tasks/t1/close", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "GET", path: "/projects/archive", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "POST", path: "/health", body: Data()).status == 405)
}

@Test func anUnknownPathIs404() async {
    let endpoint = TodoistEndpoint(operations: FakeOperations())
    #expect(await endpoint.respond(method: "POST", path: "/nope", body: Data()).status == 404)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1/reopen", body: Data()).status == 404)
    #expect(await endpoint.respond(method: "POST", path: "/projects/rename", body: Data()).status == 404)
}
