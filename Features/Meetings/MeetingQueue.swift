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
        case partiallyCompressed(String)
        case nothingRecognised(String)
        /// Distinct from `nothingRecognised`: the microphone track did produce words, and every
        /// one of them was filtered out by `micThresholdDBFS`. Reporting this as generic silence
        /// would send the owner looking at the recording, when the actual cause — and the actual
        /// fix — is the threshold in the config.
        case micThresholdAteEverything(String)

        var errorDescription: String? {
            switch self {
            case .noTracks(let name):
                return "No audio track at all in \(name)"
            case .alreadyCompressed(let name):
                return "Tracks in \(name) are already compressed, nothing left to transcribe"
            case .partiallyCompressed(let name):
                return "One track in \(name) is compressed and the other is not — a previous attempt was interrupted. Sort the folder out by hand"
            case .nothingRecognised(let name):
                return "No words were recognised in either track of \(name)"
            case .micThresholdAteEverything(let name):
                return "The microphone track in \(name) had speech, but every utterance was below micThresholdDBFS — check the threshold"
            }
        }
    }

    /// Exactly one of a meeting's voices being labelled, or diarization having failed for a
    /// named reason — never both. `MeetingMarkdown.render` takes `labels` and
    /// `diarizationFailure` as two independent optionals and would accept either combination,
    /// including both at once, a fourth state the design does not name. Holding the result of
    /// diarization in one value here, converted to that pair only immediately before the call,
    /// makes the excluded combination unrepresentable instead of merely untested.
    private enum DiarizationOutcome {
        case none
        case labels(SpeakerLabels)
        case failure(String)

        var forRendering: (labels: SpeakerLabels?, failure: String?) {
            switch self {
            case .none: return (nil, nil)
            case .labels(let labels): return (labels, nil)
            case .failure(let reason): return (nil, reason)
            }
        }
    }

    private let queue: URL
    private let archive: URL
    /// Reconfigured in place by `update(config:makeTranscriber:makeDiarizer:)` — the actor itself
    /// is never torn down and rebuilt, which is why this and `makeTranscriber` below are `var`.
    ///
    /// The alternative looked harmless at first: throw the actor away on every settings reload
    /// and build a fresh one, exactly like `MeetingCoordinator` does. It is not. «Перечитать
    /// конфиг» is the single reload path for every setting in the application, and a backlog
    /// drain can run for hours — the design document puts 40–65 hours of meetings a month at
    /// roughly ten-to-one processing. A reload landing anywhere in that window would start a
    /// second actor pointed at the same queue directory, and `Failure.partiallyCompressed` does
    /// not catch it: that guard only fires when a *fresh* `process()` finds a pre-existing mixed
    /// state, and each actor's own compress-then-delete pass is internally consistent on its
    /// own. The second actor's `removeItem` simply gets "no such file" for a track the first one
    /// already deleted — an ordinary error, filed as `error.txt` over a meeting that in fact
    /// succeeded — and because folder state reads the error file before the processed record,
    /// that meeting is retried forever afterwards, reporting `alreadyCompressed`.
    private var config: MeetingsConfig
    private var makeTranscriber: @Sendable () async throws -> any TimedTranscriber
    private var makeDiarizer: @Sendable () async throws -> any Diarizing
    private let voiceStore: VoiceStore
    private let measureLevel: @Sendable (URL, TimeInterval, TimeInterval) throws -> Float
    private let compress: @Sendable (URL, URL, Int) async throws -> Void
    private let report: @Sendable (Outcome) -> Void

    /// Held only while there is work. Loading costs 0.3 s from cache and 470 MB resident, and
    /// the alternative — sharing the transcriber dictation keeps — would put a dictation behind
    /// a whole meeting in the actor's queue.
    private var transcriber: (any TimedTranscriber)?
    /// Held while there is work, like the transcriber: 21 MB of models and 0.3 s from cache.
    private var diarizer: (any Diarizing)?
    private var pending: [URL] = []
    private var draining = false

    public init(
        queue: URL = MeetingFolder.queueURL,
        archive: URL = MeetingFolder.archiveURL,
        config: MeetingsConfig,
        makeTranscriber: @escaping @Sendable () async throws -> any TimedTranscriber,
        makeDiarizer: @escaping @Sendable () async throws -> any Diarizing,
        voiceStore: VoiceStore = VoiceStore(),
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
        self.makeDiarizer = makeDiarizer
        self.voiceStore = voiceStore
        self.measureLevel = measureLevel
        self.compress = compress
        self.report = report
    }

    public func enqueue(_ folder: URL) async {
        pending.append(folder)
        await drain()
    }

    /// Applies a settings reload without rebuilding the actor — see `config` for why a rebuild
    /// is unsafe here. Safe to call at any time, including while a drain is in progress:
    /// `process` reads `config` once at its own start, so a folder already being worked on keeps
    /// the settings it began with, and only the next one picks up whatever this call left behind.
    public func update(
        config: MeetingsConfig,
        makeTranscriber: @escaping @Sendable () async throws -> any TimedTranscriber,
        makeDiarizer: @escaping @Sendable () async throws -> any Diarizing
    ) {
        self.config = config
        self.makeTranscriber = makeTranscriber
        self.makeDiarizer = makeDiarizer
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let folder = pending.removeFirst()
            // A folder that already carries `processed.json` is finished. Running it again would
            // find its tracks compressed, write that failure over a perfectly good record, and —
            // because the error file is read before the record — leave a finished meeting looking
            // broken for good. Nothing to do here, and nothing to say either: a notice would
            // announce a meeting the owner has already seen.
            if case .processed = MeetingFolderState.of(folder) { continue }
            report(await run(folder))
        }
        // Nothing left to do: the models go, and the resting footprint is what it was before.
        transcriber = nil
        diarizer = nil
        draining = false
    }

    /// Everything in the queue that has not been through the pipeline: leftovers from a
    /// previous run and folders a previous attempt failed on. Failures are retried at launch
    /// rather than on a timer — the typical one either fixes itself by the next launch (the
    /// model could not download) or never fixes itself (a broken file), and three quick
    /// attempts on a broken file are three wasted minutes.
    public func scanAll() async {
        for folder in folders() {
            switch MeetingFolderState.of(folder) {
            case .waiting, .failed:
                pending.append(folder)
            case .recording, .processed:
                continue
            }
        }
        await drain()
    }

    /// Drops the compressed audio of meetings older than the retention window.
    ///
    /// Only folders that have actually been processed. Rotation exists to throw away a copy of
    /// the audio, never a meeting: an untranscribed folder means the transcript does not exist
    /// yet, and deleting it would destroy the only record. Folders carrying `error.txt` are
    /// spared for the same reason, however old they are.
    public func sweep(now: Date = Date()) async {
        let window = TimeInterval(config.audioRetentionDays) * 86400
        for folder in folders() {
            guard case .processed = MeetingFolderState.of(folder) else { continue }
            let metadataURL = folder.appendingPathComponent(MeetingMetadata.fileName)
            guard let metadata = try? MeetingMetadata.read(from: metadataURL) else { continue }
            guard now.timeIntervalSince(metadata.startedAt) > window else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func folders() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: queue, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )
        return (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        // Snapshotted once, before any suspension point below.
        // `update(config:makeTranscriber:makeDiarizer:)` can land on any of the awaits further
        // down, and a folder cut into phrases with one gap value and then gated by a different
        // microphone threshold would be a defect nobody could reproduce from outside this actor.
        let config = self.config
        let fileManager = FileManager.default
        let metadata = try MeetingMetadata.read(
            from: folder.appendingPathComponent(MeetingMetadata.fileName)
        )
        let system = folder.appendingPathComponent(MeetingAudioRecorder.systemFileName)
        let microphone = folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName)
        // Which tracks to work on is decided from the shape of the whole folder, never from
        // "whichever WAVs happen to still be there". A track whose raw copy is gone while its
        // compressed one exists was already consumed by an earlier attempt, and reading that as
        // "this meeting only had one track" is how a retry rewrites the archive with half the
        // voices missing and calls it a success. That is the worst thing this queue can do, so
        // it is a named failure instead.
        // A `for` loop rather than `.map`: a `map` closure here would capture `fileManager`,
        // which this SDK declares non-Sendable, while the same `fileManager` is also used
        // synchronously further down in this function. SE-0414's region-based isolation checking
        // treats that as a possible data race and refuses to compile the `map` version. A `for`
        // loop does not open a new isolation region for its body, so the same use compiles.
        var states: [(track: URL, state: TrackState)] = []
        for track in [system, microphone] {
            states.append((track: track, state: trackState(of: track, fileManager: fileManager)))
        }
        let tracks = states.filter { $0.state == .raw }.map(\.track)
        let consumed = states.contains { $0.state == .compressed }

        if consumed && !tracks.isEmpty {
            throw Failure.partiallyCompressed(folder.lastPathComponent)
        }
        guard !tracks.isEmpty else {
            throw consumed
                ? Failure.alreadyCompressed(folder.lastPathComponent)
                : Failure.noTracks(folder.lastPathComponent)
        }

        let transcriber = try await resolveTranscriber()

        var theirs: [Utterance] = []
        // Hoisted above the `if tracks.contains(system)` block that fills it in, because the
        // label-building step below needs to know whether diarization actually found anyone —
        // an empty result is a legitimate "nobody was separated", not a failure, and must read
        // exactly as phase 2б's single nameless voice did.
        var voices: [MeetingVoice] = []
        var diarizationOutcome: DiarizationOutcome = .none
        // Names and cross-meeting identities, bundled as `MeetingVoices` already returns them
        // rather than split into two locals carried separately to the two places that read them.
        var resolution: MeetingVoices.Resolution?
        // Held until the markdown is safely written: the book is saved once, at the end, so a
        // failure between the two never leaves fingerprints recorded for a meeting that has no
        // file.
        var updatedBook: VoiceBook?

        // Reuses `tracks`, computed above, instead of asking the file system the same question
        // again — see the comment on `states` above about why the raw/compressed distinction is
        // decided once, from the whole folder's shape.
        if tracks.contains(system) {
            let words = try await transcriber.transcribeTimed(audio: system)
            if config.diarizationEnabled {
                do {
                    let diarizer = try await resolveDiarizer()
                    voices = VoiceClustering.voices(
                        from: try await diarizer.segments(of: system),
                        threshold: Float(config.voiceMatchThreshold)
                    )
                } catch {
                    // Never fatal to the meeting. A thrown error here would mark the folder
                    // failed, and its retry would find the tracks compressed and refuse for
                    // ever — the meeting would be lost over a missing 21 MB model.
                    //
                    // `.noSpeech` is not a defect: the interlocutors' track can be legitimately
                    // silent while the owner talked. The sentence names the diarizer's own
                    // finding rather than asserting a fact about the track — a claim that could
                    // otherwise sit, permanently, directly above lines Parakeet did transcribe
                    // on that same track.
                    if let diarizationError = error as? DiarizationError, diarizationError == .noSpeech {
                        diarizationOutcome = .failure("диаризация не нашла речи на дорожке собеседников")
                    } else {
                        diarizationOutcome = .failure(error.localizedDescription)
                    }
                }

                // Separated from the diarizer's own do/catch above: splitting the voices within
                // one meeting needs no book at all, only the clustering just computed. The book
                // supplies exclusively names and cross-meeting memory, so a book that will not
                // parse must cost only those — never the split diarization already found. A
                // meeting labelled «Собеседник 1 / Собеседник 2» with no names is exactly the
                // truth in that case. The owner still learns the book is broken, through Task 7's
                // archive pass reporting it against every later meeting — not through this file,
                // which would otherwise blame diarization for a storage fault.
                if !voices.isEmpty {
                    do {
                        var book = try await voiceStore.book()
                        resolution = MeetingVoices.resolve(
                            voices: voices,
                            meeting: folder.lastPathComponent,
                            book: &book,
                            config: config
                        )
                        updatedBook = book
                    } catch {
                        resolution = nil
                        updatedBook = nil
                    }
                }
            }
            theirs = Utterance.split(
                assigned: VoiceAssignment.assign(words: words, to: voices),
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
        }

        var mine: [Utterance] = []
        // Kept before the gate below so a folder where the microphone spoke but every utterance
        // was too quiet can be told apart from one where the microphone genuinely heard nothing —
        // see `Failure.micThresholdAteEverything`.
        var microphoneUtterancesBeforeGate = 0
        if tracks.contains(microphone) {
            let all = Utterance.split(
                words: try await transcriber.transcribeTimed(audio: microphone),
                speaker: .me,
                gap: config.phraseGapSeconds,
                maxLength: config.maxPhraseSeconds
            )
            microphoneUtterancesBeforeGate = all.count
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
        guard !merged.isEmpty else {
            // `theirs` is necessarily empty too here — otherwise `merged` would not be — so a
            // non-zero pre-gate microphone count means the threshold, not silence, ate the
            // meeting.
            if microphoneUtterancesBeforeGate > 0 {
                throw Failure.micThresholdAteEverything(folder.lastPathComponent)
            }
            throw Failure.nothingRecognised(folder.lastPathComponent)
        }

        // Built from the merged transcript rather than from `voices`, because the order in the
        // header must be the order the reader meets people in the file — and that is decided by
        // the merge, which interleaves both tracks.
        //
        // `!voices.isEmpty` is the guard that matters: an empty result is diarization succeeding
        // at finding nobody, and must produce the same file phase 2б wrote — no `participants:`,
        // replies read as plain «Собеседник». `merged` cannot be empty here (the guard above
        // already threw otherwise), and `SpeakerLabels.make` on a transcript with no `.voice`
        // entries returns an empty `order`, which the two `!labels.order.isEmpty` guards below
        // already treat as "nothing to say" — so neither is checked again here.
        if case .none = diarizationOutcome, config.diarizationEnabled, !voices.isEmpty {
            diarizationOutcome = .labels(
                SpeakerLabels.make(transcript: merged, names: resolution?.names ?? [:])
            )
        }

        let duration = try tracks.map { try AudioDuration.seconds(of: $0) }.max() ?? 0

        // Markdown before compression, deliberately: if the encoder falls over, the text is
        // already in the archive and the raw audio is still on disk.
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        let transcript = archive.appendingPathComponent(folder.lastPathComponent + ".md")
        // The threshold is applied here rather than in the renderer because it is the panel's own
        // — the same ten seconds that decide whether the owner is warned while the meeting runs,
        // so the archive and the panel never disagree about whether a track was silent. Below it
        // the archive says nothing: a gap that short is a gap between buffers.
        let silence = metadata.trailingMicrophoneSilenceSeconds
        // `labels` and `diarizationFailure` come out of one value rather than two independent
        // optionals: `MeetingMarkdown.render` would happily accept both at once, a fourth state
        // the design does not name, and `diarizationOutcome` makes that state unrepresentable
        // here rather than merely untested.
        let (labels, diarizationFailure) = diarizationOutcome.forRendering
        let markdown = MeetingMarkdown.render(
            transcript: merged,
            startedAt: metadata.startedAt,
            durationSeconds: duration,
            appName: metadata.app?.name,
            trailingMicrophoneSilenceSeconds:
                (silence ?? 0) >= MeetingCoordinator.microphoneSilenceThreshold ? silence : nil,
            // Passed through untouched: the number above decides whether the archive says
            // anything about the microphone at all, and this decides which of the two things it
            // says. No threshold of its own, and no default — `nil`, a folder recorded before
            // this was measured, is a third answer the renderer needs to see rather than a
            // missing value to fill in here.
            microphoneSawAudio: metadata.microphoneSawAudio,
            labels: labels,
            diarizationFailure: diarizationFailure
        )
        try Data(markdown.utf8).write(to: transcript)

        // Written after the file exists: the row says "the archive holds a file whose header
        // means these voices", and a row without its file would let the archive pass read a
        // rename out of thin air.
        //
        // The rows are built from `labels` — from what the file actually shows — and never from
        // the voices the diarizer found. Those two can differ: a voice all of whose words went
        // to a neighbour has no line in the transcript and no position in the header. Numbering
        // rows from the diarizer's list would shift every position after it by one, and the
        // archive pass would then read an untouched file as a rename.
        if var book = updatedBook, let labels, !labels.order.isEmpty {
            let rows = labels.order.enumerated().map { position, voice in
                MeetingLabels.Label(
                    position: position + 1,
                    voiceId: resolution?.identities[voice],
                    renderedName: labels.label(for: .voice(voice))
                )
            }
            book.record(MeetingLabels(file: transcript.lastPathComponent, labels: rows))
            try? await voiceStore.save(book)
        }

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

    /// What one track looks like on disk right now.
    ///
    /// `absent` is a legitimate outcome — a meeting where the microphone never delivered a
    /// buffer has no `mic.wav` and never had one — which is exactly why it has to be told apart
    /// from `compressed`, where the raw track existed and is gone.
    private enum TrackState {
        case raw
        case compressed
        case absent
    }

    private func trackState(of track: URL, fileManager: FileManager) -> TrackState {
        if fileManager.fileExists(atPath: track.path) { return .raw }
        let compressed = track.deletingPathExtension().appendingPathExtension("m4a")
        return fileManager.fileExists(atPath: compressed.path) ? .compressed : .absent
    }

    private func resolveTranscriber() async throws -> any TimedTranscriber {
        if let transcriber { return transcriber }
        let made = try await makeTranscriber()
        transcriber = made
        return made
    }

    private func resolveDiarizer() async throws -> any Diarizing {
        // A failed load is not cached — same as `resolveTranscriber` — so the next folder in the
        // drain retries it, which is what lets a transient failure (a model download that timed
        // out, say) recover on its own without restarting the queue.
        if let diarizer { return diarizer }
        let made = try await makeDiarizer()
        diarizer = made
        return made
    }
}
