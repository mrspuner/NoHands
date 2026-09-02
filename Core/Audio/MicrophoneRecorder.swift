import AVFoundation
import Foundation

public enum RecordingError: Error, Equatable, LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case engineFailed(String)
    case writeFailed(String)
    case noAudioCaptured

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
        case .noAudioCaptured:
            return "No audio was captured — the app likely lacks microphone permission; " +
                "check System Settings > Privacy & Security > Microphone"
        }
    }
}

/// Checks `MicrophoneRecorder.record` has to make around the file it writes, kept separate so
/// they're testable without a live microphone.
enum RecordingChecks {
    /// A denied microphone permission lets `AVAudioEngine` start and the tap install without
    /// error, it just never delivers a buffer — which used to produce a WAV with a valid header
    /// and zero seconds of audio that `record` reported as a success. Zero captured frames is
    /// that failure, not silence.
    static func validateCaptured(frameCount: AVAudioFrameCount) throws {
        guard frameCount > 0 else {
            throw RecordingError.noAudioCaptured
        }
    }

    /// Removes `url` only when this call is the one that created it, so a failure never deletes
    /// a file that predates the recording. `try?`: the caller is already about to see the real
    /// failure that triggered this cleanup, and a removal error would only bury it.
    static func removeIfOwned(_ url: URL, existedBefore: Bool) {
        guard !existedBefore else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `AVAudioFile(forWriting:settings:)` — the plain initializer — opens the file for writing
    /// "using the standard format (deinterleaved floating point)" (Apple's doc comment on that
    /// initializer in `AVAudioFile.h`), no matter what `settings` says. That standard format is
    /// `processingFormat`: what `write(from:)` requires of the buffer it's handed, as opposed to
    /// `fileFormat`, the on-disk encoding `settings` actually controls. Buffers built in
    /// `targetFormat` (Int16) never matched a Float32 `processingFormat`, and `write(from:)`
    /// catches that mismatch deep inside AudioToolbox as a process trap (`SIGTRAP` inside
    /// `-[AVAudioFile writeFromBuffer:error:]`) — not a Swift error, so no `catch` here could
    /// have caught or reported it; the process just died mid-write, leaving the header-only WAV
    /// that both the original bug report and this repo's own crash logs show. The designated
    /// initializer below takes `commonFormat`/`interleaved` explicitly, pinning
    /// `processingFormat` to `targetFormat`'s so it actually matches the buffers the tap builds.
    /// `fileFormat` — what lands on disk — still comes from `settings` alone and is unaffected.
    static func openForWriting(_ url: URL, targetFormat: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )
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

        // From here on `url` may exist on disk (AVAudioFile below creates it). Any error past
        // this point is routed through the outer `catch` so it removes what this call created
        // instead of leaving a header-only WAV that looks like a successful, silent recording —
        // see RecordingError.noAudioCaptured. Checked before the file is created, so a file that
        // already existed at `url` is never touched.
        let fileExistedBefore = FileManager.default.fileExists(atPath: url.path)

        do {
            // The tap closure runs on a real-time audio thread and captures these. AVAudioFile
            // and AVAudioConverter are themselves Sendable on this SDK, so they need no opt-out.
            // `writeError` and `framesWritten` are plain vars written from that audio thread;
            // `nonisolated(unsafe)` opts them out of Swift 6's capture check. They are only safe
            // to read once the tap can no longer fire, which is why every read goes through
            // `tearDown()` first — see below.
            let file = try RecordingChecks.openForWriting(url, targetFormat: targetFormat)
            let sharedConverter = converter
            nonisolated(unsafe) var writeError: Error?
            nonisolated(unsafe) var framesWritten: AVAudioFrameCount = 0

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
                    framesWritten += converted.frameLength
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

            // Tear down before reading writeError or framesWritten: the tap must be guaranteed
            // to no longer be able to fire, or a buffer delivered in the gap between the sleep
            // returning and this check could write a value that's never read. Calling tearDown()
            // here, ahead of the defer, closes that window on the normal path.
            tearDown()

            if let writeError {
                throw RecordingError.writeFailed(writeError.localizedDescription)
            }
            try RecordingChecks.validateCaptured(frameCount: framesWritten)
        } catch {
            RecordingChecks.removeIfOwned(url, existedBefore: fileExistedBefore)
            throw error
        }
    }
}
