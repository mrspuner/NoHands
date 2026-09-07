import Foundation

/// Anything that can turn a transcript into a summary. One implementation and one fake, which is
/// the whole reason it exists: the fake is how the queue above it gets tested without a 4.3 GB
/// model and two minutes per case.
public protocol SummaryRunning: Sendable {
    func summarize(transcript: String) async throws -> MeetingSummary
}

/// A failure that knows whether trying again could ever help.
///
/// The distinction is load-bearing: a permanent failure is written into the meeting file and the
/// pass moves on, a temporary one stops the pass and is left for next time. Getting it backwards
/// either closes a meeting for ever over a network hiccup, or re-raises a hopeless one at every
/// launch until the owner starts ignoring the panel.
public protocol SummaryFailure: Error {
    var isPermanent: Bool { get }
}
