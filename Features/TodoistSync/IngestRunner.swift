import Core
import Foundation

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

/// Runs BigHead's agent on one raw file, with file tools only.
public struct IngestRunner: Sendable {
    private let claude: URL
    private let bighead: URL
    let runner: any ProcessRunning
    let timeout: TimeInterval

    public init(claude: URL, bighead: URL, runner: any ProcessRunning, timeout: TimeInterval = 600) {
        self.claude = claude
        self.bighead = bighead
        self.runner = runner
        self.timeout = timeout
    }

    public func ingest(rawFile: String) async throws {
        let run: AgentRun
        do {
            run = try await runner.run(executable: claude, arguments: Self.arguments(rawFile: rawFile),
                                       directory: bighead, timeout: timeout, pidFile: nil)
        } catch AgentLaunchError.timedOut {
            throw IngestError.timedOut
        } catch AgentLaunchError.launchFailed(let reason) {
            throw IngestError.launchFailed(reason)
        }
        guard run.exitCode == 0 else { throw IngestError.failed(run.exitCode) }
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
        Сделай ingest по разделу «Todoist → входящие» в AGENTS.md. \
        Обработай ВСЕ ещё не обработанные raw-файлы вида todoist в порядке имён файлов по возрастанию, \
        файл \(rawFile) — последним. \
        Это автоматический запуск из NoHands: вопросов не задавай, в Todoist ничего не отправляй. \
        Существующие страницы правь через Edit, не перезаписывай их через Write. \
        Для каждого файла запиши отдельную запись ingest в wiki/log.md.
        """
    }
}
