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
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            return rms(base, count: buffer.count)
        }
    }

    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }

    /// Reads the buffer's samples in place — this runs on the real-time audio thread, where
    /// allocating an array per buffer would be the wrong thing to do. Shares its accumulation
    /// with `rms(_:)` below so the tested path and the shipped path can't drift apart.
    public static func normalized(buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        return normalized(rms: rms(channel[0], count: Int(buffer.frameLength)))
    }

    /// The accumulation both `rms(_:)` and `normalized(buffer:)` need: one over an array's
    /// storage, the other straight off the audio buffer's channel pointer.
    private static func rms(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index]) / 32768.0
            sum += value * value
        }
        return Float((sum / Double(count)).squareRoot())
    }

    /// The same accumulation over float samples, which is what `AVAudioFile` hands back when it
    /// is read through its processing format. Public because `PhraseLevel` reads meeting tracks
    /// off disk; the `Int16` path above stays private to the real-time capture that owns it.
    public static func rms(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index])
            sum += value * value
        }
        return Float((sum / Double(count)).squareRoot())
    }
}
