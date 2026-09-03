import AVFoundation
import Foundation
import Testing
@testable import Core

// `ExtAudioFile` — what `AVAudioFile` writes through — does not produce a canonical 44-byte
// header. Measured on this machine for 16 kHz mono Int16, the format `MeetingAudioRecorder`
// writes: RIFF -> JUNK (28-byte pad) -> fmt (16 bytes) -> FLLR (filler) -> data, with the data
// chunk's payload starting at byte 4096 so it lands on a page boundary. Byte 40, where a
// hand-built header would put the data length, falls inside the JUNK chunk's padding here —
// nowhere near the real field. Every helper below therefore locates the data chunk by walking
// the chunk list, the same way `WavHeaderRepair` itself has to, rather than trusting an offset.

/// Writes a WAV the same way `MeetingAudioRecorder` does — through
/// `RecordingChecks.openForWriting`, 16 kHz mono Int16 — and returns its URL once the file is
/// closed with a correct, healthy header.
private func healthyWav(frames: AVAudioFrameCount = 16000) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
    )!
    // A local function, not a top-level `let`: the file must go out of scope and deinitialize
    // — closing it and finalizing its header — before this function returns.
    try writeAndClose(url: url, format: format, frames: frames)
    return url
}

private func writeAndClose(url: URL, format: AVAudioFormat, frames: AVAudioFrameCount) throws {
    let file = try RecordingChecks.openForWriting(url, targetFormat: format)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    try file.write(from: buffer)
}

/// A file that looks exactly like a crashed recording: real audio bytes on disk, but the
/// length fields still at the placeholder value `ExtAudioFile` writes when a file is created
/// and never gets to update, because closing it — which is what would update them — is exactly
/// the step a crash skips.
private func brokenWav(frames: AVAudioFrameCount = 16000) throws -> URL {
    let url = try healthyWav(frames: frames)
    try corruptLengthFields(of: url)
    return url
}

/// Overwrites the `data` chunk's length field with zero, in place, without touching a single
/// audio byte — simulating the crash deterministically instead of racing `AVAudioFile`'s own
/// finalization.
///
/// The RIFF size field (offset 4) is deliberately left alone. A genuinely crashed recording
/// leaves it exactly as `ExtAudioFile` first wrote it when the file was created — the size of
/// the header alone, before any audio was appended — which is *not* zero (measured on this
/// machine: 4088 for this format, the byte offset where the `data` chunk begins). Zeroing that
/// field too, as a hand-built canonical header's repair would, produces a file
/// `ExtAudioFileOpenURL` refuses to open at all — confirmed on this machine, and the reason
/// this helper does not do it: it would test a header shape a real crash never produces.
private func corruptLengthFields(of url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }

    var offset: UInt64 = 12
    while true {
        try handle.seek(toOffset: offset)
        guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else {
            Issue.record("test setup: could not find a data chunk to corrupt")
            return
        }
        if Array(chunkHeader.prefix(4)) == Array("data".utf8) {
            try handle.seek(toOffset: offset + 4)
            try handle.write(contentsOf: Data([0, 0, 0, 0]))
            return
        }
        let size = readLittleEndianUInt32(chunkHeader, at: 4)
        offset += 8 + UInt64(size) + UInt64(size % 2)
    }
}

private func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: 4)
    var value: UInt32 = 0
    for byte in data[start..<end].reversed() {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

// A file left behind by a crash mid-recording looks empty even though the audio is on disk:
// `AVAudioFile` writes the length fields only when the file closes.
@Test func aTruncatedHeaderIsRepairedFromTheActualFileSize() throws {
    let url = try brokenWav()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try AVAudioFile(forReading: url).length == 0)
    #expect(try WavHeaderRepair.repair(at: url) == true)

    let repaired = try AVAudioFile(forReading: url)
    #expect(repaired.length == 16000)
}

@Test func aHealthyFileIsLeftAlone() throws {
    let url = try brokenWav()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try WavHeaderRepair.repair(at: url)
    #expect(try WavHeaderRepair.repair(at: url) == false)
}

// A file that was never broken must come out byte-for-byte identical: repair only ever runs
// against a file the owner cannot re-record, so touching one that needed nothing done is its
// own kind of damage.
@Test func aNaturallyHealthyFileIsUntouchedByteForByte() throws {
    let url = try healthyWav()
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    #expect(try WavHeaderRepair.repair(at: url) == false)

    let after = try Data(contentsOf: url)
    #expect(before == after)
}

// The dangerous case the brief's own hardcoded offsets would have gotten wrong: repair must
// find `data` wherever `ExtAudioFile` actually put it, not at a fixed byte 40.
@Test func repairFindsTheDataChunkPastTheRealHeaderPadding() throws {
    let url = try brokenWav(frames: 10)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try WavHeaderRepair.repair(at: url) == true)
    #expect(try AVAudioFile(forReading: url).length == 10)
}

// The chunk walk pads an odd-sized chunk by one byte, per the RIFF spec (`size + size % 2`) —
// a line no fixture above exercises, because every chunk `ExtAudioFile` itself writes happens
// to be even-sized. Miss that pad byte and the walk starts reading the next chunk header one
// byte early: on this fixture it would land inside `data`'s own tag and never match it, and
// repair would wrongly refuse a file it should have fixed.
@Test func repairFindsDataPastAnOddLengthChunk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var bytes = Array("RIFF".utf8)
    bytes.append(contentsOf: [0, 0, 0, 0]) // RIFF size placeholder — repair recomputes it
    bytes.append(contentsOf: Array("WAVE".utf8))
    bytes.append(contentsOf: Array("JUNK".utf8))
    bytes.append(contentsOf: [5, 0, 0, 0]) // odd chunk size: 5 data bytes, needs a pad byte
    bytes.append(contentsOf: [0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
    bytes.append(0x00) // the pad byte the RIFF spec requires after an odd-sized chunk
    bytes.append(contentsOf: Array("data".utf8))
    bytes.append(contentsOf: [0, 0, 0, 0]) // data size placeholder, to be repaired
    let audio: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    bytes.append(contentsOf: audio)
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try WavHeaderRepair.repair(at: url) == true)

    let after = try Data(contentsOf: url)
    #expect(after.count == bytes.count)
    #expect(after.suffix(audio.count) == Data(audio))
    let dataSizeFieldOffset = after.count - audio.count - 4
    #expect(readLittleEndianUInt32(after, at: dataSizeFieldOffset) == UInt32(audio.count))
    #expect(readLittleEndianUInt32(after, at: 4) == UInt32(after.count - 8))
}

// A file that is not a WAV at all must not be rewritten into looking like a valid one — better
// for the draft to stay unopenable than for it to be quietly, wrongly "fixed".
@Test func aFileThatIsNotAWavIsLeftAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("this is not a wav file, just some bytes".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    #expect(try WavHeaderRepair.repair(at: url) == false)

    let after = try Data(contentsOf: url)
    #expect(before == after)
}

// Shorter than even a RIFF/WAVE signature: nothing to parse, nothing to write.
@Test func aFileShorterThanTheHeaderIsLeftAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url) // "RIFF", nothing else
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try WavHeaderRepair.repair(at: url) == false)
    #expect(try Data(contentsOf: url) == Data([0x52, 0x49, 0x46, 0x46]))
}

// A file that declares RIFF/WAVE correctly but never actually contains a `data` chunk — the
// header claims more than the bytes on disk deliver.
@Test func aFileWithNoDataChunkIsLeftAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var bytes = Array("RIFF".utf8)
    bytes.append(contentsOf: [0, 0, 0, 0])
    bytes.append(contentsOf: Array("WAVE".utf8))
    bytes.append(contentsOf: Array("fmt ".utf8))
    bytes.append(contentsOf: [4, 0, 0, 0, 1, 2, 3, 4]) // a 4-byte fmt chunk, then nothing
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    #expect(try WavHeaderRepair.repair(at: url) == false)

    let after = try Data(contentsOf: url)
    #expect(before == after)
}

// The `fmt ` fixture above declares a size that lands exactly on the end of the file — a
// well-formed file that simply has no `data` chunk. This one declares a size that overshoots
// the file entirely: the walk must not guess where the next chunk might start once its
// arithmetic runs past what is actually on disk, and must leave the file untouched either way.
@Test func aChunkLengthPastEndOfFileIsLeftAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var bytes = Array("RIFF".utf8)
    bytes.append(contentsOf: [0, 0, 0, 0])
    bytes.append(contentsOf: Array("WAVE".utf8))
    bytes.append(contentsOf: Array("fmt ".utf8))
    bytes.append(contentsOf: [0xFF, 0xFF, 0x00, 0x00]) // declares 65535 bytes
    bytes.append(contentsOf: [1, 2, 3, 4]) // only 4 actual bytes follow
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    #expect(try WavHeaderRepair.repair(at: url) == false)

    let after = try Data(contentsOf: url)
    #expect(before == after)
}

// A different shape of the same danger: the position where `data` should be holds a garbage
// chunk instead, one that also lies about its length. Distinct from both the well-formed
// "no data chunk" fixture above (an honest length that just runs out) and the overshooting
// `fmt` chunk above (the lie sits earlier, before any chunk could plausibly be `data`) — here
// the lie sits exactly where the real recording's length would be found.
@Test func aGarbageChunkWhereDataShouldBeWithAnOversizedLengthIsLeftAlone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var bytes = Array("RIFF".utf8)
    bytes.append(contentsOf: [0, 0, 0, 0])
    bytes.append(contentsOf: Array("WAVE".utf8))
    bytes.append(contentsOf: Array("fmt ".utf8))
    bytes.append(contentsOf: [4, 0, 0, 0, 1, 2, 3, 4]) // a well-formed 4-byte fmt chunk
    bytes.append(contentsOf: Array("grbg".utf8)) // garbage where "data" was expected
    bytes.append(contentsOf: [0x00, 0x10, 0x00, 0x00]) // declares 4096 bytes
    bytes.append(contentsOf: [9, 9, 9]) // only 3 actual bytes follow
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try Data(contentsOf: url)

    #expect(try WavHeaderRepair.repair(at: url) == false)

    let after = try Data(contentsOf: url)
    #expect(before == after)
}

// A byte count past what a classic WAV's 32-bit length field can hold must be refused, not
// wrapped into a wrong-but-plausible-looking number — silently corrupting a recording that
// cannot be made again. Grown with `truncate(atOffset:)` into a sparse hole so the test does
// not need to write four real gigabytes of audio.
@Test func aFileTooLargeForAClassicWavHeaderIsRefused() throws {
    let url = try brokenWav(frames: 10)
    defer { try? FileManager.default.removeItem(at: url) }

    let handle = try FileHandle(forUpdating: url)
    try handle.truncate(atOffset: UInt64(UInt32.max) + 4096 + 100)
    try handle.close()

    #expect(throws: WavHeaderRepair.RepairError.self) {
        try WavHeaderRepair.repair(at: url)
    }
}
