import Foundation
import Testing
@testable import TodoistSync

private func decode(_ json: String) throws -> CreateTaskRequest {
    try CreateTaskRequest.decode(Data(json.utf8))
}

@Test func aFullRequestIsDecoded() throws {
    let request = try decode("""
    {"title":"Собрать правки","description":"п. 9–14","due":"2026-10-10","area":"Сколково","project":"Хибины"}
    """)
    #expect(request == CreateTaskRequest(
        title: "Собрать правки", description: "п. 9–14", due: "2026-10-10",
        area: "Сколково", project: "Хибины"
    ))
}

// A task from the area's «Общее» section has no project, and most tasks have no due date.
@Test func optionalFieldsMayBeAbsent() throws {
    let request = try decode(#"{"title":"Ликбез по git","area":"Сколково"}"#)
    #expect(request.description == nil)
    #expect(request.due == nil)
    #expect(request.project == nil)
}

// The agent assembles this JSON by hand; an empty string is how "no value" most often arrives.
@Test func emptyOptionalStringsBecomeNil() throws {
    let request = try decode(#"{"title":"T","area":"A","description":"  ","due":"","project":""}"#)
    #expect(request.description == nil)
    #expect(request.due == nil)
    #expect(request.project == nil)
}

@Test func surroundingWhitespaceIsTrimmed() throws {
    let request = try decode(#"{"title":"  T  ","area":" Сколково ","project":" Хибины "}"#)
    #expect(request.title == "T")
    #expect(request.area == "Сколково")
    #expect(request.project == "Хибины")
}

@Test func aMissingTitleIsNamed() {
    #expect(throws: RequestError.missingField("title")) { try decode(#"{"area":"A"}"#) }
}

@Test func aBlankAreaIsNamed() {
    #expect(throws: RequestError.missingField("area")) { try decode(#"{"title":"T","area":"   "}"#) }
}

@Test func aNonStringFieldCountsAsMissing() {
    #expect(throws: RequestError.missingField("title")) { try decode(#"{"title":42,"area":"A"}"#) }
}

@Test func notJSONIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try decode("title=T") }
}

@Test func aJSONArrayIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try decode(#"["T"]"#) }
}

// Todoist parses `due_string` by language and silently lands on the wrong day for Russian
// phrases; only a calendar date is ever passed on, and only a real one.
@Test(arguments: ["10.10.2026", "завтра", "2026-10-1", "2026-02-30", "2026-13-01"])
func anInvalidDueIsRefused(due: String) {
    #expect(throws: RequestError.invalidDue(due)) {
        try decode(#"{"title":"T","area":"A","due":"\#(due)"}"#)
    }
}

@Test func aLeapDayIsAValidDue() throws {
    #expect(try decode(#"{"title":"T","area":"A","due":"2028-02-29"}"#).due == "2028-02-29")
}

@Test func optionalFieldWithWrongTypeIsRejected_project() {
    #expect(throws: RequestError.wrongType("project")) {
        try decode(#"{"title":"T","area":"A","project":42}"#)
    }
}

@Test func optionalFieldWithWrongTypeIsRejected_due() {
    #expect(throws: RequestError.wrongType("due")) {
        try decode(#"{"title":"T","area":"A","due":20261010}"#)
    }
}

@Test func optionalFieldWithWrongTypeIsRejected_description() {
    #expect(throws: RequestError.wrongType("description")) {
        try decode(#"{"title":"T","area":"A","description":["x"]}"#)
    }
}

@Test func jsonNullForOptionalFieldBecomesNil() throws {
    let request = try decode(#"{"title":"T","area":"A","project":null}"#)
    #expect(request.project == nil)
}
