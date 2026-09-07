import Core
import Foundation

/// Adds the summary to meeting files that do not have one, one file at a time.
///
/// Works over the archive rather than over the queue on purpose. Inside `MeetingQueue.process` a
/// failed summary would mark a perfectly good meeting `failed`, and its retry would find the
/// tracks already compressed, throw `alreadyCompressed` and leave the meeting broken for ever.
/// Over the archive the state is the file itself, an old file without a summary is picked up for
/// free, and the audio is not needed at all.
public actor MeetingSummarizer {
    public struct Outcome: Equatable, Sendable {
        public var file: String
        public var failure: String?

        public init(file: String, failure: String?) {
            self.file = file
            self.failure = failure
        }
    }

    private enum Step {
        case done
        /// Written into the file; the pass continues.
        case permanent(String)
        /// Left for next time; the pass stops.
        case temporary(String)
    }

    private let archive: URL
    private var config: MeetingsConfig
    private var makeRunner: @Sendable () -> any SummaryRunning
    private let report: @Sendable (Outcome) -> Void
    /// See `scanArchive` for why one pass at a time is a requirement rather than a tidiness.
    private var scanning = false
    private var rescanRequested = false

    public init(
        archive: URL = MeetingFolder.archiveURL,
        config: MeetingsConfig,
        makeRunner: @escaping @Sendable () -> any SummaryRunning,
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.archive = archive
        self.config = config
        self.makeRunner = makeRunner
        self.report = report
    }

    /// Applied in place, exactly like `MeetingQueue.update`: a second summarizer over the same
    /// archive would race the first one's writes.
    public func update(
        config: MeetingsConfig,
        makeRunner: @escaping @Sendable () -> any SummaryRunning
    ) {
        self.config = config
        self.makeRunner = makeRunner
    }

    /// One pass at a time, exactly like `MeetingQueue.drain`, and for a sharper reason: a pass
    /// suspends for minutes per file inside the runner, and three callers can start one — the
    /// queue's outcome, launch, and every «Перечитать конфиг». Overlapping passes would read the
    /// same file before the first had written it, find no summary, and summarise it twice; the
    /// later write would then land on text read before the earlier one, silently undoing any
    /// hand edit made in that window. `rescanRequested` keeps the request rather than dropping
    /// it: a file that appeared mid-pass gets exactly one more pass afterwards, not an
    /// overlapping one.
    public func scanArchive() async {
        guard config.summaryEnabled else { return }
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        defer { scanning = false }
        repeat {
            rescanRequested = false
            await pass()
        } while rescanRequested
    }

    private func pass() async {
        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Selection, per spec §10: the heading present and no summary yet. A file without
            // the heading is not ours — `~/Meetings` is an Obsidian folder, notes live there —
            // and is skipped in silence. Reporting it would raise the same failure at every
            // launch for ever, because nothing about the file will ever change.
            guard TranscriptIndex.hasHeading(text) else { continue }
            guard !SummaryInsertion.hasSummary(text) else { continue }
            switch await summarize(file, text: text) {
            case .done:
                report(Outcome(file: file.lastPathComponent, failure: nil))
            case .permanent(let reason):
                report(Outcome(file: file.lastPathComponent, failure: reason))
            case .temporary(let reason):
                report(Outcome(file: file.lastPathComponent, failure: reason))
                return
            }
        }
    }

    private func summarize(_ file: URL, text: String) async -> Step {
        let index = TranscriptIndex.parse(text)
        // No reply lines at all: either not a meeting file or one edited past recognition. Not a
        // model problem, and trying again will not change it.
        guard !index.lines.isEmpty else {
            return refuse("The file carries no transcript lines", file: file, text: text)
        }
        // Snapshotted once, before the only suspension point below. Actors are reentrant:
        // `update(config:makeRunner:)` can land while `summarize` is suspended on the runner, and
        // a file scored against a threshold that was not in effect when its processing began
        // would be a defect nobody could reproduce from outside this actor — same reasoning as
        // `MeetingQueue.process`'s own snapshot.
        let config = self.config
        do {
            let summary = try await makeRunner().summarize(transcript: index.body)
            let decisions = QuoteMatch.check(
                summary.decisions, against: index, threshold: config.quoteMatchRatio
            )
            let updated = try SummaryInsertion.apply(
                summary: summary,
                decisions: decisions,
                to: text,
                named: file.lastPathComponent,
                mode: .insert
            )
            try Data(updated.utf8).write(to: file, options: .atomic)
            return .done
        } catch let failure as any SummaryFailure where failure.isPermanent {
            return refuse(failure.localizedDescription, file: file, text: text)
        } catch {
            // `SummaryInsertion.Failure` used to have a clause of its own here, returning
            // `.permanent` without writing anything into the file — the forever-loop shape: a
            // notice at every launch and nothing that could ever mark the file done. Selection
            // in `pass()` makes it unreachable, and if it ever becomes reachable again a
            // temporary failure stops the pass, which is loud and visible, instead of quietly
            // repeating for ever.
            return .temporary(error.localizedDescription)
        }
    }

    /// Writes the reason into the file as its `## Саммари` section so `hasSummary` stops
    /// offering it — the whole point of a permanent failure being permanent. `try?` on the write:
    /// a failed refusal write must still return rather than crash the pass over one bad file.
    private func refuse(_ reason: String, file: URL, text: String) -> Step {
        if let refused = try? SummaryInsertion.refusal(
            reason, to: text, named: file.lastPathComponent
        ) {
            try? Data(refused.utf8).write(to: file, options: .atomic)
        }
        return .permanent(reason)
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
