import AVFoundation
import Foundation

public enum RecordingError: Error, Equatable, LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case engineFailed(String)
    case writeFailed(String)
    case noAudioCaptured
    case alreadyRecording
    case notRecording

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
        case .alreadyRecording:
            return "A recording is already in progress"
        case .notRecording:
            return "No recording is in progress"
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
    /// Called on the audio thread, thinned out to 20 times a second. The receiver is
    /// responsible for hopping to whatever thread it needs.
    public typealias LevelHandler = @Sendable (Float) -> Void

    private var session: RecordingSession?

    public init() {}

    public func start(to url: URL, onLevel: LevelHandler? = nil) throws {
        guard session == nil else { throw RecordingError.alreadyRecording }
        guard AudioInputDevice.current() != nil else { throw RecordingError.noInputDevice }

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

        // From here on `url` may exist on disk. Checked before the file is created, so a file
        // that was already there is never removed by a failure of this call.
        let fileExistedBefore = FileManager.default.fileExists(atPath: url.path)

        do {
            let file = try RecordingChecks.openForWriting(url, targetFormat: targetFormat)
            let live = RecordingSession(
                engine: engine, input: input, file: file, url: url, fileExistedBefore: fileExistedBefore
            )
            let sharedConverter = converter
            let counters = live.counters

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
                    counters.addFrames(converted.frameLength)
                } catch {
                    counters.recordWriteFailure(error)
                }

                if let onLevel, counters.shouldEmitLevel(at: ProcessInfo.processInfo.systemUptime, interval: 0.05) {
                    onLevel(AudioLevel.normalized(buffer: converted))
                }
            }

            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw RecordingError.engineFailed(error.localizedDescription)
            }

            session = live
        } catch {
            RecordingChecks.removeIfOwned(url, existedBefore: fileExistedBefore)
            throw error
        }
    }

    /// - Returns: the file that was written.
    /// - Throws: `noAudioCaptured` when the tap never delivered a buffer — which is what a
    ///   denied microphone permission looks like, since the engine starts and the tap installs
    ///   without complaint. The file is removed in that case.
    public func stop() throws -> URL {
        guard let live = session else { throw RecordingError.notRecording }
        session = nil
        live.tearDown()

        let outcome = live.counters.outcome()
        do {
            if let writeError = outcome.writeError {
                throw RecordingError.writeFailed(writeError.localizedDescription)
            }
            try RecordingChecks.validateCaptured(frameCount: outcome.frames)
        } catch {
            RecordingChecks.removeIfOwned(live.url, existedBefore: live.fileExistedBefore)
            throw error
        }
        return live.url
    }

    /// Stops without producing anything: the file this call created is removed. Used when the
    /// owner cancels, and when a hold turns out to be too short to have been meant.
    public func discard() {
        guard let live = session else { return }
        session = nil
        live.tearDown()
        RecordingChecks.removeIfOwned(live.url, existedBefore: live.fileExistedBefore)
    }

    /// Fixed-duration recording, kept for the phase 0 `nohands record` command.
    public func record(seconds: TimeInterval, to url: URL) async throws {
        try start(to: url)
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            discard()
            throw error
        }
        _ = try stop()
    }
}
