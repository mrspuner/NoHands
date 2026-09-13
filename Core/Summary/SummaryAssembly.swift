import Foundation

/// Builds one meeting summary out of the chunks' partial ones.
///
/// The points — decisions, tasks, open issues — are concatenated here, by code, in meeting order,
/// with neither text nor quote touched. Only the title and the summary come from the model's
/// merge pass, and only when there is more than one partial to merge. That split is what makes a
/// merge unable to damage a quote: it never sees one.
///
/// The cost is named rather than hidden: an agreement voiced in two parts of the meeting now
/// appears twice, and a question raised early and closed late stays in the open issues. Nothing
/// collapses repeats any more. That is a visible nuisance; a merge silently rewriting a quote
/// would be an invisible falsehood.
///
/// Internal rather than public: the only caller is `MLXSummaryRunner`, in the same module, and it
/// is the one place that already guarantees `partials` is never empty. Keeping the type
/// unreachable from outside `Core` makes that guarantee true by construction instead of by
/// convention.
enum SummaryAssembly {
    /// Names a chunk whose answer did not parse. `number` is 1-based, matching what the owner
    /// reads in the file.
    ///
    /// The single source for this sentence: `MLXSummaryRunner` builds it here rather than
    /// inline, and tests read it back through this symbol rather than re-typing the words —
    /// same reasoning as `TranscriptEnvelope` keeping one copy of its markers, after the two
    /// spellings were once allowed to drift apart.
    static func chunkParseFailure(number: Int, of total: Int) -> String {
        "Кусок \(number) из \(total): ответ модели не разобран"
    }

    /// Names a merge pass whose answer did not parse. The points still survive a failed merge —
    /// see `combine` — only the title and the merged summary are lost.
    static let mergeParseFailure = "Сведение не удалось: ответ модели не разобран"

    /// - Parameters:
    ///   - partials: the chunks that parsed, in meeting order. Never empty — a run where nothing
    ///     parsed is a failure, not a summary.
    ///   - refusals: sentences naming what could not be read — a chunk whose answer did not
    ///     parse, or a merge that failed. They go into the summary because that is where the
    ///     owner reads what the file knows about itself.
    ///   - merged: the merge pass's answer, or `nil` when there was one partial or the merge
    ///     failed. Only its `title` and `summary` are used.
    static func combine(
        partials: [MeetingSummary],
        refusals: [String],
        merged: MeetingSummary?
    ) -> MeetingSummary {
        let title: String
        let summary: [String]
        if let merged {
            title = merged.title
            summary = merged.summary + refusals
        } else if partials.count == 1, refusals.isEmpty {
            // A true single-chunk meeting: nothing was refused, so this partial's title has
            // nothing else to misname.
            title = partials[0].title
            summary = partials[0].summary
        } else if partials.count == 1 {
            // One partial survived, but a refusal names a chunk that did not: there were other
            // chunks, so this partial is not the whole meeting any more than any one of several
            // surviving partials would be. Same rule as the branch below, one condition
            // (`refusals.isEmpty`) rather than two: a lone partial only gets to title the meeting
            // when there was truly nothing else to lose.
            title = ""
            summary = partials[0].summary + refusals
        } else {
            // Several partials and no merge: the merge is what would have chosen a title, so
            // there is none to give. An invented one — the first chunk's, say — would name the
            // whole meeting after its opening minutes.
            title = ""
            summary = refusals
        }
        return MeetingSummary(
            title: title,
            summary: summary,
            decisions: partials.flatMap(\.decisions),
            tasks: partials.flatMap(\.tasks),
            openIssues: partials.flatMap(\.openIssues)
        )
    }
}
