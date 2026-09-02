import AVFoundation
import Foundation

/// Loudness of one buffer, normalized for drawing.
///
/// The panel shows a live level while you speak. Root mean square answers "how loud", but in
/// linear form it is useless for drawing: ordinary speech sits in the bottom few percent of the
/// range and the bar barely moves. Mapping it to decibels and clamping to a -60…0 dBFS window
/// spreads speech across the whole bar.
public enum AudioLevel {
    /// Quieter than this is not drawn at all.
    static let floorDB: Float = -60

    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768.0
            sum += value * value
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }

    /// Reads the buffer's samples in place — this runs on the real-time audio thread, where
    /// allocating an array per buffer would be the wrong thing to do.
    public static func normalized(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let samples = channel[0]
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index]) / 32768.0
            sum += value * value
        }
        return normalized(rms: Float((sum / Double(count)).squareRoot()))
    }
}
