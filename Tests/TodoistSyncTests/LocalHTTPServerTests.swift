import Foundation
import Network
import Testing
@testable import TodoistSync

private func startEcho() async throws -> (LocalHTTPServer, UInt16) {
    let server = LocalHTTPServer(port: 0) { method, path, body in
        .json(200, ["method": method, "path": path, "size": body.count])
    }
    let port = try await server.start()
    return (server, port)
}

private func call(_ port: UInt16, method: String, path: String, body: Data? = nil) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 5
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return ((response as! HTTPURLResponse).statusCode, json)
}

@Test func aRequestReachesTheHandlerAndTheAnswerComesBack() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }

    let (status, json) = try await call(port, method: "POST", path: "/tasks", body: Data(#"{"a":1}"#.utf8))
    #expect(status == 200)
    #expect(json["method"] as? String == "POST")
    #expect(json["path"] as? String == "/tasks")
    #expect(json["size"] as? Int == 7)
}

@Test func severalRequestsInARowAreServed() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }
    for _ in 0..<5 {
        let (status, _) = try await call(port, method: "GET", path: "/health")
        #expect(status == 200)
    }
}

@Test func anOversizedBodyGets413() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }
    let (status, _) = try await call(port, method: "POST", path: "/tasks",
                                     body: Data(repeating: 0x61, count: HTTPRequestParser.maxBody + 1))
    #expect(status == 413)
}

// A client that sends half a request and hangs up must not take the server with it.
@Test func aClientThatHangsUpMidRequestDoesNotBreakTheServer() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }

    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global())
    connection.send(content: Data("POST /tasks HTTP/1.1\r\nContent-Length: 100\r\n\r\n{".utf8),
                    completion: .contentProcessed { _ in })
    try await Task.sleep(for: .milliseconds(100))
    connection.cancel()

    let (status, _) = try await call(port, method: "GET", path: "/health")
    #expect(status == 200)
}

@Test func aTakenPortIsAnError() async throws {
    let (first, port) = try await startEcho()
    defer { first.stop() }
    let second = LocalHTTPServer(port: port) { _, _, _ in .json(200, [:]) }
    await #expect(throws: (any Error).self) { _ = try await second.start() }
}

// The read deadline guards slow readers only; a handler that outlives it must still answer.
@Test func aSlowHandlerStillAnswersPastTheReadDeadline() async throws {
    let server = LocalHTTPServer(port: 0, readDeadline: 0.2) { _, _, _ in
        try? await Task.sleep(for: .milliseconds(600))
        return .json(200, ["done": true])
    }
    let port = try await server.start()
    defer { server.stop() }

    let (status, json) = try await call(port, method: "POST", path: "/tasks", body: Data("{}".utf8))
    #expect(status == 200)
    #expect(json["done"] as? Bool == true)
}

@Test func aHalfSentRequestIsDroppedAfterTheDeadline() async throws {
    let server = LocalHTTPServer(port: 0, readDeadline: 0.2) { _, _, _ in .json(200, [:]) }
    let port = try await server.start()
    defer { server.stop() }

    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global())
    connection.send(content: Data("POST /tasks HTTP/1.1\r\nContent-Length: 100\r\n\r\n{".utf8),
                    completion: .contentProcessed { _ in })
    let closed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
            continuation.resume(returning: isComplete || error != nil)
        }
    }
    connection.cancel()
    #expect(closed)

    let (status, _) = try await call(port, method: "GET", path: "/health")
    #expect(status == 200)
}

// The start timeout guards only the start: a listener that became ready must outlive it.
@Test func aRunningServerSurvivesTheStartTimeout() async throws {
    let server = LocalHTTPServer(port: 0, readDeadline: 10, startTimeout: 0.3) { _, _, _ in .json(200, [:]) }
    let port = try await server.start()
    defer { server.stop() }

    try await Task.sleep(for: .milliseconds(600))
    let (status, _) = try await call(port, method: "GET", path: "/health")
    #expect(status == 200)
}
