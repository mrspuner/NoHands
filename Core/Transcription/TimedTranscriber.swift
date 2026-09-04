import Foundation

/// Turns an audio file into words with the times they were spoken at.
///
/// Separate from `Transcriber` rather than an addition to it: dictation needs a string and
/// nothing else, and `ScribeTranscriber` has no timings to give. A protocol exists here at all
/// — despite the project's rule against abstracting single implementations — because
/// `MeetingQueue` has to be testable without a 470 MB model, exactly as `MeetingCapture` exists
/// so the coordinator can be tested without a screen recording.
public protocol TimedTranscriber: Sendable {
    func transcribeTimed(audio url: URL) async throws -> [TimedWord]
}
