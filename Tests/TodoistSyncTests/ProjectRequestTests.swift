import Foundation
import Testing
@testable import TodoistSync

@Test func aProjectRequestIsDecodedAndTrimmed() throws {
    let request = try ProjectRequest.decode(Data(#"{"area":" RooX ","project":" ИНДИД "}"#.utf8))
    #expect(request == ProjectRequest(area: "RooX", project: "ИНДИД"))
}

@Test func aProjectRequestNeedsBothFields() {
    #expect(throws: RequestError.missingField("project")) {
        try ProjectRequest.decode(Data(#"{"area":"RooX"}"#.utf8))
    }
    #expect(throws: RequestError.missingField("area")) {
        try ProjectRequest.decode(Data(#"{"area":"  ","project":"P"}"#.utf8))
    }
}

@Test func aProjectRequestThatIsNotAnObjectIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try ProjectRequest.decode(Data("[]".utf8)) }
}
