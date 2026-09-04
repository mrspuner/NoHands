import Foundation

/// One recognised word together with the span of audio it came from.
///
/// Parakeet emits subword tokens, not words; this is what they add up to. The span is what
/// everything downstream needs — splitting speech into utterances, measuring how loud a
/// phrase was, and placing two tracks on one timeline all work on times, not on text.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Averaged over the tokens the word was assembled from. Nothing in phase 2б reads it; it
    /// is carried because the decoder hands it over for free and discarding it here would mean
    /// re-running recognition to get it back.
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
