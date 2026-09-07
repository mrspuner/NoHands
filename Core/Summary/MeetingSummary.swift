import Foundation

/// What the model was asked for: a name for the meeting, a few lines about it, and the
/// agreements — each with a quote that has to be found in the transcript before anyone
/// believes it.
public struct MeetingSummary: Equatable, Sendable {
    public struct Decision: Equatable, Sendable {
        public var text: String
        public var quote: String

        public init(text: String, quote: String) {
            self.text = text
            self.quote = quote
        }
    }

    /// Something somebody took on. `owner` and `due` carry what was actually said out loud and
    /// are empty when it was not: until phase 2г the transcript knows only «Я» and «Собеседник»,
    /// so a name appears here only when a participant used one.
    public struct Task: Equatable, Sendable {
        public var text: String
        public var owner: String
        public var due: String
        public var quote: String

        public init(text: String, owner: String, due: String, quote: String) {
            self.text = text
            self.owner = owner
            self.due = due
            self.quote = quote
        }
    }

    public var title: String
    public var summary: [String]
    public var decisions: [Decision]
    public var tasks: [Task]
    public var openIssues: [String]

    public init(
        title: String,
        summary: [String],
        decisions: [Decision],
        tasks: [Task] = [],
        openIssues: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.tasks = tasks
        self.openIssues = openIssues
    }
}

/// A decision after the transcript has been asked about it.
///
/// A separate type rather than a field on `Decision` on purpose: one is what the model said,
/// the other is what we found out about it, and merging them would make it impossible to test
/// the checking apart from the parsing.
public struct CheckedDecision: Equatable, Sendable {
    public var text: String
    /// Share of the quote's longest run of words found in the transcript, 0…1.
    public var ratio: Double
    /// Timecode of the utterance that run starts in, `nil` when the quote did not pass.
    public var timecode: TimeInterval?

    public init(text: String, ratio: Double, timecode: TimeInterval?) {
        self.text = text
        self.ratio = ratio
        self.timecode = timecode
    }
}

/// A task after the transcript has been asked about its quote. Mirrors `CheckedDecision` and
/// carries the two fields a decision does not have.
public struct CheckedTask: Equatable, Sendable {
    public var text: String
    public var owner: String
    public var due: String
    public var ratio: Double
    public var timecode: TimeInterval?

    public init(text: String, owner: String, due: String, ratio: Double, timecode: TimeInterval?) {
        self.text = text
        self.owner = owner
        self.due = due
        self.ratio = ratio
        self.timecode = timecode
    }
}
