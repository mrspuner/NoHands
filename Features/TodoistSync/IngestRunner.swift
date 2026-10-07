import Foundation

public protocol ProcessRunning: Sendable {
    /// - Returns: the exit code. Throws `IngestError.timedOut` after terminating a child that
    ///   outlived `timeout`, `IngestError.launchFailed` when it could not start.
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32
}

public enum IngestError: Error, Equatable, LocalizedError {
    case failed(Int32)
    case timedOut
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let code): return "BigHead ingest exited with code \(code)"
        case .timedOut: return "BigHead ingest did not finish in time and was stopped"
        case .launchFailed(let reason): return "BigHead ingest could not start: \(reason)"
        }
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Output goes nowhere: a pipe nobody drains fills up and hangs the child.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                // Launch failed: the waiter below is never started, so this is the only resume.
                continuation.resume(throwing: IngestError.launchFailed(error.localizedDescription))
                return
            }
            // Exactly one branch below runs, so the continuation resumes exactly once.
            DispatchQueue.global().async {
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        // Foundation reaps the child; wait for it so no zombie outlives the call.
                        _ = finished.wait(timeout: .now() + 2)
                    }
                    continuation.resume(throwing: IngestError.timedOut)
                } else {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }
    }
}

/// Runs BigHead's agent on one raw file, with file tools only.
public struct IngestRunner: Sendable {
    private let claude: URL
    private let bighead: URL
    private let runner: any ProcessRunning
    private let timeout: TimeInterval

    public init(claude: URL, bighead: URL, runner: any ProcessRunning, timeout: TimeInterval = 600) {
        self.claude = claude
        self.bighead = bighead
        self.runner = runner
        self.timeout = timeout
    }

    public func ingest(rawFile: String) async throws {
        let code = try await runner.run(executable: claude, arguments: Self.arguments(rawFile: rawFile),
                                        directory: bighead, timeout: timeout)
        guard code == 0 else { throw IngestError.failed(code) }
    }

    /// - `-p <prompt>`: non-interactive run; the prompt stays right after `-p`.
    /// - `--restricted`: drops command/code-running tools and WebFetch, ignores user/project/local
    ///   settings, and confines file tools to the working directory (BigHead).
    /// - `--strict-mcp-config` (no `--mcp-config`): loads no MCP servers, so the user's connectors
    ///   are unreachable.
    /// - `--permission-mode acceptEdits`: file edits need no prompt in an unattended run.
    /// - `--tools`: restricts the built-in set to file tools. (`--allowedTools` would only
    ///   pre-approve, not remove, tools such as Bash.) Not `--bare`: it disables OAuth login.
    static func arguments(rawFile: String) -> [String] {
        ["-p", prompt(rawFile: rawFile), "--restricted", "--strict-mcp-config",
         "--permission-mode", "acceptEdits", "--tools", "Read,Edit,Write,Glob,Grep"]
    }

    static func prompt(rawFile: String) -> String {
        """
        Сделай ingest файла \(rawFile) по разделу «Todoist → входящие» в AGENTS.md. \
        Это автоматический запуск из NoHands: вопросов не задавай, в Todoist ничего не отправляй, \
        обработай только этот файл, запиши ingest в wiki/log.md.
        """
    }
}
