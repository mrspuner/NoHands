import Foundation

/// Rewrites a WAV file's length fields from its actual size on disk.
///
/// `AVAudioFile` — really `ExtAudioFile` underneath — updates the `data` chunk's length field
/// only when the file closes; until then it sits at the placeholder value written when the file
/// was created, zero. (The RIFF chunk's own length field is a separate placeholder — the size
/// of the header alone, before any audio — and is *not* zero; only `data`'s is.) An application
/// that dies mid-recording never reaches that close, so the file reads as empty even though
/// every sample made it to disk. The draft folder of a crashed meeting
/// (`~/Meetings/.queue/.draft-…`) holds exactly that file, and it is worth nothing to the owner
/// if it cannot be opened.
///
/// **The two fields are not at a fixed offset.** A hand-built canonical WAV puts them at bytes
/// 4 and 40, in a 44-byte header. `ExtAudioFile` does not write a canonical header: measured on
/// this machine, a 16 kHz mono Int16 file — exactly what `MeetingAudioRecorder` writes — comes
/// out as `RIFF` → `JUNK` (28-byte pad) → `fmt ` (16 bytes) → `FLLR` (a filler chunk sized to
/// pad the header) → `data`, with the `data` chunk starting at byte 4096 so its payload lands
/// on a page boundary. Byte 40 falls inside the `JUNK` chunk's padding on that layout — nowhere
/// near the actual length field — so a repair that trusted the canonical offset would leave the
/// real `data` size at zero while overwriting four bytes that happened to do no visible harm
/// only because they were already zero. `repair` instead walks the chunk list from the start of
/// the file to find `data`, the same way any WAV reader has to.
public enum WavHeaderRepair {
    /// Thrown instead of silently truncating a byte count into the 32-bit field a classic WAV
    /// header has room for. Not expected in practice for this project — 16 kHz mono Int16 audio
    /// reaches 4 GiB only after roughly 37 days of continuous recording — but wrapping the
    /// number instead of naming the problem is exactly the kind of quiet corruption this type
    /// exists to prevent.
    public enum RepairError: Error, Equatable, LocalizedError {
        case tooLargeForClassicWavHeader(byteCount: UInt64)

        public var errorDescription: String? {
            switch self {
            case .tooLargeForClassicWavHeader(let byteCount):
                return "Audio data is \(byteCount) bytes, too large for a classic WAV's " +
                    "32-bit length field — refusing to repair rather than write a wrapped number"
            }
        }
    }

    /// Bytes 0–11 every RIFF/WAVE file starts with: `"RIFF"`, a 4-byte size, `"WAVE"`.
    private static let minimumHeaderSize: UInt64 = 12
    private static let riffTag = Array("RIFF".utf8)
    private static let waveTag = Array("WAVE".utf8)
    private static let dataTag = Array("data".utf8)

    /// - Returns: `true` when the header's length fields were rewritten, `false` when the file
    ///   was already consistent with its size, when it did not look like a WAV file, or when it
    ///   was too short to safely contain one. A file this declines to repair is left exactly as
    ///   it was: opening it will fail on its own, which is a plainer signal than a file quietly
    ///   left half-fixed or, worse, written into at the wrong offset.
    /// - Throws: an I/O error from the filesystem, or ``RepairError`` when the file is larger
    ///   than a classic WAV header can describe.
    @discardableResult
    public static func repair(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= minimumHeaderSize else { return false }

        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Int(minimumHeaderSize)),
              header.count == Int(minimumHeaderSize),
              Array(header.prefix(4)) == riffTag,
              Array(header.suffix(4)) == waveTag
        else {
            return false
        }

        guard let dataChunkOffset = try locateDataChunk(handle: handle, fileSize: fileSize) else {
            return false
        }
        let dataSizeFieldOffset = dataChunkOffset + 4
        let dataPayloadOffset = dataChunkOffset + 8
        guard fileSize >= dataPayloadOffset else { return false }

        let expectedDataSize = try classicWavLength(fileSize - dataPayloadOffset)
        let expectedRiffSize = try classicWavLength(fileSize - 8)

        try handle.seek(toOffset: dataSizeFieldOffset)
        let existingDataSize = try handle.read(upToCount: 4) ?? Data()
        try handle.seek(toOffset: 4)
        let existingRiffSize = try handle.read(upToCount: 4) ?? Data()
        guard existingDataSize != littleEndian(expectedDataSize)
            || existingRiffSize != littleEndian(expectedRiffSize)
        else {
            return false
        }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndian(expectedRiffSize))
        try handle.seek(toOffset: dataSizeFieldOffset)
        try handle.write(contentsOf: littleEndian(expectedDataSize))
        return true
    }

    /// Walks RIFF sub-chunks from byte 12 looking for `data`. Every chunk ahead of it — `fmt `,
    /// `JUNK`, `FLLR`, whatever else `ExtAudioFile` chose to write — carries a correct declared
    /// size: those are written once, at open, and never touched again. Only `data`'s size is
    /// left at a placeholder until the file closes, which is the field this function exists to
    /// fix. Returns the byte offset where the `data` chunk's 4-byte tag starts (its size field
    /// follows at `+4`), or `nil` when no such chunk is found before the file runs out — which
    /// covers both a genuinely malformed file and one too short to contain a real header.
    private static func locateDataChunk(handle: FileHandle, fileSize: UInt64) throws -> UInt64? {
        var offset = minimumHeaderSize
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else {
                return nil
            }
            if Array(chunkHeader.prefix(4)) == dataTag {
                return offset
            }
            let size = UInt64(readLittleEndian(chunkHeader, at: 4))
            // RIFF chunks are word-aligned: an odd-sized chunk carries one pad byte after it.
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    private static func classicWavLength(_ byteCount: UInt64) throws -> UInt32 {
        guard byteCount <= UInt64(UInt32.max) else {
            throw RepairError.tooLargeForClassicWavHeader(byteCount: byteCount)
        }
        return UInt32(byteCount)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Reads a little-endian `UInt32` out of `data` starting at `offset`, without assuming
    /// `data`'s own indices start at zero — a `Data` returned by `FileHandle.read` does, but
    /// this keeps the helper honest either way.
    private static func readLittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: 4)
        var value: UInt32 = 0
        for byte in data[start..<end].reversed() {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
