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

    public func scanArchive() async {
        guard config.summaryEnabled else { return }
        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
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
            return .permanent("The file carries no transcript lines")
        }
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
            let reason = failure.localizedDescription
            if let refused = try? SummaryInsertion.refusal(
                reason, to: text, named: file.lastPathComponent
            ) {
                try? Data(refused.utf8).write(to: file, options: .atomic)
            }
            return .permanent(reason)
        } catch let failure as SummaryInsertion.Failure {
            return .permanent(failure.localizedDescription)
        } catch {
            return .temporary(error.localizedDescription)
        }
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
