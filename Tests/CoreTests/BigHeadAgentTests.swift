import Foundation
import os
import Testing
@testable import Core

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let tmp = FileManager.default.temporaryDirectory

/// Answers every run with a fixed outcome and records how many runs overlapped.
private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let outcome: Result<AgentRun, AgentLaunchError>
    private let delay: Duration
    private let state = OSAllocatedUnfairLock(initialState: (active: 0, maxActive: 0, order: [String]()))

    init(_ outcome: Result<AgentRun, AgentLaunchError>, delay: Duration = .zero) {
        self.outcome = outcome
        self.delay = delay
    }

    var maxActive: Int { state.withLock { $0.maxActive } }
    var order: [String] { state.withLock { $0.order } }

    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun {
        state.withLock { state in
            state.active += 1
            state.maxActive = max(state.maxActive, state.active)
            state.order.append(arguments.first ?? "")
        }
        try? await Task.sleep(for: delay)
        state.withLock { $0.active -= 1 }
        return try outcome.get()
    }
}

private func report(_ outcome: Result<AgentRun, AgentLaunchError>, timeout: TimeInterval = 600) async -> AgentReport {
    await BigHeadAgent(runner: FakeRunner(outcome), pidFile: nil)
        .run(executable: claude, arguments: [], directory: tmp, timeout: timeout)
}

@Test func runsNeverOverlap() async {
    let runner = FakeRunner(.success(AgentRun(exitCode: 0, result: AgentResult(isError: false, terminalReason: nil),
                                              stderrLine: nil)), delay: .milliseconds(50))
    let agent = BigHeadAgent(runner: runner, pidFile: nil)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<5 {
            group.addTask { _ = await agent.run(executable: claude, arguments: ["\(index)"], directory: tmp, timeout: 5) }
            // Gives each run time to reach the actor, so the order of arrival is known.
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    #expect(runner.maxActive == 1)
    #expect(runner.order == ["0", "1", "2", "3", "4"])
}

@Test func aCleanExitWithACleanResultIsSuccess() async {
    let result = await report(.success(AgentRun(exitCode: 0, result: AgentResult(isError: false, terminalReason: nil),
                                                stderrLine: nil)))
    #expect(result.failure == nil)
    #expect(result.exitCode == 0)
}

@Test func aNonZeroExitIsAFailureEvenWhenTheResultSaysError() async {
    let result = await report(.success(AgentRun(exitCode: 1, result: AgentResult(isError: true, terminalReason: "api_error"),
                                                stderrLine: "boom")))
    #expect(result.failure == .exitCode(1, reason: "api_error"))
    #expect(result.exitCode == 1)
    #expect(result.stderrLine == "boom")
}

// The failure seen live: exit 1, `is_error: true`, `terminal_reason: "api_error"`, empty stderr.
// The code still wins the classification, but the reason is the only thing that says why.
@Test func theTerminalReasonIsKeptWhenTheExitCodeWins() async {
    let result = await report(.success(AgentRun(exitCode: 1, result: AgentResult(isError: true, terminalReason: "api_error"),
                                                stderrLine: nil)))
    #expect(result.terminalReason == "api_error")
}

@Test func theTerminalReasonIsKeptOnSuccessToo() async {
    let result = await report(.success(AgentRun(exitCode: 0, result: AgentResult(isError: false, terminalReason: "completed"),
                                                stderrLine: nil)))
    #expect(result.failure == nil)
    #expect(result.terminalReason == "completed")
}

@Test func aNonZeroExitWithoutAResultIsAnExitCodeFailure() async {
    let result = await report(.success(AgentRun(exitCode: 1, result: nil, stderrLine: nil)))
    #expect(result.failure == .exitCode(1, reason: nil))
    #expect(result.terminalReason == nil)
}

@Test func anErrorResultCarriesTheTerminalReason() async {
    let result = await report(.success(AgentRun(exitCode: 0, result: AgentResult(isError: true, terminalReason: "api_error"),
                                                stderrLine: nil)))
    #expect(result.failure == .agentError("api_error"))
}

@Test func anErrorResultWithoutAReasonIsUnknown() async {
    let result = await report(.success(AgentRun(exitCode: 0, result: AgentResult(isError: true, terminalReason: nil),
                                                stderrLine: nil)))
    #expect(result.failure == .agentError("unknown"))
}

@Test func aCleanExitWithoutAResultIsUnreadable() async {
    let result = await report(.success(AgentRun(exitCode: 0, result: nil, stderrLine: nil)))
    #expect(result.failure == .unreadableResult)
}

@Test func aTimeoutCarriesTheConfiguredTimeout() async {
    let result = await report(.failure(.timedOut), timeout: 900)
    #expect(result.failure == .timedOut(900))
    #expect(result.exitCode == nil)
}

@Test func aLaunchFailureIsPassedOn() async {
    let result = await report(.failure(.launchFailed("x")))
    #expect(result.failure == .launchFailed("x"))
    #expect(result.exitCode == nil)
}

@Test func theDurationIsMeasuredByTheClock() async {
    let ticks = OSAllocatedUnfairLock(initialState: [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 107)])
    let agent = BigHeadAgent(
        runner: FakeRunner(.success(AgentRun(exitCode: 0, result: nil, stderrLine: nil))), pidFile: nil,
        clock: { ticks.withLock { $0.removeFirst() } })
    let result = await agent.run(executable: claude, arguments: [], directory: tmp, timeout: 5)
    #expect(result.duration == 7)
}

@Test func failuresDescribeThemselvesInEnglish() {
    #expect(AgentFailure.exitCode(1, reason: nil).errorDescription == "BigHead agent exited with code 1")
    #expect(AgentFailure.exitCode(1, reason: "api_error").errorDescription
        == "BigHead agent exited with code 1 (api_error)")
    #expect(AgentFailure.timedOut(900).errorDescription?.contains("900") == true)
    #expect(AgentFailure.agentError("api_error").errorDescription?.contains("api_error") == true)
}

private func pidFile() -> URL {
    tmp.appendingPathComponent("bighead-agent-test-\(UUID().uuidString).pid")
}

private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

@Test func leftoverIsStoppedOnlyWhenItIsTheAgent() async throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { if sleeper.isRunning { kill(sleeper.processIdentifier, SIGKILL) } }
    let pid = sleeper.processIdentifier
    let file = pidFile()
    let contents = Data("\(pid)\n/bin/sleep".utf8)
    try contents.write(to: file)

    LeftoverAgent.stop(pidFile: file, isAgent: { _, _ in false })
    #expect(isAlive(pid))
    // The file is gone either way: a PID that is not the agent will never become one.
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try contents.write(to: file)
    LeftoverAgent.stop(pidFile: file, isAgent: { _, _ in true })
    sleeper.waitUntilExit()
    #expect(!sleeper.isRunning)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

/// The real case: the runner launches the agent through a symlink, the way `~/.local/bin/claude`
/// points into a versions folder, and the default check must still recognise it.
@Test func anAgentLaunchedThroughASymlinkIsRecognisedAndStopped() async throws {
    let dir = tmp.appendingPathComponent("leftover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appendingPathComponent("claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    let file = dir.appendingPathComponent("bighead-agent.pid")

    let started = Date()
    let run = Task {
        try await SystemProcessRunner().run(executable: link, arguments: ["30"], directory: dir, timeout: 30, pidFile: file)
    }
    while !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(50))

    LeftoverAgent.stop(pidFile: file)
    let finished = try await run.value
    #expect(finished.exitCode == SIGTERM)
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func aLiveProcessAtAnotherPathIsLeftAlone() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { if sleeper.isRunning { kill(sleeper.processIdentifier, SIGKILL) } }
    let file = pidFile()
    try Data("\(sleeper.processIdentifier)\n/usr/local/bin/claude".utf8).write(to: file)

    LeftoverAgent.stop(pidFile: file)
    #expect(isAlive(sleeper.processIdentifier))
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func aMissingPIDFileIsNothingToStop() {
    LeftoverAgent.stop(pidFile: pidFile(), isAgent: { _, _ in Issue.record("must not be asked"); return true })
}

@Test func anUnparsablePIDFileIsRemoved() throws {
    for contents in ["not a pid", "\(getpid())"] {
        let file = pidFile()
        try Data(contents.utf8).write(to: file)
        LeftoverAgent.stop(pidFile: file, isAgent: { _, _ in Issue.record("must not be asked"); return true })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func onlyTheRecordedExecutableIsTheAgent() {
    #expect(!LeftoverAgent.isRecordedExecutable(getpid(), "/usr/local/bin/claude"))
}
