import Foundation

/// Puts the summary into a meeting file phase 2б already wrote.
///
/// Insertion, not rendering: the transcript below and the front matter above pass through
/// untouched, because the owner edits speaker labels by hand and phase 2г will edit them too.
/// Rewriting the file from parsed values would quietly discard both.
public enum SummaryInsertion {
    public enum Failure: LocalizedError, Equatable {
        case noTranscriptSection(String)

        public var errorDescription: String? {
            switch self {
            case .noTranscriptSection(let name):
                return "No \(TranscriptIndex.heading) section in \(name) — nothing this pipeline wrote"
            }
        }
    }

    /// `insert` is what the application does, `replace` is what the CLI does while a threshold
    /// is being tuned. The difference is deliberately the only one between the two paths.
    public enum Mode: Equatable, Sendable {
        case insert
        case replace
    }

    public static let summaryHeading = "## Саммари"
    public static let decisionsHeading = "## Решения"
    public static let tasksHeading = "## Задачи"
    public static let openIssuesHeading = "## Открытые вопросы"
    public static let unfoundedNote = "основание не найдено"
    /// Written in full rather than left blank: an empty column in an archive reads as an
    /// oversight, while these two say plainly that nobody named an owner or a date out loud.
    public static let noOwnerNote = "не назначено"
    public static let noDueNote = "срок не назван"

    public static func hasSummary(_ file: String) -> Bool {
        file.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == summaryHeading
        }
    }

    public static func apply(
        summary: MeetingSummary,
        decisions: [CheckedDecision],
        tasks: [CheckedTask],
        to file: String,
        named name: String,
        mode: Mode
    ) throws -> String {
        let lines = file.components(separatedBy: "\n")
        guard
            let heading = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == TranscriptIndex.heading
            })
        else { throw Failure.noTranscriptSection(name) }

        let frontMatterEnd = endOfFrontMatter(lines)
        let afterFrontMatter = frontMatterEnd.map { $0 + 1 } ?? 0
        var front = Array(lines[..<afterFrontMatter])
        var middle = Array(lines[afterFrontMatter..<heading])
        let tail = Array(lines[heading...])

        if mode == .replace {
            front.removeAll { $0.hasPrefix("title:") }
            middle = withoutSummarySections(middle)
        }
        // Only into an existing front matter block: there is no sensible place for `title:` in a
        // file that has none, and inventing one would be rewriting somebody else's file.
        if !summary.title.isEmpty, frontMatterEnd != nil,
            !front.contains(where: { $0.hasPrefix("title:") }) {
            front.insert("title: \(MeetingMarkdown.quoted(summary.title))", at: front.count - 1)
        }

        while middle.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            middle.removeLast()
        }

        var result = front
        result.append(contentsOf: middle)
        result.append("")
        result.append(contentsOf: sections(summary, decisions, tasks))
        result.append(contentsOf: tail)
        return result.joined(separator: "\n")
    }

    /// A failure that trying again cannot fix, written where it will be read: into the file.
    ///
    /// It goes in as a `## Саммари` section on purpose — that is what marks the file as done, so
    /// the pass stops offering it, instead of raising the same hopeless meeting at every launch.
    public static func refusal(_ reason: String, to file: String, named name: String) throws -> String {
        try apply(
            summary: MeetingSummary(title: "", summary: ["Конспект не сделан: \(reason)"], decisions: []),
            decisions: [],
            tasks: [],
            to: file,
            named: name,
            mode: .insert
        )
    }

    private static func sections(
        _ summary: MeetingSummary,
        _ decisions: [CheckedDecision],
        _ tasks: [CheckedTask]
    ) -> [String] {
        var out = [summaryHeading, ""]
        out.append(contentsOf: summary.summary.map { "- \($0)" })
        out.append("")

        if !decisions.isEmpty {
            out.append(decisionsHeading)
            out.append("")
            for decision in decisions {
                out.append("- \(decision.text) — \(mark(decision.timecode))")
            }
            out.append("")
        }

        if !tasks.isEmpty {
            out.append(tasksHeading)
            out.append("")
            for task in tasks {
                let owner = task.owner.isEmpty ? noOwnerNote : task.owner
                let due = task.due.isEmpty ? noDueNote : task.due
                out.append("- \(task.text) — \(owner) — \(due) — \(mark(task.timecode))")
            }
            out.append("")
        }

        if !summary.openIssues.isEmpty {
            out.append(openIssuesHeading)
            out.append("")
            out.append(contentsOf: summary.openIssues.map { "- \($0)" })
            out.append("")
        }

        return out
    }

    private static func mark(_ timecode: TimeInterval?) -> String {
        guard let timecode else { return unfoundedNote }
        return "[\(MeetingMarkdown.timestamp(timecode))]"
    }

    /// Drops the `## Саммари`, `## Решения`, `## Задачи` and `## Открытые вопросы` blocks and
    /// nothing else.
    ///
    /// Each block runs from its heading to the next `## ` heading or to the end of the region.
    /// Clearing the whole region instead would be indistinguishable on a file this pipeline
    /// wrote, and wrong on the owner's own: `meeting summarize` exists to be re-run over the
    /// real archive while a threshold is tuned, and a note somebody typed above the transcript
    /// has to survive that. The same line also cost a file without front matter its `---`.
    private static func withoutSummarySections(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var dropping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == summaryHeading || trimmed == decisionsHeading
                || trimmed == tasksHeading || trimmed == openIssuesHeading {
                dropping = true
                continue
            }
            if dropping, trimmed.hasPrefix("## ") { dropping = false }
            if !dropping { kept.append(line) }
        }
        return kept
    }

    private static func endOfFrontMatter(_ lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        return lines.dropFirst().firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" }
    }
}
