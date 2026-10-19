import Foundation
import Testing
@testable import Core

private let sh = URL(fileURLWithPath: "/bin/sh")
private let tmp = FileManager.default.temporaryDirectory

@Test func aResultIsParsedFromJSON() {
    let json = #"{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Not logged in · Please run /login"}"#
    #expect(AgentResult.parse(Data(json.utf8)) == AgentResult(isError: true, terminalReason: "api_error"))
}

@Test func garbageIsNotAResult() {
    #expect(AgentResult.parse(Data("Not logged in".utf8)) == nil)
}

@Test func theRunnerReadsStdoutAndStderr() async throws {
    let run = try await SystemProcessRunner().run(
        executable: sh, arguments: ["-c", #"echo "{\"is_error\":false}"; echo "boom" >&2; echo "second" >&2; exit 2"#],
        directory: tmp, timeout: 5, pidFile: nil)
    #expect(run.exitCode == 2)
    #expect(run.result == AgentResult(isError: false, terminalReason: nil))
    #expect(run.stderrLine == "boom")
}

@Test func hugeStdoutDoesNotHangAndIsUnparsed() async throws {
    let run = try await SystemProcessRunner().run(
        executable: sh, arguments: ["-c", #"head -c 3000000 /dev/zero | tr "\0" a"#],
        directory: tmp, timeout: 10, pidFile: nil)
    #expect(run.exitCode == 0)
    #expect(run.result == nil)
}

@Test func aLongStderrLineIsCut() async throws {
    let run = try await SystemProcessRunner().run(
        executable: sh, arguments: ["-c", #"head -c 500 /dev/zero | tr "\0" x >&2"#],
        directory: tmp, timeout: 5, pidFile: nil)
    #expect(run.stderrLine?.count == 200)
}

@Test func thePIDFileExistsOnlyWhileRunning() async throws {
    let pidFile = tmp.appendingPathComponent("agent-\(UUID().uuidString).pid")
    // The child sleeps first: the PID is written right after `run()` returns in the parent.
    let run = try await SystemProcessRunner().run(
        executable: sh, arguments: ["-c", #"sleep 0.2; echo "{\"is_error\":false,\"terminal_reason\":\"$(cat "$0") $$\"}""#, pidFile.path],
        directory: tmp, timeout: 5, pidFile: pidFile)
    let parts = try #require(run.result?.terminalReason).split(separator: " ")
    #expect(parts.count == 2)
    #expect(Int32(parts[0]) != nil)
    #expect(parts[0] == parts[1])
    #expect(!FileManager.default.fileExists(atPath: pidFile.path))
}

@Test func theSystemRunnerReportsExitCodes() async throws {
    let run = try await SystemProcessRunner().run(executable: sh, arguments: ["-c", "exit 3"],
                                                  directory: tmp, timeout: 5, pidFile: nil)
    #expect(run.exitCode == 3)
}

@Test func theSystemRunnerKillsAHungChild() async {
    await #expect(throws: AgentLaunchError.timedOut) {
        _ = try await SystemProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                                directory: tmp, timeout: 0.5, pidFile: nil)
    }
}

@Test func aMissingExecutableIsALaunchFailure() async {
    do {
        _ = try await SystemProcessRunner().run(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                                                directory: tmp, timeout: 5, pidFile: nil)
        Issue.record("expected a launch failure")
    } catch let error as AgentLaunchError {
        guard case .launchFailed = error else { Issue.record("wrong error: \(error)"); return }
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func aLingeringGrandchildDoesNotHoldTheCallPastTheTimeout() async throws {
    let started = Date()
    let run = try await SystemProcessRunner().run(
        executable: sh, arguments: ["-c", #"sleep 30 & echo "{\"is_error\":false}""#],
        directory: tmp, timeout: 2, pidFile: nil)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(run.exitCode == 0)
    #expect(run.result == AgentResult(isError: false, terminalReason: nil))
}
