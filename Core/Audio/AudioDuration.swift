import AVFoundation
import Foundation

/// How long an audio file is, in seconds.
///
/// Its own type because three unrelated places need this and each was about to grow a private
/// copy: the transcriber reporting a file too short, the phrase-level measurement, and the
/// pipeline writing `duration` into the meeting's front matter.
public enum AudioDuration {
    public static func seconds(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
