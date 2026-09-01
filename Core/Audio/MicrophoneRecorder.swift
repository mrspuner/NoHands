import AVFoundation
import Foundation

public enum RecordingError: Error, LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device is available"
        case .unsupportedFormat:
            return "Cannot convert the input format to 16 kHz mono"
        case .engineFailed(let reason):
            return "Audio engine failed: \(reason)"
        }
    }
}

/// Records the default input into a 16 kHz mono WAV file — the format both engines accept
/// without resampling.
public actor MicrophoneRecorder {
    public init() {}

    public func record(seconds: TimeInterval, to url: URL) async throws {
        guard AudioInputDevice.current() != nil else {
            throw RecordingError.noInputDevice
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw RecordingError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecordingError.unsupportedFormat
        }

        // The tap closure runs on a real-time audio thread and captures both of these.
        // Neither AVAudioFile nor AVAudioConverter is Sendable, and Swift 6 rejects the
        // capture without an explicit opt-out. Safe here because the tap is the only writer
        // and it is removed before this function returns.
        nonisolated(unsafe) let file = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        nonisolated(unsafe) let sharedConverter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            var consumed = false
            var conversionError: NSError?
            sharedConverter.convert(to: converted, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }

            guard conversionError == nil, converted.frameLength > 0 else { return }
            try? file.write(from: converted)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.engineFailed(error.localizedDescription)
        }

        try await Task.sleep(for: .seconds(seconds))

        engine.stop()
        input.removeTap(onBus: 0)
    }
}
