import Foundation

/// The one line the panel says when a recording has been through the pipeline.
///
/// The wording lives here rather than in the `App` target for the same reason every other
/// sentence in this feature does: it is the part that can be tested, and the panel's job is to
/// draw it.
public struct MeetingNotice: Equatable, Sendable {
    public var text: String
    /// Red text instead of secondary. The backing stays grey either way — only something
    /// waiting for an answer glows, and this asks nothing.
    public var isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }

    /// The same five seconds every other notice on this panel gets. Re-exported rather than
    /// duplicated: `MeetingMachine.noticeDwell` is internal to this module, and the `App` target
    /// needs a number to pass to `hideNotice(after:)`.
    public static let dwell: TimeInterval = MeetingMachine.noticeDwell

    public static func forOutcome(_ outcome: MeetingQueue.Outcome) -> MeetingNotice {
        if let failure = outcome.failure {
            return MeetingNotice(text: "Не расшифровано: \(failure)", isFailure: true)
        }
        // `minutes` is set on every path that has no failure — the two are written together in
        // `MeetingQueue.run`. The fallback exists because the type cannot say so, not because a
        // meeting of zero minutes is a thing this can report.
        return MeetingNotice(text: "Расшифровано, \(outcome.minutes ?? 0) мин", isFailure: false)
    }
}
