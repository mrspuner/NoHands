import Darwin
import Foundation

public enum AgentFailure: Error, Equatable, LocalizedError {
    case exitCode(Int32)
    /// The agent finished but reported an error; carries `terminal_reason`, or `"unknown"` without one.
    case agentError(String)
    /// Exit code 0, but stdout held no result JSON: nothing says the work was done.
    case unreadableResult
    /// Carries the timeout the run was given.
    case timedOut(TimeInterval)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .exitCode(let code): "BigHead agent exited with code \(code)"
        case .agentError(let reason): "BigHead agent reported an error: \(reason)"
        case .unreadableResult: "BigHead agent printed no readable result"
        case .timedOut(let timeout): "BigHead agent did not finish within \(Int(timeout)) s"
        case .launchFailed(let reason): "BigHead agent could not be launched: \(reason)"
        }
    }
}

public struct AgentReport: Equatable, Sendable {
    /// `nil` means the run succeeded.
    public var failure: AgentFailure?
    /// `nil` when the process never exited on its own (timeout, launch failure).
    public var exitCode: Int32?
    public var stderrLine: String?
    /// Time spent running, not waiting in the queue.
    public var duration: TimeInterval

    public init(failure: AgentFailure?, exitCode: Int32?, stderrLine: String?, duration: TimeInterval) {
        self.failure = failure
        self.exitCode = exitCode
        self.stderrLine = stderrLine
        self.duration = duration
    }
}

/// The one gate every BigHead agent run goes through, one instance per app. Todoist ingest and
/// meeting ingest both edit the same `~/BigHead` files, so two agents at once would race over them.
public actor BigHeadAgent {
    public static var defaultPIDFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/bighead-agent.pid")
    }

    private let runner: any ProcessRunning
    private let pidFile: URL?
    private let clock: @Sendable () -> Date
    /// The last queued run. Awaiting inside an actor method is not enough to serialize: the actor
    /// is reentrant, so a second call would start while the first is suspended in the runner.
    /// Each run waits for its predecessor instead, and the chain keeps the order of arrival.
    private var tail: Task<Void, Never>?

    public init(runner: any ProcessRunning, pidFile: URL? = BigHeadAgent.defaultPIDFile,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.pidFile = pidFile
        self.clock = clock
    }

    public func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async -> AgentReport {
        let previous = tail
        let runner = runner, pidFile = pidFile, clock = clock
        let task = Task {
            await previous?.value
            return await Self.perform(runner: runner, pidFile: pidFile, clock: clock, executable: executable,
                                      arguments: arguments, directory: directory, timeout: timeout)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private static func perform(runner: any ProcessRunning, pidFile: URL?, clock: @Sendable () -> Date,
                                executable: URL, arguments: [String], directory: URL,
                                timeout: TimeInterval) async -> AgentReport {
        if let pidFile {
            // The runner writes the PID with `try?`; a missing folder would silently leave no file,
            // and a leftover agent of this session could then never be found.
            try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        let started = clock()
        do {
            let run = try await runner.run(executable: executable, arguments: arguments, directory: directory,
                                           timeout: timeout, pidFile: pidFile)
            return AgentReport(failure: classify(run), exitCode: run.exitCode, stderrLine: run.stderrLine,
                               duration: clock().timeIntervalSince(started))
        } catch AgentLaunchError.timedOut {
            return AgentReport(failure: .timedOut(timeout), exitCode: nil, stderrLine: nil,
                               duration: clock().timeIntervalSince(started))
        } catch AgentLaunchError.launchFailed(let reason) {
            return AgentReport(failure: .launchFailed(reason), exitCode: nil, stderrLine: nil,
                               duration: clock().timeIntervalSince(started))
        } catch {
            return AgentReport(failure: .launchFailed(error.localizedDescription), exitCode: nil, stderrLine: nil,
                               duration: clock().timeIntervalSince(started))
        }
    }

    /// A non-zero exit wins over `is_error`: the code is what the process itself says about the run.
    static func classify(_ run: AgentRun) -> AgentFailure? {
        if run.exitCode != 0 { return .exitCode(run.exitCode) }
        guard let result = run.result else { return .unreadableResult }
        if result.isError { return .agentError(result.terminalReason ?? "unknown") }
        return nil
    }
}

/// An agent orphaned by the previous app session. `make-app.sh` stops the app with a signal, so
/// `applicationWillTerminate` never runs and the child `claude` keeps editing `~/BigHead` while the
/// new session starts its own. Called at launch, before the first run.
public enum LeftoverAgent {
    public static func stop(pidFile: URL, isAgent: (pid_t) -> Bool = LeftoverAgent.isClaude) {
        guard let data = try? Data(contentsOf: pidFile) else { return }
        // Removed first and in every case: a PID that is not the agent now never becomes one, and an
        // unparsable file can never be acted on.
        try? FileManager.default.removeItem(at: pidFile)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // The PID may have been reused by an unrelated process since; only `claude` is touched.
        guard let pid = pid_t(text), pid > 0, isAlive(pid), isAgent(pid) else { return }

        // Same shape as the runner's timeout: terminate, two seconds of grace, then kill.
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while isAlive(pid), Date() < deadline { usleep(100_000) }
        if isAlive(pid) { kill(pid, SIGKILL) }
    }

    public static func isClaude(_ pid: pid_t) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE is a macro Swift does not import: 4 * MAXPATHLEN.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent == "claude"
    }

    private static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}
