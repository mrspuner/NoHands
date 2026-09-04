import AVFoundation
import Foundation
import ScreenCaptureKit

public enum MeetingCaptureError: Error, Equatable, LocalizedError {
    case permissionDenied
    case noDisplay
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "No screen recording permission — check System Settings > Privacy & " +
                "Security > Screen & System Audio Recording"
        case .noDisplay:
            return "No display is available to capture system audio from"
        case .streamFailed(let reason):
            return "Meeting capture failed: \(reason)"
        }
    }
}

/// Writes both meeting tracks — system audio and microphone — through one `SCStream`.
///
/// One stream rather than two sources is the point: a USB microphone and the system output run
/// off different clocks, and two independent captures drift apart over an hour. Phase 2б merges
/// the tracks by time, and it would inherit that drift as misplaced speaker labels.
///
/// Both files are 16 kHz mono: Parakeet and the voice-embedding model both work at 16 kHz, so
/// 48 kHz would only be downsampled later, after a week of sitting on a 256 GB disk.
public actor MeetingAudioRecorder {
    /// What one capture left behind — including a capture that went wrong.
    ///
    /// A failure and the paths are different pieces of information, and the paths are not worth
    /// less because something failed: half a meeting on disk is still half a meeting. So the
    /// cause is carried here rather than thrown, and the caller decides what to do with a
    /// recording that has one.
    public struct Outcome: Sendable {
        public let systemURL: URL
        public let microphoneURL: URL

        /// When the first buffer of each track arrived, in seconds on the stream's own clock,
        /// or `nil` for a track that never received one.
        ///
        /// The whole reason both tracks come off one `SCStream` is that they are then stamped
        /// by the same clock — but they still begin whenever each output starts delivering.
        /// Phase 2б needs the difference to place words on a shared timeline. Nothing here
        /// pads or trims anything: the number is reported, not corrected, because a correction
        /// applied twice is worse than a gap measured once.
        public let systemStartedAt: Double?
        public let microphoneStartedAt: Double?

        /// What went wrong, named, or `nil` when nothing did.
        public let failure: String?

        public init(
            systemURL: URL,
            microphoneURL: URL,
            systemStartedAt: Double?,
            microphoneStartedAt: Double?,
            failure: String?
        ) {
            self.systemURL = systemURL
            self.microphoneURL = microphoneURL
            self.systemStartedAt = systemStartedAt
            self.microphoneStartedAt = microphoneStartedAt
            self.failure = failure
        }
    }

    public static let sampleRate: Double = 16000
    public static let channelCount: AVAudioChannelCount = 1
    public static let systemFileName = "system.wav"
    public static let microphoneFileName = "mic.wav"

    private let folder: URL
    private let excludedBundleIDs: [String]
    private let onFailureWhileRecording: @Sendable (String) -> Void
    private var stream: SCStream?
    private var writer: TrackWriter?

    /// - Parameter excludedBundleIDs: applications whose audio is cut out of the system track.
    ///
    ///   Read that again before filling this list. It is not "do not record these windows" and
    ///   it is not a privacy switch — it removes those applications from the audio mix. Put the
    ///   browser or the conferencing client in here and the recording still runs, the buffers
    ///   still arrive, every check in this file still passes, and `system.wav` is a perfectly
    ///   valid file containing an hour of silence. Nothing downstream would notice either.
    ///   This list is for the things that must not end up in a meeting — a music player, a
    ///   noisy game — never for the application the meeting is happening in.
    ///
    /// - Parameter onFailureWhileRecording: called at most once, with the reason, when this
    ///   recording stops being a recording while the meeting is still going. Two things do that:
    ///   the stream dying, and the system track becoming unwritable — a full disk, a folder that
    ///   went away. A microphone track that fails is deliberately not one of them; `receive`
    ///   says why the two tracks are not equal.
    ///
    ///   Nothing here restarts the capture, so this is not a retry hook: it exists because a
    ///   stream that died on the fifth minute is otherwise noticed only by `stop`, and the
    ///   fifty-five minutes in between are spent recording nothing while the application says
    ///   it is recording. The caller decides what that means for the meeting — this type only
    ///   names it.
    ///
    ///   Called on the capture's own queue, not the caller's. Nothing after the recording has
    ///   been handed over ever reaches it, so the caller does not have to guard against a
    ///   failure about a meeting that is already filed.
    public init(
        folder: URL,
        excludedBundleIDs: [String],
        onFailureWhileRecording: @escaping @Sendable (String) -> Void
    ) {
        self.folder = folder
        self.excludedBundleIDs = excludedBundleIDs
        self.onFailureWhileRecording = onFailureWhileRecording
    }

    public func start() async throws {
        guard stream == nil else {
            throw MeetingCaptureError.streamFailed("start called while a capture is running")
        }
        // Checked here rather than at the first buffer: a missing folder would otherwise
        // surface as a write failure an hour later, when the meeting is already over.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MeetingCaptureError.streamFailed("no meeting folder at \(folder.path)")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // The only way this fails in practice is a denied screen recording permission, and
            // saying so is more useful than passing the raw error through.
            throw MeetingCaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }

        let excluded = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: excluded, exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // Our own sounds — the dictation chimes — must not end up in the meeting.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // Only the two audio outputs are attached below, so no video frame is ever delivered.
        // These keep the capture from building full-display frames for an hour anyway.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try TrackWriter(
            systemURL: folder.appendingPathComponent(Self.systemFileName),
            microphoneURL: folder.appendingPathComponent(Self.microphoneFileName),
            onFailureWhileRecording: onFailureWhileRecording
        )
        // The stream holds its delegate weakly; `writer` stays alive because this actor keeps
        // it until `stop`.
        let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
        do {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            try await stream.startCapture()
        } catch {
            // A half-started stream can still deliver a buffer; closing the writer first means
            // it is dropped instead of creating files nobody will ever finish.
            writer.close()
            throw MeetingCaptureError.streamFailed(error.localizedDescription)
        }
        self.stream = stream
        self.writer = writer
    }

    /// Stops the capture and closes both files.
    ///
    /// A capture that went wrong still returns its `Outcome`, with the cause in `failure`: the
    /// stream died mid-meeting, a file could not be written, or a track received nothing at
    /// all. Whatever was recorded before that stays on disk, which is what the spec asks for —
    /// the folder is kept as it is and the panel names the reason.
    ///
    /// A track's file exists only if at least one buffer reached it. That is not a detail:
    /// "no audio arrived" — the failure this most often reports — is exactly the case where the
    /// file was never created, because creating it eagerly would leave a valid WAV header with
    /// no audio behind it, which is the shape of a bug phase 1 already paid for once.
    ///
    /// - Throws: only when there is no capture to stop. That is a programmer error rather than
    ///   a circumstance, and there is no recording whose paths or timestamps could be described
    ///   — an `Outcome` would have to invent them.
    public func stop() async throws -> Outcome {
        guard let stream, let writer else {
            throw MeetingCaptureError.streamFailed("stop called with no capture running")
        }
        self.stream = nil
        self.writer = nil
        // `try?`: a stream that already died reports "not running" here, while the reason it
        // died was recorded by the delegate. `finish` is what names it.
        try? await stream.stopCapture()
        return writer.finish()
    }
}

/// Averages every channel of a buffer into one.
///
/// Separate from the capture because it is the one part of it that can be tested, and because
/// it is not obvious that it has to exist at all: `AVAudioConverter` looks like it does this
/// already. It does not. Asked to convert a stereo buffer into a mono one it keeps the first
/// channel and drops the rest — measured on this machine, with and without an explicit stereo
/// channel layout. On the system track that would lose whoever happens to be panned right, and
/// nothing about the resulting file would look wrong.
enum AudioDownmix {
    /// - Returns: the buffer itself when it is already mono, a new 32-bit float mono buffer at
    ///   the same sample rate otherwise, and `nil` when the samples are laid out in a way this
    ///   cannot read — which the caller has to report rather than quietly drop channels.
    static func mono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1 else { return buffer }
        // ScreenCaptureKit delivers 32-bit float, one plane per channel. Anything else is
        // unexpected enough to be worth a named failure instead of a guess.
        guard !buffer.format.isInterleaved, let planes = buffer.floatChannelData else {
            return nil
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mixed = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(buffer.frameLength, 1)
        ), let output = mixed.floatChannelData else {
            return nil
        }
        mixed.frameLength = buffer.frameLength
        let scale = 1 / Float(channels)
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += planes[channel][frame]
            }
            output[0][frame] = sum * scale
        }
        return mixed
    }
}

/// One track: converts what arrives into 16 kHz mono and appends it to its own file.
///
/// Touched only from `TrackWriter.queue`, so it needs no locking of its own. Internal rather
/// than private so the tests can drive it with a sample buffer of their own — an `SCStream`
/// cannot be built in a test process.
final class CaptureTrack {
    let url: URL
    private let name: String
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var frames: AVAudioFrameCount = 0
    private(set) var failure: String?

    /// Presentation timestamp of the first buffer this track was handed, in seconds on the
    /// stream's clock. Where the audio in the file begins — the resampler holds a few frames
    /// back, but the content still starts at this buffer.
    private(set) var startedAt: Double?

    init(name: String, url: URL, format: AVAudioFormat) {
        self.name = name
        self.url = url
        self.format = format
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        // One named failure per track is enough: every cause below is structural, and retrying
        // it every ten milliseconds for the rest of the meeting would only spin on it.
        guard failure == nil else { return }
        if startedAt == nil {
            let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if stamp.isValid, stamp.isNumeric {
                startedAt = stamp.seconds
            }
        }
        guard let source = samples(of: sampleBuffer) else { return }
        guard let mono = AudioDownmix.mono(from: source) else {
            fail("cannot down-mix the \(name) track from \(source.format)")
            return
        }
        guard let converted = resampled(mono), converted.frameLength > 0 else { return }
        do {
            // Created on the first buffer rather than at start, so a capture that never
            // delivers anything leaves no file pretending to be a recording.
            if file == nil {
                file = try RecordingChecks.openForWriting(url, targetFormat: format)
            }
            try file?.write(from: converted)
            frames += converted.frameLength
        } catch {
            fail("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Copies the samples out of the sample buffer into a buffer of their own format.
    private func samples(of sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let sourceFormat = AVAudioFormat(streamDescription: asbd)
        else {
            fail("\(name) samples arrive without a readable audio format")
            return nil
        }
        let sourceFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard sourceFrames > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: sourceFrames
        ) else {
            fail("cannot allocate a source buffer for the \(name) track")
            return nil
        }
        buffer.frameLength = sourceFrames
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(sourceFrames), into: buffer.mutableAudioBufferList
        )
        guard copied == noErr else {
            fail("cannot read \(name) samples: OSStatus \(copied)")
            return nil
        }
        return buffer
    }

    /// Resamples the already-mono buffer to 16 kHz.
    ///
    /// The converter is built once and kept between buffers: the two tracks have different
    /// source formats — the system mix follows the stream configuration, the microphone its
    /// device's native format — and a resampler carries filter state from one buffer to the
    /// next, which a converter built per buffer would throw away at every boundary. It is
    /// rebuilt only when the source format itself changes, which is what swapping the input
    /// device mid-meeting looks like from here.
    private func resampled(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            guard let made = AVAudioConverter(from: buffer.format, to: format) else {
                fail("cannot convert the \(name) track from \(buffer.format) to 16 kHz mono")
                return nil
            }
            converter = made
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        ) + 1024
        guard let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail("cannot allocate a conversion buffer for the \(name) track")
            return nil
        }
        // `nonisolated(unsafe)`: the input block below is declared `@Sendable`, but the
        // converter calls it synchronously, on this queue, before `convert` returns — there is
        // no second thread for either of these to reach.
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        converter.convert(to: target, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError {
            fail("cannot convert \(name) samples: \(conversionError.localizedDescription)")
            return nil
        }
        // An empty result is not a failure: a resampler holds a few input frames back before it
        // has enough to produce output.
        return target
    }

    /// Closing the file writes the WAV header for what was actually recorded, so everything up
    /// to the failure stays playable.
    func close() {
        file = nil
        converter = nil
    }

    private func fail(_ message: String) {
        failure = message
        close()
    }
}

/// Receives both output types on one queue and writes each into its own file.
///
/// A class rather than a closure because `SCStreamOutput` is a delegate protocol, and one
/// serial queue for both tracks because the two files must not be written concurrently by
/// converters that are not thread-safe.
///
/// Internal rather than private for the same reason as `CaptureTrack`: the delegate method
/// takes an `SCStream`, which a test process cannot build, so it does nothing but forward to
/// `receive`, which a test can call.
final class TrackWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.nohands.meeting.capture")

    /// Everything below is touched on `queue` only.
    private let system: CaptureTrack
    private let microphone: CaptureTrack
    /// What has already been named to the caller while the meeting was still being recorded —
    /// a dead stream or a track that can no longer be written. Both go through `report`, and
    /// this is what makes it happen once.
    private var reportedFailure: String?
    private var closed = false

    private let onFailureWhileRecording: @Sendable (String) -> Void

    init(
        systemURL: URL,
        microphoneURL: URL,
        onFailureWhileRecording: @escaping @Sendable (String) -> Void
    ) throws {
        self.onFailureWhileRecording = onFailureWhileRecording
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: MeetingAudioRecorder.sampleRate,
            channels: MeetingAudioRecorder.channelCount,
            interleaved: false
        ) else {
            throw MeetingCaptureError.streamFailed("cannot build the 16 kHz mono target format")
        }
        system = CaptureTrack(name: "system", url: systemURL, format: format)
        microphone = CaptureTrack(name: "microphone", url: microphoneURL, format: format)
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        receive(sampleBuffer, of: type)
    }

    /// Called on `queue` for every buffer of either track.
    func receive(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A buffer arriving after `finish` is dropped rather than written: recreating a closed
        // file would truncate the recording that was just handed over.
        guard !closed, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            system.append(sampleBuffer)
        case .microphone:
            microphone.append(sampleBuffer)
        default:
            // No screen output is attached, so `.screen` never arrives here.
            break
        }
        // A track that failed has stopped writing for good — `append` refuses every buffer after
        // the first failure — so this is a recording that is no longer being made. Spec §10 asks
        // for it to stop with the reason named rather than run out its hour on a truncated file,
        // and the reason travels the same road a dead stream travels: out at once, exactly once,
        // and never after the hand-off. `report` is where all three of those rules live.
        //
        // The system track only, and the two are deliberately not equal. Without the participants
        // there is no meeting left to record, so that one stops everything. Without the
        // microphone there is still half a meeting, and spec §10 is explicit about the input
        // device disappearing mid-meeting: the other track carries on, the break is noted,
        // "половина записи лучше нуля". A microphone failure is therefore named when the
        // recording is handed over and not before — which is also where the deferred work on
        // marking breaks in the metadata will pick it up.
        //
        // Running out of disk is still caught here: it takes both files down, and the system
        // track is the one being written continuously.
        if let failure = system.failure { report(failure) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamDied(error)
    }

    /// The stream dying mid-meeting is the one failure nobody asks for. Remembered so `stop` can
    /// name it instead of handing back a truncated recording as a success — and reported at once,
    /// because until this fires the meeting goes on believing it is being recorded.
    ///
    /// Internal rather than private for the same reason as `receive`: the delegate method above
    /// takes an `SCStream`, which a test process cannot build.
    func streamDied(_ error: Error) {
        // `async`, never `sync`: this can arrive on the sample handler queue itself, and the
        // rules below are the queue's. `receive` is already on it and calls `report` directly.
        queue.async { [self] in
            report("the capture stopped: \(error.localizedDescription)")
        }
    }

    /// The one way a failure reaches the caller while the meeting is still being recorded.
    ///
    /// Called on `queue`, which is what lets "once" and "not after the hand-off" be two plain
    /// guards rather than locks. Nothing here restarts anything, so a second report would be the
    /// same failure said twice; and after `finish` the recording has already been handed over, so
    /// a straggler would name a meeting that is no longer happening — the same mistake a late
    /// buffer used to make with the file.
    private func report(_ message: String) {
        guard !closed, reportedFailure == nil else { return }
        reportedFailure = message
        onFailureWhileRecording(message)
    }

    func close() {
        queue.sync { closeOnQueue() }
    }

    func finish() -> MeetingAudioRecorder.Outcome {
        queue.sync {
            closeOnQueue()
            return MeetingAudioRecorder.Outcome(
                systemURL: system.url,
                microphoneURL: microphone.url,
                systemStartedAt: system.startedAt,
                microphoneStartedAt: microphone.startedAt,
                failure: firstFailure()
            )
        }
    }

    private func closeOnQueue() {
        closed = true
        system.close()
        microphone.close()
    }

    private func firstFailure() -> String? {
        // Whatever was already named to the owner comes first: the panel and `meeting.json` say
        // the same sentence about the same recording.
        if let reportedFailure { return reportedFailure }
        if let failure = system.failure { return failure }
        if let failure = microphone.failure { return failure }
        // A track that received nothing at all is what a refused capture looks like from here:
        // the stream starts, and no buffer ever arrives. Phase 1 learned the same about the
        // microphone, where a denied permission produced a valid header and zero seconds of
        // audio that the code reported as a success.
        if system.frames == 0 {
            return "no audio arrived on the system track"
        }
        if microphone.frames == 0 {
            return "no audio arrived on the microphone track — check System Settings > " +
                "Privacy & Security > Microphone"
        }
        return nil
    }
}
