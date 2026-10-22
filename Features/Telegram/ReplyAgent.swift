import Core
import Foundation
import os

/// One message the owner wrote to the bot.
public struct Reply: Equatable, Sendable {
    public var text: String
    public var at: Date
    /// The `ref` of the bot message this answers, when it answers one that had it.
    public var ref: String?
    /// The text of the bot message this answers, when it is a reply.
    public var quoted: String?

    public init(text: String, at: Date, ref: String?, quoted: String?) {
        self.text = text
        self.at = at
        self.ref = ref
        self.quoted = quoted
    }
}

/// Runs the BigHead agent for the owner's Telegram replies, one batch per run.
///
/// Everything that arrived before a run starts goes into it as one file; what arrives while it
/// runs waits for the next. The runs themselves queue behind meeting and Todoist ingest in the
/// shared `BigHeadAgent`.
public actor ReplyAgent {
    public struct Settings: Equatable, Sendable {
        public var claude: URL
        /// The agent's working directory, `bigheadPath`.
        public var bighead: URL
        public var timeout: TimeInterval
        /// The PreToolUse hook that filters the agent's Bash calls, as argv: executable, arguments.
        public var hook: [String]

        public init(claude: URL, bighead: URL, timeout: TimeInterval, hook: [String]) {
            self.claude = claude
            self.bighead = bighead
            self.timeout = timeout
            self.hook = hook
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// `nil` means the run succeeded.
        public var failure: AgentFailure?

        public init(failure: AgentFailure?) {
            self.failure = failure
        }
    }

    public enum SessionChoice: Equatable, Sendable {
        case new(UUID)
        case resume(UUID)

        var id: UUID {
            switch self {
            case .new(let id), .resume(let id): id
            }
        }
    }

    /// A conversation older than this starts a new agent session.
    static let resumeWindow: TimeInterval = 7200

    private static let logger = Logger(subsystem: "com.nohands.app", category: "telegram")

    private let agent: BigHeadAgent
    private let store: TelegramStateStore
    private let repliesFolder: URL
    private let outbox: URL
    private let meetings: URL
    private let now: @Sendable () -> Date
    private let newSessionID: @Sendable () -> UUID
    private let report: @Sendable (Outcome) -> Void
    /// `nil` switches the feature off: batches are dropped without a launch.
    private var settings: Settings?

    private var pending: [Reply] = []
    private var worker: Task<Void, Never>?

    public init(
        agent: BigHeadAgent,
        store: TelegramStateStore,
        settings: Settings?,
        repliesFolder: URL,
        outbox: URL,
        meetings: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        newSessionID: @escaping @Sendable () -> UUID = UUID.init,
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.agent = agent
        self.store = store
        self.settings = settings
        self.repliesFolder = repliesFolder
        self.outbox = outbox
        self.meetings = meetings
        self.now = now
        self.newSessionID = newSessionID
        self.report = report
    }

    /// Takes effect from the next batch; a run already in flight finishes with what it started with.
    public func update(settings: Settings?) {
        self.settings = settings
    }

    /// Adds the reply to the next batch and returns without waiting for the agent.
    public func enqueue(_ reply: Reply) {
        pending.append(reply)
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    /// Returns once nothing is pending and nothing runs.
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    /// The chat text for a failed run.
    public static func failureText(_ failure: AgentFailure) -> String {
        "Не обработал твоё сообщение: \(failure.ownerReason). Пришли его ещё раз"
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = pending
            pending = []
            // Snapshotted: actors are reentrant, and `update(settings:)` may land mid-run.
            guard let settings else {
                Self.logger.info("dropped \(batch.count, privacy: .public) replies: agent is off")
                continue
            }
            await run(batch, settings: settings)
        }
        worker = nil
    }

    private func run(_ batch: [Reply], settings: Settings) async {
        // Fail closed: Claude Code treats a hook it cannot run (exit 127) as non-blocking, so a
        // missing hook would mean unfiltered Bash.
        guard let hookPath = settings.hook.first, FileManager.default.isExecutableFile(atPath: hookPath) else {
            let path = settings.hook.first ?? ""
            Self.logger.error("bash hook not found, run skipped: \(path, privacy: .public)")
            report(Outcome(failure: .launchFailed("фильтр команд не найден: \(path)")))
            return
        }
        let startedAt = now()
        // Read-only here; the write after the run goes through `update`. A state that does not
        // load gets a new session and no saved conversation: the bot reports the broken file itself.
        var conversation: Conversation?
        var stateReadable = true
        do {
            conversation = try await store.load().conversation
        } catch {
            Self.logger.error("state unreadable: \(error.localizedDescription, privacy: .public)")
            stateReadable = false
        }
        let session = Self.choose(batch: batch, conversation: conversation, now: startedAt,
                                  newSessionID: newSessionID)

        let file: URL
        do {
            file = try writeBatch(batch, at: startedAt)
        } catch {
            Self.logger.error("""
                reply file not written: \(error.localizedDescription, privacy: .public)
                """)
            report(Outcome(failure: .launchFailed("файл реплики не записан")))
            return
        }
        defer {
            // Removed whatever the outcome: the agent has the reply in `raw/` if it got that far,
            // and otherwise the owner sends it again.
            try? FileManager.default.removeItem(at: file)
        }

        let result = await agent.run(
            executable: settings.claude,
            arguments: Self.arguments(replyFile: file, session: session, bighead: settings.bighead,
                                      outbox: outbox, meetings: meetings, replies: repliesFolder,
                                      hook: settings.hook),
            directory: settings.bighead,
            timeout: settings.timeout
        )
        Self.log(batchSize: batch.count, session: session, result: result)

        if stateReadable {
            let finishedAt = now()
            do {
                try await store.update { state in
                    // A failure forgets the session: the next reply starts afresh.
                    state.conversation = result.failure == nil
                        ? Conversation(sessionID: session.id, lastReplyAt: finishedAt)
                        : nil
                }
            } catch {
                Self.logger.error("conversation not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        report(Outcome(failure: result.failure))
    }

    /// A `ref` means the owner answers one particular message, and that context is new to whatever
    /// session was going on; otherwise a recent conversation is continued.
    static func choose(batch: [Reply], conversation: Conversation?, now: Date,
                       newSessionID: () -> UUID) -> SessionChoice {
        if !batch.contains(where: { $0.ref != nil }), let conversation,
           now.timeIntervalSince(conversation.lastReplyAt) < resumeWindow {
            return .resume(conversation.sessionID)
        }
        return .new(newSessionID())
    }

    private func writeBatch(_ batch: [Reply], at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: repliesFolder, withIntermediateDirectories: true)
        let base = Self.formatter("yyyyMMdd-HHmmss").string(from: date)
        var file = repliesFolder.appendingPathComponent(base + ".md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = repliesFolder.appendingPathComponent("\(base)-\(suffix).md")
            suffix += 1
        }
        try Data(Self.render(batch).utf8).write(to: file, options: .withoutOverwriting)
        return file
    }

    /// One block per reply: the time as a heading, `ref` and the quote when present, then the text.
    public static func render(_ batch: [Reply]) -> String {
        let time = formatter("yyyy-MM-dd HH:mm:ss")
        return batch.map { reply in
            var lines = ["## \(time.string(from: reply.at))"]
            if let ref = reply.ref { lines.append("ref: \(ref)") }
            if let quoted = reply.quoted {
                lines += quoted.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
                lines.append("")
            }
            lines.append(reply.text)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    /// Batch size, session kind, exit code, duration and the failure's case. Never the replies.
    private static func log(batchSize: Int, session: SessionChoice, result: AgentReport) {
        let kind = switch session {
        case .new: "new"
        case .resume: "resume"
        }
        let code = result.exitCode.map(String.init) ?? "none"
        let duration = Int(result.duration.rounded())
        guard let failure = result.failure else {
            logger.info("""
                replies \(batchSize, privacy: .public), session \(kind, privacy: .public): \
                exit \(code, privacy: .public), \(duration, privacy: .public) s
                """)
            return
        }
        let reason = switch failure {
        case .exitCode: "exitCode"
        case .agentError: "agentError"
        case .unreadableResult: "unreadableResult"
        case .timedOut: "timedOut"
        case .launchFailed: "launchFailed"
        }
        logger.error("""
            replies \(batchSize, privacy: .public), session \(kind, privacy: .public) failed: \
            exit \(code, privacy: .public), \(duration, privacy: .public) s, \(reason, privacy: .public)
            """)
    }

    /// The agent's command after the executable, in the exact order the spec gives it. `bighead` is
    /// the run's working directory, passed as `directory`, not as an argument.
    public static func arguments(replyFile: URL, session: SessionChoice, bighead: URL, outbox: URL,
                                 meetings: URL, replies: URL, hook: [String]) -> [String] {
        let prompt = "Реплика владельца из Телеграма: \(replyFile.path). Действуй по разделу «Телеграм» "
            + "в AGENTS.md: сначала всё, что схема требует при любом контакте, потом сама реплика. "
            + "Итог — в outbox \(outbox.path)."
        let sessionArguments = switch session {
        // Lower case, as claude names its session files.
        case .new(let id): ["--session-id", id.uuidString.lowercased()]
        case .resume(let id): ["--resume", id.uuidString.lowercased()]
        }
        return [
            "-p", prompt,
            "--restricted", "--strict-mcp-config",
            "--tools", "Read,Edit,Write,Glob,Grep,Bash",
            "--allowedTools",
            "Bash(curl -sS -m 120 -X * http://127.0.0.1:41730/*)",
            "Bash(curl -sS http://127.0.0.1:41730/health)",
            // `--allowedTools` only pre-approves: the hook is what denies everything else.
            // User settings are ignored under `--restricted`, so it is passed here.
            "--settings", hookSettings(hook),
            "--add-dir", meetings.path, "--add-dir", outbox.path, "--add-dir", replies.path,
        ] + sessionArguments + [
            "--permission-mode", "acceptEdits",
            "--output-format", "json",
        ]
    }

    /// The `--settings` JSON that installs `hook` as the PreToolUse hook for Bash. The argv is
    /// single-quoted for the shell Claude Code runs it in: the app's path has spaces.
    public static func hookSettings(_ hook: [String]) -> String {
        let command = hook.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
            .joined(separator: " ")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a lone string cannot fail.
        let quoted = (try? encoder.encode(command)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"#
            + quoted + "}]}]}}"
    }
}
