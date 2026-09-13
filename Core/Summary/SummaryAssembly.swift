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
public enum SummaryAssembly {
    /// - Parameters:
    ///   - partials: the chunks that parsed, in meeting order. Never empty — a run where nothing
    ///     parsed is a failure, not a summary.
    ///   - refusals: sentences naming what could not be read — a chunk whose answer did not
    ///     parse, or a merge that failed. They go into the summary because that is where the
    ///     owner reads what the file knows about itself.
    ///   - merged: the merge pass's answer, or `nil` when there was one partial or the merge
    ///     failed. Only its `title` and `summary` are used.
    public static func combine(
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
            title = partials[0].title
            summary = partials[0].summary
        } else if partials.count == 1 {
            title = partials[0].title
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
