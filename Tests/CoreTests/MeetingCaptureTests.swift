import AVFoundation
import ScreenCaptureKit
import Testing
@testable import Core

/// A PCM audio sample buffer shaped like the ones ScreenCaptureKit delivers, stamped with a
/// presentation timestamp of our choosing. Silence: what is being checked here is bookkeeping,
/// not sound.
private func sampleBuffer(
    at seconds: Double,
    frames: Int = 480,
    sampleRate: Double = 48000
) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format
    ) == noErr)

    let bytes = frames * 4
    var block: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: bytes,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: bytes,
        flags: 0,
        blockBufferOut: &block
    ) == noErr)
    let blockBuffer = try #require(block)
    try #require(CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes
    ) == noErr)

    var buffer: CMSampleBuffer?
    try #require(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: try #require(format),
        sampleCount: CMItemCount(frames),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
        packetDescriptions: nil,
        sampleBufferOut: &buffer
    ) == noErr)
    return try #require(buffer)
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func targetFormat() throws -> AVAudioFormat {
    try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: MeetingAudioRecorder.sampleRate,
        channels: MeetingAudioRecorder.channelCount,
        interleaved: false
    ))
}

/// The two tracks of one capture, in a folder of the test's own. Most tests here do not care
/// about the failure handler, so it defaults to one that ignores everything.
private func makeWriter(
    in folder: URL,
    onFailureWhileRecording: @escaping @Sendable (String) -> Void = { _ in }
) throws -> TrackWriter {
    try TrackWriter(
        systemURL: folder.appendingPathComponent("system.wav"),
        microphoneURL: folder.appendingPathComponent("mic.wav"),
        onFailureWhileRecording: onFailureWhileRecording
    )
}

/// Collects what the capture reported, from whichever thread it reported it on.
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

private struct StreamDeath: LocalizedError {
    var errorDescription: String? { "display disconnected" }
}

// The one thing a single stream buys over two independent captures is that both tracks are
// stamped by the same clock. That is worth nothing unless the stamps are carried out: the two
// outputs still start whenever they start, and phase 2б needs the difference.
@Test func theFirstBufferDecidesWhereTheTrackBegins() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let track = CaptureTrack(
        name: "system", url: folder.appendingPathComponent("system.wav"), format: try targetFormat()
    )

    track.append(try sampleBuffer(at: 1234.5))
    track.append(try sampleBuffer(at: 1234.51))

    #expect(track.startedAt == 1234.5)
    #expect(track.frames > 0)
    #expect(track.failure == nil)
}

@Test func aTrackThatReceivedNothingHasNoBeginning() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let track = CaptureTrack(
        name: "system", url: folder.appendingPathComponent("system.wav"), format: try targetFormat()
    )

    #expect(track.startedAt == nil)
    #expect(track.frames == 0)
    // No buffer, no file: an empty WAV with a valid header is the shape of the bug phase 1 paid
    // for once already.
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.wav").path))
}

// Both outputs go through one writer, and the tracks they land in must not be confused: the
// whole point of two files is that "me" is identified without diarization.
@Test func eachOutputTypeLandsInItsOwnFile() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try makeWriter(in: folder)

    writer.receive(try sampleBuffer(at: 100), of: .audio)
    writer.receive(try sampleBuffer(at: 100.25), of: .microphone)
    let outcome = writer.finish()

    #expect(outcome.failure == nil)
    #expect(outcome.systemStartedAt == 100)
    #expect(outcome.microphoneStartedAt == 100.25)
    #expect(FileManager.default.fileExists(atPath: outcome.systemURL.path))
    #expect(FileManager.default.fileExists(atPath: outcome.microphoneURL.path))
}

// A failure and the paths are different pieces of information. Losing the second because of the
// first would throw away whatever did get recorded — the spec keeps the folder as it is.
@Test func aTrackThatGotNothingIsNamedAndThePathsStillCome() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try makeWriter(in: folder)

    writer.receive(try sampleBuffer(at: 7), of: .audio)
    let outcome = writer.finish()

    let failure = try #require(outcome.failure)
    #expect(failure.contains("microphone"))
    #expect(outcome.systemURL == folder.appendingPathComponent("system.wav"))
    #expect(outcome.microphoneURL == folder.appendingPathComponent("mic.wav"))
    #expect(outcome.systemStartedAt == 7)
    #expect(outcome.microphoneStartedAt == nil)
    // The system track was recorded and stays recorded.
    #expect(FileManager.default.fileExists(atPath: outcome.systemURL.path))
}

@Test func silenceOnBothTracksIsNamedForTheSystemTrackFirst() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try makeWriter(in: folder)

    let outcome = writer.finish()

    #expect(try #require(outcome.failure).contains("system"))
}

// After the hand-off a late buffer must not reopen the file: `AVAudioFile(forWriting:)`
// truncates, so one straggler would cut a finished meeting down to nothing.
@Test func aBufferArrivingAfterTheHandoffDoesNotTruncateTheRecording() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try makeWriter(in: folder)

    writer.receive(try sampleBuffer(at: 1), of: .audio)
    writer.receive(try sampleBuffer(at: 1), of: .microphone)
    let outcome = writer.finish()
    let recorded = try AVAudioFile(forReading: outcome.systemURL).length
    #expect(recorded > 0)

    writer.receive(try sampleBuffer(at: 2), of: .audio)

    #expect(try AVAudioFile(forReading: outcome.systemURL).length == recorded)
}

// The written file is what recognition expects, so nothing downstream resamples it again.
@Test func bothFilesAreSixteenKilohertzMono() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try makeWriter(in: folder)

    writer.receive(try sampleBuffer(at: 0), of: .audio)
    writer.receive(try sampleBuffer(at: 0, sampleRate: 44100), of: .microphone)
    let outcome = writer.finish()

    for url in [outcome.systemURL, outcome.microphoneURL] {
        let format = try AVAudioFile(forReading: url).fileFormat
        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)
    }
}

@Test func stoppingWithoutAStartIsAnError() async {
    let recorder = MeetingAudioRecorder(
        folder: FileManager.default.temporaryDirectory,
        excludedBundleIDs: [],
        onFailureWhileRecording: { _ in }
    )
    await #expect(throws: MeetingCaptureError.self) {
        _ = try await recorder.stop()
    }
}

// MARK: - A stream that dies while the meeting is still going

// The reason this exists at all: a stream that died on the fifth minute used to be visible only
// in the outcome of `stop`, so for the remaining fifty-five minutes the application believed it
// was recording an hour that was not being recorded.
@Test func aStreamThatDiesWhileRecordingIsReportedWithoutWaitingForTheStop() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }

    writer.receive(try sampleBuffer(at: 1), of: .audio)
    writer.streamDied(StreamDeath())
    writer.queue.sync {}

    #expect(log.messages == ["the capture stopped: display disconnected"])
    // The same sentence the stop reports, so the panel and `meeting.json` cannot disagree about
    // what went wrong.
    #expect(writer.finish().failure == "the capture stopped: display disconnected")
}

// Nothing retries a dead stream, and ScreenCaptureKit is free to say so more than once. A second
// report would be a second failure panel about the same thing.
@Test func aDeadStreamIsReportedOnceHoweverOftenItIsAnnounced() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }

    writer.streamDied(StreamDeath())
    writer.streamDied(StreamDeath())
    writer.streamDied(StreamDeath())
    writer.queue.sync {}

    #expect(log.messages.count == 1)
}

// MARK: - A track that can no longer be written

/// Takes the folder out from under a writer that has already been built. What a full disk looks
/// like from inside `append`: the first write fails, and every write after it would too.
private func makeUnwritable(_ folder: URL) throws {
    try FileManager.default.removeItem(at: folder)
}

// Spec §10: running out of disk stops the recording with the reason named, rather than writing a
// truncated file for the rest of the meeting. A track that cannot be written is finished for
// good — `append` never tries again — so without this the meeting went on believing in itself
// and the reason turned up only when the owner pressed stop an hour later. The same door a dead
// stream goes through, and the same rules: once, and nothing after the hand-off.
@Test func aTrackThatCannotBeWrittenIsReportedWithoutWaitingForTheStop() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }
    try makeUnwritable(folder)

    writer.receive(try sampleBuffer(at: 1), of: .audio)

    #expect(try #require(log.messages.first).contains("system.wav"))
    #expect(log.messages.count == 1)
    // The same sentence the stop reports, so the panel and `meeting.json` cannot disagree about
    // what went wrong.
    #expect(writer.finish().failure == log.messages.first)
}

// Buffers keep arriving ten times a second, and every one of them would fail the same way.
@Test func aTrackThatCannotBeWrittenIsReportedOnceHoweverManyBuffersArrive() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }
    try makeUnwritable(folder)

    writer.receive(try sampleBuffer(at: 1), of: .audio)
    writer.receive(try sampleBuffer(at: 2), of: .audio)
    writer.receive(try sampleBuffer(at: 3), of: .microphone)

    #expect(log.messages.count == 1)
}

// The two tracks are not worth the same, and only one of them may stop the meeting. Spec §10 for
// "устройство ввода исчезло посреди встречи": the system track carries on, the break is noted,
// "половина записи лучше нуля". Reporting a microphone failure through this door would close both
// files over the one that matters least — the participants would be lost because the owner's own
// microphone went.
@Test func aMicrophoneTrackThatCannotBeWrittenDoesNotStopTheMeeting() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }
    // The system track opens its file while the folder is still there, and keeps it open.
    writer.receive(try sampleBuffer(at: 1), of: .audio)
    try makeUnwritable(folder)

    writer.receive(try sampleBuffer(at: 1), of: .microphone)

    #expect(log.messages.isEmpty)
    // Still named when the recording is handed over — silenced mid-meeting, not swallowed.
    #expect(try #require(writer.finish().failure).contains("mic.wav"))
}

@Test func aWriteThatCannotHappenAfterTheHandoffIsNotReportedEither() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }
    writer.receive(try sampleBuffer(at: 1), of: .audio)
    writer.receive(try sampleBuffer(at: 1), of: .microphone)
    _ = writer.finish()
    try makeUnwritable(folder)

    writer.receive(try sampleBuffer(at: 2), of: .audio)

    #expect(log.messages.isEmpty)
}

// The meeting is over and the folder has already been handed on. A straggling failure would
// raise a panel about a recording nobody is making — the same class of mistake as the late
// buffer that used to truncate a finished file.
@Test func aStreamFailureArrivingAfterTheHandoffIsNotReported() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = FailureLog()
    let writer = try makeWriter(in: folder) { log.append($0) }

    writer.receive(try sampleBuffer(at: 1), of: .audio)
    writer.receive(try sampleBuffer(at: 1), of: .microphone)
    _ = writer.finish()

    writer.streamDied(StreamDeath())
    writer.queue.sync {}

    #expect(log.messages.isEmpty)
}
