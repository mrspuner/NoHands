import Core
import Foundation
import os

/// Hands each finished meeting file over to the BigHead agent, once, oldest first.
///
/// Works over the archive for the same reason `MeetingSummarizer` does: the state is the file
/// itself, so a meeting missed while the app was down is picked up by the very next pass. The
/// pass only queues; the agent runs behind it. A fifteen-minute run inside `scan()` would hold
/// up the summary of the next meeting, which runs in the same archive pass.
public actor MeetingIngest {
    public struct Settings: Equatable, Sendable {
        public var claude: URL
        /// The agent's working directory, `bigheadPath`.
        public var bighead: URL
        public var timeout: TimeInterval

        public init(claude: URL, bighead: URL, timeout: TimeInterval) {
            self.claude = claude
            self.bighead = bighead
            self.timeout = timeout
        }
    }

    public enum Failure: Equatable, Sendable {
        /// The agent's run did not succeed: BigHead may not have the meeting.
        case agent(AgentFailure)
        /// The agent succeeded, but the mark was not saved: BigHead has the meeting, and the next
        /// launch will hand it over again. Kept apart from `agent` because "не обработан" would
        /// be false here.
        case notMarked
        /// The state file exists but does not load; nothing is queued over it.
        case stateUnreadable
    }

    public struct Outcome: Equatable, Sendable {
        /// The file name; empty for `stateUnreadable`, which belongs to no meeting.
        public var file: String
        /// `nil` means the file was handed over and marked.
        public var failure: Failure?

        public init(file: String, failure: Failure?) {
            self.file = file
            self.failure = failure
        }
    }

    private static let logger = Logger(subsystem: "com.nohands.app", category: "meeting-ingest")

    private let archive: URL
    private let store: MeetingIngestStore
    private let agent: BigHeadAgent
    private let report: @Sendable (Outcome) -> Void
    /// `nil` switches the feature off: nothing is queued and nothing more is launched.
    private var settings: Settings?

    private var queue: [String] = []
    private var queued = Set<String>()
    /// Failed this session. Without this memory every later pass — one per meeting — would launch
    /// the same failing file again. Cleared by «Перечитать конфиг», and by a restart.
    private var failed = Set<String>()
    private var running: String?
    /// Marked this session. `scan()` reads the state across a suspension, so the copy it holds
    /// can predate a mark the worker made meanwhile; this set closes that window.
    private var handedOver = Set<String>()
    private var worker: Task<Void, Never>?

    public init(
        archive: URL = MeetingFolder.archiveURL,
        store: MeetingIngestStore,
        agent: BigHeadAgent,
        settings: Settings?,
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.archive = archive
        self.store = store
        self.agent = agent
        self.settings = settings
        self.report = report
    }

    /// Takes effect from the next launch; a run already in flight finishes with what it started with.
    public func update(settings: Settings?) {
        self.settings = settings
    }

    public func clearFailures() {
        failed.removeAll()
    }

    /// Queues every file that is ready and returns without waiting for the agent.
    public func scan() async {
        guard settings != nil else { return }
        let state: MeetingIngestState
        do {
            // Loaded every pass rather than cached: it is a small file, and a broken one must be
            // said out loud each time, not only at launch. Nothing is queued over a broken state —
            // its `enabledAt` is the one thing keeping the old archive out.
            state = try await store.load()
        } catch {
            // Foundation's text goes to the log, not the panel: it is English and names a file
            // error, not meeting content.
            Self.logger.error("state unreadable: \(error.localizedDescription, privacy: .public)")
            report(Outcome(file: "", failure: .stateUnreadable))
            return
        }
        let marked = Set(state.handedOver).union(handedOver)
        for file in files() {
            let name = file.lastPathComponent
            guard !marked.contains(name), !failed.contains(name), !queued.contains(name), running != name
            else { continue }
            // A name without the timestamp is somebody's note, not a meeting, and has no date to
            // compare with `enabledAt` anyway.
            guard let stamp = Self.timestamp(ofName: name), stamp >= state.enabledAt else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Ready means summarised, the same two markers `MeetingSummarizer` selects by. A
            // refusal written in place of the summary counts too: BigHead still gets the transcript.
            guard TranscriptIndex.hasHeading(text), SummaryInsertion.hasSummary(text) else { continue }
            queue.append(name)
            queued.insert(name)
        }
        if worker == nil, !queue.isEmpty {
            worker = Task { await self.drain() }
        }
    }

    /// Returns once the queue is empty and nothing runs.
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let name = queue.removeFirst()
            queued.remove(name)
            let file = archive.appendingPathComponent(name)
            // Checked at its turn, not at queueing: the run before it can take fifteen minutes,
            // and the owner may have deleted or renamed the file in between.
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            // Snapshotted for the same reason as `MeetingSummarizer.summarize`'s config: actors
            // are reentrant, and `update(settings:)` may land while this run is suspended.
            guard let settings else { continue }
            running = name
            let result = await agent.run(
                executable: settings.claude,
                arguments: Self.arguments(file: file, meetings: archive),
                directory: settings.bighead,
                timeout: settings.timeout
            )
            var failure = result.failure.map(Failure.agent)
            Self.log(name: name, result: result)
            if failure == nil {
                do {
                    try await store.markHandedOver(name)
                    handedOver.insert(name)
                } catch {
                    // The run happened but nothing remembers it: next launch hands it over again.
                    // Said rather than swallowed, and kept out of this session's passes.
                    Self.logger.error("""
                        \(name, privacy: .public) not marked: \(error.localizedDescription, privacy: .public)
                        """)
                    failure = .notMarked
                }
            }
            if failure != nil { failed.insert(name) }
            running = nil
            report(Outcome(file: name, failure: failure))
        }
        worker = nil
    }

    /// Only the name, exit code, duration, `terminal_reason` when the result carried one and, on
    /// failure, the first stderr line. Never the prompt and never the agent's answer.
    private static func log(name: String, result: AgentReport) {
        let code = result.exitCode.map(String.init) ?? "none"
        let duration = Int(result.duration.rounded())
        // Read from the report rather than the failure: on a non-zero exit the code wins the
        // classification, and the reason — `api_error` with empty stderr — would be lost.
        let reason = result.terminalReason ?? "none"
        guard result.failure != nil else {
            logger.info("""
                handed over \(name, privacy: .public): exit \(code, privacy: .public), \
                \(duration, privacy: .public) s, terminal_reason \(reason, privacy: .public)
                """)
            return
        }
        let stderr = result.stderrLine ?? ""
        logger.error("""
            not handed over \(name, privacy: .public): exit \(code, privacy: .public), \
            \(duration, privacy: .public) s, terminal_reason \(reason, privacy: .public), \
            stderr \(stderr, privacy: .public)
            """)
    }

    /// The agent's command after the executable, in the exact order the spec gives it.
    public static func arguments(file: URL, meetings: URL) -> [String] {
        [
            "-p", "Обработай созвон \(file.path) по разделу «Созвоны → входящие» в AGENTS.md.",
            "--restricted", "--strict-mcp-config",
            "--tools", "Read,Edit,Write,Glob,Grep,ListAgents,SendMessage",
            "--add-dir", meetings.path,
            "--permission-mode", "acceptEdits",
            "--output-format", "json",
        ]
    }

    /// The `yyyy-MM-dd-HHmm` prefix every meeting file carries, read in the local zone because
    /// that is the zone the folder was named in.
    static func timestamp(ofName name: String) -> Date? {
        let prefix = String(name.prefix(15))
        guard prefix.count == 15,
              prefix.wholeMatch(of: /\d{4}-\d{2}-\d{2}-\d{4}/) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.isLenient = false
        return formatter.date(from: prefix)
    }

    private func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
