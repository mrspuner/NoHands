import Foundation
import os

/// One poll of Todoist per `tick()`: learn what changed, drop what BigHead must not hear,
/// write it into BigHead's `raw/`, and have BigHead's agent ingest it. Never throws: a failure
/// becomes a line for the menu and the next tick tries again.
public actor InboundPoller {
    private static let logger = Logger(subsystem: "com.nohands.app", category: "todoist-inbound")

    private var config: TodoistInboundConfig
    private let sync: any TodoistSyncing
    private let store: SyncStateStore
    private let journal: ActionJournal
    private var ingest: IngestRunner
    private let now: @Sendable () -> Date
    private let report: @Sendable (String?) -> Void
    private var running = false

    public init(config: TodoistInboundConfig, sync: any TodoistSyncing, store: SyncStateStore, journal: ActionJournal,
                ingest: IngestRunner, now: @escaping @Sendable () -> Date = Date.init,
                report: @escaping @Sendable (String?) -> Void) {
        self.config = config
        self.sync = sync
        self.store = store
        self.journal = journal
        self.ingest = ingest
        self.now = now
        self.report = report
    }

    /// Takes effect from the next tick; a poll already running keeps the settings it started with.
    public func update(config: TodoistInboundConfig) {
        self.config = config
        ingest = IngestRunner(claude: URL(fileURLWithPath: config.claudePath),
                              bighead: URL(fileURLWithPath: config.bigheadPath),
                              runner: ingest.runner, timeout: ingest.timeout)
    }

    public func tick() async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            try await poll()
            report(nil)
        } catch let error as IngestError {
            switch error {
            case .failed(let code): Self.logger.error("todoist ingest failed: exit code \(code, privacy: .public)")
            case .timedOut: Self.logger.error("todoist ingest failed: timed out")
            case .launchFailed: Self.logger.error("todoist ingest failed: could not launch")
            }
            report("todoist: ingest не прошёл — \(error.localizedDescription)")
        } catch {
            Self.logger.error("todoist poll failed: \(String(describing: type(of: error)), privacy: .public)")
            report("todoist: опрос не прошёл — \(error.localizedDescription)")
        }
    }

    private func poll() async throws {
        let state = try await store.load()
        let response = try await sync.sync(token: state.syncToken ?? "*")

        // A first poll, or Todoist resetting the token: learn the layout, report nothing.
        if state.syncToken == nil || response.fullSync {
            let map = Dictionary(response.projects.filter { !$0.isDeleted }.map {
                ($0.id, ProjectInfo(name: $0.name, parentID: $0.parentID))
            }, uniquingKeysWith: { _, last in last })
            let work = InboundEvents.workItemIDs(items: response.items, projects: map, areas: config.areas,
                                                 ignored: Set(state.ignored))
            try await store.saveSync(token: response.syncToken, projects: map, workItems: work)
            return
        }

        // An unreadable journal must not stop the poll; without it echoes may slip through,
        // and applying an echo in BigHead changes nothing.
        let entries: [ActionJournal.Entry]
        do {
            entries = try await journal.entries()
        } catch {
            Self.logger.error("todoist journal unreadable: \(String(describing: type(of: error)), privacy: .public)")
            entries = []
        }
        let config = self.config
        let ingest = self.ingest
        let batch = InboundEvents.build(response: response, previous: state.projects, areas: config.areas,
                                        ignored: Set(state.ignored), workItems: Set(state.workItems), journal: entries)
        let rawDirectory = URL(fileURLWithPath: config.bigheadPath).appendingPathComponent("raw")
        let polledAt = now()

        if !batch.projects.isEmpty {
            _ = try InboundRawFile.write(InboundRawFile.renderProjects(batch.projects, polledAt: polledAt),
                                         kind: "todoist-project", at: polledAt, rawDirectory: rawDirectory)
        }
        var taskFile: URL?
        if !batch.tasks.isEmpty {
            taskFile = try InboundRawFile.write(InboundRawFile.renderTasks(batch.tasks, polledAt: polledAt),
                                                kind: "todoist", at: polledAt, rawDirectory: rawDirectory)
        }
        // Saved before the agent runs: a crash during ingest must not fetch the same changes
        // again and write them twice.
        // Skipped when nothing moved: most polls are empty, and each save rewrites the file.
        let unchanged = response.syncToken == state.syncToken && batch.tasks.isEmpty
            && batch.projects.isEmpty && batch.projectMap == state.projects
            && batch.workItems == Set(state.workItems)
        if !unchanged {
            try await store.saveSync(token: response.syncToken, projects: batch.projectMap, workItems: batch.workItems)
        }
        Self.logger.info("todoist poll: \(batch.tasks.count, privacy: .public) task events, \(batch.projects.count, privacy: .public) new projects")

        if let taskFile {
            try await ingest.ingest(rawFile: "raw/\(taskFile.lastPathComponent)")
        }
    }
}
