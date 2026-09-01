import AVFoundation
import Foundation

public enum RecordingError: Error, Equatable, LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case engineFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device is available"
        case .unsupportedFormat:
            return "Cannot convert the input format to 16 kHz mono"
        case .engineFailed(let reason):
            return "Audio engine failed: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write audio to file: \(reason)"
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

        // The tap closure runs on a real-time audio thread and captures these. AVAudioFile and
        // AVAudioConverter are themselves Sendable on this SDK, so they need no opt-out.
        // `writeError` is a plain `Error?` written from that audio thread; `nonisolated(unsafe)`
        // opts it out of Swift 6's capture check. It is only safe to read once the tap can no
        // longer fire, which is why every read of it goes through `tearDown()` first — see below.
        let file = try AVAudioFile(forWriting: url, settings: targetFormat.settings)
        let sharedConverter = converter
        nonisolated(unsafe) var writeError: Error?

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
            do {
                try file.write(from: converted)
            } catch {
                // Keep the first failure; later writes fail the same way and would only
                // overwrite the more informative one.
                if writeError == nil {
                    writeError = error
                }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.engineFailed(error.localizedDescription)
        }

        // Idempotent so it can run both on the normal path (explicitly, before writeError is
        // read below) and from `defer` on every other exit (cancellation, or a throw from this
        // function) without double-removing the tap.
        var isTornDown = false
        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            engine.stop()
            input.removeTap(onBus: 0)
        }
        defer { tearDown() }

        try await Task.sleep(for: .seconds(seconds))

        // Tear down before reading writeError: the tap must be guaranteed to no longer be able
        // to fire, or a buffer delivered in the gap between the sleep returning and this check
        // could write a failure that's never read. Calling tearDown() here, ahead of the defer,
        // closes that window on the normal path.
        tearDown()

        if let writeError {
            throw RecordingError.writeFailed(writeError.localizedDescription)
        }
    }
}
