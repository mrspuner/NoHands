import AVFoundation
import Foundation

/// Mutable state of one live recording, shared with the audio tap.
///
/// The tap closure runs on a real-time audio thread: it cannot await, so actor isolation is
/// not available to it. A lock is. Split out from `RecordingSession` so the decisions it makes
/// are testable without a microphone.
final class RecordingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var writeError: Error?
    private var framesWritten: AVAudioFrameCount = 0
    private var lastLevelAt: Double?

    func recordWriteFailure(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        // Keep the first failure; later writes fail the same way and would only overwrite the
        // more informative one.
        if writeError == nil {
            writeError = error
        }
    }

    func addFrames(_ count: AVAudioFrameCount) {
        lock.lock()
        defer { lock.unlock() }
        framesWritten += count
    }

    func outcome() -> (writeError: Error?, frames: AVAudioFrameCount) {
        lock.lock()
        defer { lock.unlock() }
        return (writeError, framesWritten)
    }

    /// True at most once per `interval`. Called from the audio thread on every buffer.
    func shouldEmitLevel(at now: Double, interval: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastLevelAt, now - lastLevelAt < interval {
            return false
        }
        lastLevelAt = now
        return true
    }
}

/// One live recording: everything `stop()` and `discard()` need to finish or undo it.
final class RecordingSession: @unchecked Sendable {
    let engine: AVAudioEngine
    let input: AVAudioInputNode
    let file: AVAudioFile
    let url: URL
    let fileExistedBefore: Bool
    let counters = RecordingCounters()

    private let teardownLock = NSLock()
    private var isTornDown = false

    init(engine: AVAudioEngine, input: AVAudioInputNode, file: AVAudioFile, url: URL, fileExistedBefore: Bool) {
        self.engine = engine
        self.input = input
        self.file = file
        self.url = url
        self.fileExistedBefore = fileExistedBefore
    }

    /// Idempotent, and every read of `counters` must come after it: while the tap can still
    /// fire, a buffer delivered in the gap would write a value nobody reads.
    func tearDown() {
        teardownLock.lock()
        let already = isTornDown
        isTornDown = true
        teardownLock.unlock()
        guard !already else { return }
        engine.stop()
        input.removeTap(onBus: 0)
    }

    /// Safety net for a session that's dropped without `stop()` or `discard()` ever being
    /// called: without this, the tap stays installed on the input node and a partially written
    /// WAV sits on disk until ARC gets around to it — the same "file that looks like a
    /// successful recording" shape the comments in `MicrophoneRecorder.swift` exist to prevent.
    /// `tearDown()` is idempotent, so this is safe alongside the explicit calls elsewhere.
    deinit {
        tearDown()
    }
}
