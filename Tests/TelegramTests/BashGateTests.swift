import Foundation
import Testing
@testable import Telegram

private func allowed(_ command: String) -> Bool { BashGate.verdict(command) == .allow }

@Test func theAgentsTaskCallIsAllowed() {
    let command = """
        curl -sS -m 120 -X POST http://127.0.0.1:41730/tasks \\
          -H 'Content-Type: application/json' -H 'Expect:' \\
          -d '{"title":"Позвонить Ване [срочно]","description":"Обсудить: отчёт","due":"2026-10-23","area":"работа","project":"Отчёт"}'
        """
    #expect(allowed(command))
}

@Test func healthIsAllowed() {
    #expect(allowed("curl -sS http://127.0.0.1:41730/health"))
}

@Test func aDeleteIsAllowed() {
    #expect(allowed("curl -sS -m 120 -X DELETE http://127.0.0.1:41730/tasks/6hRvqqQ89g3prC7Q"))
}

@Test func aQuotedQueryIsAllowed() {
    #expect(allowed("curl -sS 'http://127.0.0.1:41730/tasks?area=work&x=1'"))
}

@Test(arguments: [
    "ls .",
    "cat AGENTS.md",
    "touch x",
    "rm x",
    "echo x > f",
    "curl https://example.com",
    "curl -sS http://127.0.0.1:41730/health && ls",
    "curl -sS http://127.0.0.1:41730/health; ls",
    "curl -sS http://127.0.0.1:41730/health | sh",
    "curl $(cat f)",
    "curl `id`",
    "curl -sS http://127.0.0.1:41730/x -o /tmp/f",
    "curl -K cfg http://127.0.0.1:41730/x",
    "curl -d @secret http://127.0.0.1:41730/x",
    "curl -H @headers http://127.0.0.1:41730/x",
    "curl http://127.0.0.1:41730@evil.com/",
    "curl http://127.0.0.1:41730/a http://evil/",
    "curl \"http://127.0.0.1:41730/$HOME\"",
    "curl -sS 'http://127.0.0.1:41730/health",
    "",
    "  curl -sS",
    "/usr/bin/curl http://127.0.0.1:41730/health",
    "curl -sS http://127.0.0.1:41730/health\nls",
    "curl -sS http://127.0.0.1:41730/health &",
    "curl -X get http://127.0.0.1:41730/x",
    "curl -m 1e3 http://127.0.0.1:41730/x",
    "curl -sS http://127.0.0.1:41730/x?a=1",
    "curl -sS http://127.0.0.1:41730/x\\ y",
    "curl --unix-socket /s http://127.0.0.1:41730/x",
])
func everythingElseIsDenied(_ command: String) {
    #expect(!allowed(command))
}

@Test func aDenialHasAReason() {
    guard case .deny(let reason) = BashGate.verdict("ls .") else {
        Issue.record("ls was allowed")
        return
    }
    #expect(!reason.isEmpty)
}

private func hook(_ object: [String: Any]) throws -> (exitCode: Int32, stderr: String) {
    BashGate.hookDecision(stdin: try JSONSerialization.data(withJSONObject: object))
}

@Test func theHookLetsOtherToolsThrough() throws {
    let decision = try hook(["tool_name": "Read", "tool_input": ["file_path": "/x"]])
    #expect(decision.exitCode == 0)
    #expect(decision.stderr.isEmpty)
}

@Test func theHookAllowsTheLocalCall() throws {
    let decision = try hook(["tool_name": "Bash",
                             "tool_input": ["command": "curl -sS http://127.0.0.1:41730/health"]])
    #expect(decision.exitCode == 0)
    #expect(decision.stderr.isEmpty)
}

@Test func theHookBlocksAnythingElseWithAReason() throws {
    let decision = try hook(["tool_name": "Bash", "tool_input": ["command": "ls ."]])
    #expect(decision.exitCode == 2)
    #expect(!decision.stderr.isEmpty)
}

@Test func theHookBlocksABashCallWithoutACommand() throws {
    #expect(try hook(["tool_name": "Bash", "tool_input": [:] as [String: Any]]).exitCode == 2)
}

@Test func theHookBlocksGarbage() {
    #expect(BashGate.hookDecision(stdin: Data("not json".utf8)).exitCode == 2)
    #expect(BashGate.hookDecision(stdin: Data()).exitCode == 2)
}
