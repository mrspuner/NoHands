import Foundation
import Testing
@testable import TodoistSync

private func bytes(_ text: String) -> Data { Data(text.utf8) }

@Test func aCompletePostIsParsed() {
    let raw = "POST /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .complete(method: "POST", path: "/tasks", body: bytes("{}")))
}

@Test func headerNamesAreCaseInsensitive() {
    let raw = "POST /tasks HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .complete(method: "POST", path: "/tasks", body: bytes("{}")))
}

@Test func aGetWithoutBodyIsComplete() {
    #expect(HTTPRequestParser.parse(bytes("GET /health HTTP/1.1\r\n\r\n"))
        == .complete(method: "GET", path: "/health", body: Data()))
}

@Test func theQueryStringIsDropped() {
    #expect(HTTPRequestParser.parse(bytes("GET /health?x=1 HTTP/1.1\r\n\r\n"))
        == .complete(method: "GET", path: "/health", body: Data()))
}

// TCP delivers in pieces; half a request is a reason to keep reading, not an error.
@Test func headersWithoutTheirEndAreIncomplete() {
    #expect(HTTPRequestParser.parse(bytes("POST /tasks HTTP/1.1\r\nContent-Le")) == .incomplete)
}

@Test func aBodyShorterThanItsLengthIsIncomplete() {
    let raw = "POST /tasks HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .incomplete)
}

@Test func anOversizedBodyIsRefusedBeforeItArrives() {
    let raw = "POST /tasks HTTP/1.1\r\nContent-Length: 70000\r\n\r\n"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .invalid(status: 413))
}

@Test func endlessHeadersAreRefused() {
    let raw = "POST /tasks HTTP/1.1\r\n" + String(repeating: "X-Pad: aaaaaaaa\r\n", count: 2000)
    #expect(HTTPRequestParser.parse(bytes(raw)) == .invalid(status: 431))
}

@Test func garbageIsABadRequest() {
    #expect(HTTPRequestParser.parse(bytes("hello\r\n\r\n")) == .invalid(status: 400))
}

@Test func aNonNumericLengthIsABadRequest() {
    #expect(HTTPRequestParser.parse(bytes("POST /tasks HTTP/1.1\r\nContent-Length: ten\r\n\r\n")) == .invalid(status: 400))
}

@Test func aResponseIsSerializedWithLengthAndClose() {
    let response = HTTPResponse(status: 201, body: bytes("{}"))
    let text = String(decoding: response.serialized(), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
    #expect(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
    #expect(text.contains("Content-Length: 2\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{}"))
}

@Test func contentLengthCountsBytesNotCharacters() {
    let response = HTTPResponse(status: 200, body: bytes("ё"))
    #expect(String(decoding: response.serialized(), as: UTF8.self).contains("Content-Length: 2\r\n"))
}
