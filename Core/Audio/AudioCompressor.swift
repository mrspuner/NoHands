import AVFoundation
import Foundation

/// WAV to AAC, for the week the audio survives after a meeting.
///
/// `AVAssetExportSession` would be shorter but has no way to set a bitrate — its presets pick
/// one — and the whole point here is 32 kbit/s: the disk is 256 GB, and fifteen hours of
/// meetings a week is 3.4 GB of raw WAV against roughly 400 MB compressed.
public enum AudioCompressor {
    public enum Failure: LocalizedError {
        case noAudioTrack(String)
        case encodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack(let name):
                return "No audio track in \(name)"
            case .encodingFailed(let reason):
                return "AAC encoding failed: \(reason)"
            }
        }
    }

    public static func compress(_ source: URL, to destination: URL, bitrate: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack(source.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        // `AVAssetReaderTrackOutput` and `AVAssetWriterInput` are not `Sendable`, and the pump
        // closure below captures both across the `DispatchQueue` boundary that
        // `requestMediaDataWhenReady(on:)` requires. Safe in practice: `startReading` /
        // `startWriting` below are the last touch from this task before the pump takes over, and
        // nothing outside the pump queue touches either object until it resumes the continuation.
        // Same shape as the buffer handling in `MeetingAudioRecorder`.
        nonisolated(unsafe) let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        // `nonisolated(unsafe)` for the same reason as `input` and `output` above: the pump
        // closure below now also reads `writer.status`, across the same `DispatchQueue`
        // boundary, under the same guarantee that nothing outside the pump queue touches it
        // until the continuation resumes.
        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        nonisolated(unsafe) let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MeetingAudioRecorder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitrate,
            ]
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw Failure.encodingFailed(reader.error?.localizedDescription ?? "reader refused to start")
        }
        guard writer.startWriting() else {
            throw Failure.encodingFailed(writer.error?.localizedDescription ?? "writer refused to start")
        }
        writer.startSession(atSourceTime: .zero)

        // `requestMediaDataWhenReady` is a callback API: it calls back on its own queue whenever
        // the encoder has room. The continuation is resumed exactly once, on the one path that
        // stops asking for more data — after `markAsFinished()` AVFoundation does not call the
        // block again.
        let pump = DispatchQueue(label: "nohands.compress")
        // What is deliberately not guarded here: a writer that fails *and* stops calling this
        // block would leave the continuation waiting for ever, and the queue with it. Apple's
        // documented behaviour is the opposite — a failed writer keeps `isReadyForMoreMediaData`
        // true so `append` returns false, which the loop below handles — and the only alternative
        // is a timeout whose duration would be a guess. Cutting a long meeting's encode short
        // because it took longer than a number somebody made up is a worse failure than a rare
        // wedge that relaunching clears.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: pump) {
                while input.isReadyForMoreMediaData {
                    // A writer that has already failed — a full disk is the case this whole
                    // retention design exists for — must not be fed further. Without this the
                    // loop keeps pulling samples into a writer that will never accept them.
                    guard writer.status == .writing else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        // Anything thrown from here on leaves a truncated file at exactly the path the caller
        // expects the compressed track to be: some real audio, silently cut short. The week the
        // audio survives exists so a bad result can be re-run, and debris that looks like a
        // result defeats that — a caller checking whether the file is there would be misled.
        // So the failure takes the file with it.
        func abandon(_ reason: String) -> Failure {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destination)
            return Failure.encodingFailed(reason)
        }

        if reader.status == .failed {
            throw abandon(reader.error?.localizedDescription ?? "reading failed")
        }
        guard writer.status == .completed else {
            throw abandon(writer.error?.localizedDescription ?? "writing did not complete")
        }
    }
}
