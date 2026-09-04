import AVFoundation
import Foundation

/// How loud a stretch of a track actually was, and which utterances that lets through.
///
/// Exists because of one fact about the owner's setup: the microphone is an iPhone lying on the
/// desk, and it hears the room. The microphone track is supposed to mean "me"; keeping that
/// promise is recognition's job, not the microphone's, so the room is removed here rather than
/// suppressed at capture — capture would have cost the two tracks their shared clock.
public enum PhraseLevel {
    /// Windows this long are measured separately and the loudest one wins.
    public static let windowSeconds: TimeInterval = 0.1

    /// Loudest window inside the span, in dBFS. Silence returns `-infinity`, which compares
    /// below every threshold without needing a special case at the call site.
    public static func peakDBFS(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let firstFrame = max(0, AVAudioFramePosition(start * rate))
        let lastFrame = min(file.length, AVAudioFramePosition(end * rate))
        guard lastFrame > firstFrame else { return -.infinity }

        let windowFrames = AVAudioFrameCount(max(1, windowSeconds * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return -.infinity
        }

        var peak: Float = 0
        var frame = firstFrame
        while frame < lastFrame {
            file.framePosition = frame
            let remaining = lastFrame - frame
            let count = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData else { break }
            peak = max(peak, AudioLevel.rms(channel[0], count: Int(buffer.frameLength)))
            frame += AVAudioFramePosition(buffer.frameLength)
        }

        guard peak > 0 else { return -.infinity }
        return 20 * log10(peak)
    }

    /// Utterances loud enough to be the owner rather than the room.
    ///
    /// Takes the measurement as a closure instead of an array of levels: pairing two arrays by
    /// index is the kind of coupling that survives every test and breaks the first time someone
    /// filters one of them.
    public static func passing(
        _ utterances: [Utterance],
        thresholdDBFS: Float,
        level: (Utterance) throws -> Float
    ) rethrows -> [Utterance] {
        try utterances.filter { try level($0) >= thresholdDBFS }
    }
}
