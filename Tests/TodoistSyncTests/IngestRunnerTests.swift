import Foundation
import Core
import os
import Testing
@testable import TodoistSync

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<Int32, any Error>
    private let calls = OSAllocatedUnfairLock(initialState: [(URL, [String], URL, TimeInterval)]())
    init(_ result: Result<Int32, any Error>) { self.result = result }
    var recorded: [(URL, [String], URL, TimeInterval)] { calls.withLock { $0 } }
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun {
        calls.withLock { $0.append((executable, arguments, directory, timeout)) }
        return AgentRun(exitCode: try result.get(), result: nil, stderrLine: nil)
    }
}

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let bighead = URL(fileURLWithPath: "/tmp/BigHead")

@Test func theAgentIsRunInBigHeadWithFileToolsOnly() async throws {
    let runner = FakeRunner(.success(0))
    try await IngestRunner(claude: claude, bighead: bighead, runner: runner).ingest(rawFile: "raw/2026-10-07-todoist-190640.md")
    let call = try #require(runner.recorded.first)
    #expect(call.0 == claude)
    #expect(call.2 == bighead)
    #expect(call.3 == 600)
    let args = call.1
    #expect(args[0] == "-p")
    #expect(args[1].contains("raw/2026-10-07-todoist-190640.md"))
    #expect(args[1].contains("Todoist → входящие"))
    #expect(args[1].contains("по возрастанию"))
    #expect(args[1].contains("Edit"))
    #expect(Array(args[2...]) == ["--restricted", "--strict-mcp-config", "--permission-mode", "acceptEdits",
                                  "--tools", "Read,Edit,Write,Glob,Grep"])
}

// The agent must reach neither a shell nor MCP connectors (NoHands among them),
// so applying a Todoist event never echoes back.
@Test func theAgentIsSandboxed() throws {
    let args = IngestRunner.arguments(rawFile: "raw/x.md")
    #expect(args.contains("--restricted"))
    #expect(args.contains("--strict-mcp-config"))
    let toolsIndex = try #require(args.firstIndex(of: "--tools"))
    #expect(args[toolsIndex + 1] == "Read,Edit,Write,Glob,Grep")
    for forbidden in ["--allowedTools", "--dangerously-skip-permissions", "bypassPermissions", "--mcp-config"] {
        #expect(!args.contains(forbidden))
    }
    #expect(!args.joined(separator: " ").contains("Bash"))
}

@Test func aNonZeroExitIsAFailure() async {
    await #expect(throws: IngestError.failed(1)) {
        try await IngestRunner(claude: claude, bighead: bighead, runner: FakeRunner(.success(1))).ingest(rawFile: "raw/x.md")
    }
}

@Test func aTimeoutIsPassedOn() async {
    await #expect(throws: IngestError.timedOut) {
        try await IngestRunner(claude: claude, bighead: bighead, runner: FakeRunner(.failure(AgentLaunchError.timedOut))).ingest(rawFile: "raw/x.md")
    }
}
