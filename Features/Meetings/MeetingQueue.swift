import Core
import Foundation

/// Turns finished recordings into meeting files, one folder at a time.
///
/// Serial by construction, and that is a requirement rather than an optimisation: two meetings
/// back to back must not fight over the Neural Engine.
public actor MeetingQueue {
    public struct Outcome: Equatable, Sendable {
        public var folder: String
        public var minutes: Int?
        public var failure: String?

        public init(folder: String, minutes: Int?, failure: String?) {
            self.folder = folder
            self.minutes = minutes
            self.failure = failure
        }
    }

    enum Failure: LocalizedError {
        case noTracks(String)
        case alreadyCompressed(String)
        case nothingRecognised(String)

        var errorDescription: String? {
            switch self {
            case .noTracks(let name):
                return "В папке \(name) нет ни одной дорожки"
            case .alreadyCompressed(let name):
                return "Дорожки \(name) уже сжаты, расшифровывать нечего"
            case .nothingRecognised(let name):
                return "В обеих дорожках \(name) не распознано ни одного слова"
            }
        }
    }

    private let queue: URL
    private let archive: URL
    private let config: MeetingsConfig
    private let makeTranscriber: @Sendable () async throws -> any TimedTranscriber
    private let measureLevel: @Sendable (URL, TimeInterval, TimeInterval) throws -> Float
    private let compress: @Sendable (URL, URL, Int) async throws -> Void
    private let report: @Sendable (Outcome) -> Void

    /// Held only while there is work. Loading costs 0.3 s from cache and 470 MB resident, and
    /// the alternative — sharing the transcriber dictation keeps — would put a dictation behind
    /// a whole meeting in the actor's queue.
    private var transcriber: (any TimedTranscriber)?
    private var pending: [URL] = []
    private var draining = false

    public init(
        queue: URL = MeetingFolder.queueURL,
        archive: URL = MeetingFolder.archiveURL,
        config: MeetingsConfig,
        makeTranscriber: @escaping @Sendable () async throws -> any TimedTranscriber,
        measureLevel: @escaping @Sendable (URL, TimeInterval, TimeInterval) throws -> Float
            = { url, from, to in try PhraseLevel.peakDBFS(of: url, from: from, to: to) },
        compress: @escaping @Sendable (URL, URL, Int) async throws -> Void
            = { source, destination, bitrate in
                try await AudioCompressor.compress(source, to: destination, bitrate: bitrate)
            },
        report: @escaping @Sendable (Outcome) -> Void
    ) {
        self.queue = queue
        self.archive = archive
        self.config = config
        self.makeTranscriber = makeTranscriber
        self.measureLevel = measureLevel
        self.compress = compress
        self.report = report
    }

    public func enqueue(_ folder: URL) async {
        pending.append(folder)
        await drain()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let folder = pending.removeFirst()
            report(await run(folder))
        }
        // Nothing left to do: the model goes, and the resting footprint is what it was before.
        transcriber = nil
        draining = false
    }

    private func run(_ folder: URL) async -> Outcome {
        let name = folder.lastPathComponent
        let started = Date()
        do {
            try MeetingErrorFile.remove(in: folder)
            let duration = try await process(folder, startedProcessingAt: started)
            return Outcome(folder: name, minutes: Int((duration / 60).rounded()), failure: nil)
        } catch {
            let reason = error.localizedDescription
            try? MeetingErrorFile.write(reason, at: Date(), to: folder)
            return Outcome(folder: name, minutes: nil, failure: reason)
        }
    }

    /// - Returns: the meeting's duration in seconds.
    private func process(_ folder: URL, startedProcessingAt: Date) async throws -> TimeInterval {
        let fileManager = FileManager.default
        let metadata = try MeetingMetadata.read(
            from: folder.appendingPathComponent(MeetingMetadata.fileName)
        )
        let system = folder.appendingPathComponent(MeetingAudioRecorder.systemFileName)
        let microphone = folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName)
        let tracks = [system, microphone].filter { fileManager.fileExists(atPath: $0.path) }
        guard !tracks.isEmpty else {
            // Compressed tracks with no raw ones and no `processed.json` means the pipeline died
            // between deleting the WAVs and recording that it had finished. Saying so beats the
            // generic "no tracks": the audio is not lost, it is just no longer in a form this
            // step can read, and the owner needs to know which of those two happened.
            let compressed = [system, microphone]
                .map { $0.deletingPathExtension().appendingPathExtension("m4a") }
                .contains { fileManager.fileExists(atPath: $0.path) }
            throw compressed
                ? Failure.alreadyCompressed(folder.lastPathComponent)
                : Failure.noTracks(folder.lastPathComponent)
        }

        let transcriber = try await resolveTranscriber()

        var theirs: [Utterance] = []
        if fileManager.fileExists(atPath: system.path) {
            theirs = Utterance.split(
                words: try await transcriber.transcribeTimed(audio: system),
                speaker: .others,
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
        }

        var mine: [Utterance] = []
        if fileManager.fileExists(atPath: microphone.path) {
            let all = Utterance.split(
                words: try await transcriber.transcribeTimed(audio: microphone),
                speaker: .me,
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
            // The room the desk microphone hears is removed here rather than at capture — see
            // the decision of 2026-09-04. Whole utterances, never single words.
            mine = try PhraseLevel.passing(all, thresholdDBFS: Float(config.micThresholdDBFS)) {
                try measureLevel(microphone, $0.start, $0.end)
            }
        }

        let merged = MeetingTranscript.merge(
            mine: mine,
            theirs: theirs,
            microphoneStartedAt: metadata.microphoneStartedAt,
            systemStartedAt: metadata.systemStartedAt
        )
        guard !merged.isEmpty else { throw Failure.nothingRecognised(folder.lastPathComponent) }

        let duration = try tracks.map { try AudioDuration.seconds(of: $0) }.max() ?? 0

        // Markdown before compression, deliberately: if the encoder falls over, the text is
        // already in the archive and the raw audio is still on disk.
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let transcript = archive.appendingPathComponent(folder.lastPathComponent + ".md")
        let markdown = MeetingMarkdown.render(
            transcript: merged,
            startedAt: metadata.startedAt,
            durationSeconds: duration,
            appName: metadata.app?.name
        )
        try Data(markdown.utf8).write(to: transcript)

        // Compress everything before deleting anything. Interleaving the two would mean a
        // failure on the second track leaves the first one already gone: the retry would then
        // transcribe one track and succeed, quietly writing a meeting with half its voices
        // missing. Both raw tracks survive until both compressed ones exist.
        for track in tracks {
            try await compress(track, track.deletingPathExtension().appendingPathExtension("m4a"), config.aacBitrate)
        }
        for track in tracks {
            try fileManager.removeItem(at: track)
        }

        let record = ProcessedRecord(
            processedAt: Date(),
            elapsedSeconds: Date().timeIntervalSince(startedProcessingAt),
            meetingDurationSeconds: duration,
            transcriptPath: transcript.path
        )
        try record.write(to: folder.appendingPathComponent(ProcessedRecord.fileName))
        return duration
    }

    private func resolveTranscriber() async throws -> any TimedTranscriber {
        if let transcriber { return transcriber }
        let made = try await makeTranscriber()
        transcriber = made
        return made
    }
}
