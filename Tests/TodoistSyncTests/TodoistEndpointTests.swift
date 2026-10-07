import Foundation
import Testing
@testable import TodoistSync

private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private let validBody = Data(#"{"title":"T","area":"Сколково","project":"Хибины"}"#.utf8)

private func endpoint(_ create: @escaping @Sendable (CreateTaskRequest) async throws -> CreateTaskResult) -> TodoistEndpoint {
    TodoistEndpoint(create: create)
}

private let succeeding = endpoint { _ in
    CreateTaskResult(id: "6hRv", projectID: "p1", createdProjects: ["Хибины"], warning: nil)
}

@Test func aCreatedTaskAnswers201WithItsId() async throws {
    let response = await succeeding.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(response.status == 201)
    let json = try object(response)
    #expect(json["id"] as? String == "6hRv")
    #expect(json["project_id"] as? String == "p1")
    #expect(json["created_projects"] as? [String] == ["Хибины"])
    #expect(json["warning"] == nil)
}

@Test func aWarningIsPassedOn() async throws {
    let warned = endpoint { _ in CreateTaskResult(id: "t", projectID: "p", createdProjects: [], warning: "journal") }
    let json = try object(await warned.respond(method: "POST", path: "/tasks", body: validBody))
    #expect(json["warning"] as? String == "journal")
}

@Test func theRequestIsHandedOverDecoded() async throws {
    let seen = SeenRequest()
    let recording = endpoint { request in
        await seen.set(request)
        return CreateTaskResult(id: "t", projectID: "p", createdProjects: [], warning: nil)
    }
    _ = await recording.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(await seen.value == CreateTaskRequest(title: "T", description: nil, due: nil, area: "Сколково", project: "Хибины"))
}

private actor SeenRequest {
    var value: CreateTaskRequest?
    func set(_ request: CreateTaskRequest) { value = request }
}

@Test func aBadRequestIs400AndNeverReachesTodoist() async throws {
    let untouchable = endpoint { _ in
        Issue.record("must not be called")
        throw TodoistError.tokenMissing
    }
    let response = await untouchable.respond(method: "POST", path: "/tasks", body: Data(#"{"area":"A"}"#.utf8))
    #expect(response.status == 400)
    #expect((try object(response)["error"] as? String)?.contains("title") == true)
}

@Test func aMissingTokenIs503() async {
    let failing = endpoint { _ in throw TodoistError.tokenMissing }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 503)
}

@Test func aKeychainRefusalIs503() async {
    let failing = endpoint { _ in throw TodoistError.keychain("denied") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 503)
}

@Test func aTodoistFailureIs502WithItsStatus() async throws {
    let failing = endpoint { _ in throw TodoistError.requestFailed(status: 429, message: "slow down") }
    let response = await failing.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(response.status == 502)
    let json = try object(response)
    #expect(json["todoist_status"] as? Int == 429)
    #expect((json["error"] as? String)?.contains("slow down") == true)
}

@Test func anUnreadableTodoistAnswerIs502() async {
    let failing = endpoint { _ in throw TodoistError.unexpectedResponse("no id") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 502)
}

@Test func anUnknownOutcomeIs504WithAMarker() async throws {
    let failing = endpoint { _ in throw TaskCreateError.outcomeUnknown("timed out") }
    let response = await failing.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(response.status == 504)
    let json = try object(response)
    #expect(json["outcome"] as? String == "unknown")
    #expect((json["error"] as? String)?.contains("Check Todoist before retrying") == true)
}

@Test func anAmbiguousProjectIs409() async {
    let failing = endpoint { _ in throw ResolveError.ambiguousProject("Хибины") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 409)
}

@Test func anythingElseIs500() async {
    let failing = endpoint { _ in throw URLError(.timedOut) }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 500)
}

// The agent's first question after a failed request: is NoHands there at all.
@Test func healthAnswers200() async throws {
    let response = await succeeding.respond(method: "GET", path: "/health", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["ok"] as? Bool == true)
}

@Test func theWrongMethodIs405() async {
    #expect(await succeeding.respond(method: "GET", path: "/tasks", body: Data()).status == 405)
}

@Test func anUnknownPathIs404() async {
    #expect(await succeeding.respond(method: "POST", path: "/nope", body: Data()).status == 404)
}
