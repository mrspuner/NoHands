import Core
import Foundation

/// Runs BigHead's agent on one raw file, with file tools only.
public struct IngestRunner: Sendable {
    private let claude: URL
    private let bighead: URL
    let agent: BigHeadAgent
    let timeout: TimeInterval

    public init(claude: URL, bighead: URL, agent: BigHeadAgent, timeout: TimeInterval = 600) {
        self.claude = claude
        self.bighead = bighead
        self.agent = agent
        self.timeout = timeout
    }

    /// Throws `AgentFailure` when the shared queue's run did not end in a successful result.
    public func ingest(rawFile: String) async throws {
        let report = await agent.run(executable: claude, arguments: Self.arguments(rawFile: rawFile),
                                     directory: bighead, timeout: timeout)
        if let failure = report.failure { throw failure }
    }

    /// - `-p <prompt>`: non-interactive run; the prompt stays right after `-p`.
    /// - `--restricted`: drops command/code-running tools and WebFetch, ignores user/project/local
    ///   settings, and confines file tools to the working directory (BigHead).
    /// - `--strict-mcp-config` (no `--mcp-config`): loads no MCP servers, so the user's connectors
    ///   are unreachable.
    /// - `--permission-mode acceptEdits`: file edits need no prompt in an unattended run.
    /// - `--tools`: restricts the built-in set to file tools. (`--allowedTools` would only
    ///   pre-approve, not remove, tools such as Bash.) Not `--bare`: it disables OAuth login.
    /// - `--output-format json`: stdout is one result object, so the shared queue can tell an agent
    ///   error from a success even when the exit code is 0.
    static func arguments(rawFile: String) -> [String] {
        ["-p", prompt(rawFile: rawFile), "--restricted", "--strict-mcp-config",
         "--permission-mode", "acceptEdits", "--tools", "Read,Edit,Write,Glob,Grep", "--output-format", "json"]
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
