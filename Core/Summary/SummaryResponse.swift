import Foundation

/// Reads what the model wrote back.
///
/// Strict on purpose: a summary that cannot be parsed is a named failure, never an empty
/// section. An empty section in the archive reads as "nothing was said", which is a claim
/// nobody made.
public enum SummaryResponse {
    public enum Failure: LocalizedError, SummaryFailure, Equatable {
        case notJSON
        case emptySummary

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                return "The model answered with something other than JSON"
            case .emptySummary:
                return "The model returned an empty summary"
            }
        }

        /// Both permanent: generation runs at temperature 0, so the same transcript produces
        /// the same unparseable answer every time — retrying buys nothing. Marking either as
        /// temporary would stop the whole archive pass over one bad meeting, blocking the
        /// summary of every other one behind it.
        public var isPermanent: Bool { true }
    }

    private struct Payload: Decodable {
        struct Decision: Decodable {
            var text: String
            var quote: String
        }

        struct Task: Decodable {
            var text: String
            var owner: String?
            var due: String?
            var quote: String
        }

        var title: String?
        var summary: [String]?
        var decisions: [Decision]?
        var tasks: [Task]?
        var openIssues: [String]?
    }

    public static func parse(_ raw: String) throws -> MeetingSummary {
        let json = stripFence(raw)
        guard let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw Failure.notJSON }

        let summary = (payload.summary ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty else { throw Failure.emptySummary }

        // A decision with no quote is dropped rather than kept unmarked: the whole check rests
        // on the quote, and one that never arrived cannot be told from one that failed.
        let decisions = (payload.decisions ?? []).compactMap { decision -> MeetingSummary.Decision? in
            let text = decision.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = decision.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !quote.isEmpty else { return nil }
            return MeetingSummary.Decision(text: text, quote: quote)
        }

        // A task with no quote is dropped for the same reason a decision is: the whole check
        // rests on the quote, and one that never arrived cannot be told from one that failed.
        let tasks = (payload.tasks ?? []).compactMap { task -> MeetingSummary.Task? in
            let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = task.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !quote.isEmpty else { return nil }
            return MeetingSummary.Task(
                text: text,
                owner: (task.owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                due: (task.due ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                quote: quote
            )
        }
        let openIssues = (payload.openIssues ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return MeetingSummary(
            title: (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary,
            decisions: decisions,
            tasks: tasks,
            openIssues: openIssues
        )
    }

    private static func stripFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
