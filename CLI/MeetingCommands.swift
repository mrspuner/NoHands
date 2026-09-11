import Core
import Dictation
import Foundation
import Meetings

/// `nohands meeting process` — re-run a single folder.
func runMeetingProcess(_ folder: URL) async throws {
    let config = try MeetingsConfig.loadOrCreate()
    let language = (try? DictationConfig.loadOrCreate())?.language

    // Checked before anything is deleted, and the order is the point. A folder whose tracks are
    // already compressed cannot be re-run at all — the pipeline reads the raw WAVs and they are
    // gone — so deleting its `processed.json` first would leave a finished meeting permanently
    // marked failed, skipped by rotation for ever, and repairable only by editing files by hand.
    // That is the same shape the queue's own `.processed` guard exists to prevent, and this
    // command routes around that guard on purpose.
    let fileManager = FileManager.default
    let hasRawTrack = [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName]
        .contains { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    guard hasRawTrack else {
        fail(
            "Папку нельзя прогнать заново: сырых дорожек в ней нет. Если они уже сжаты, читать "
                + "их конвейер пока не умеет — расшифровка идёт только по WAV. Ничего не изменено."
        )
    }
    // A processed folder is re-run, not skipped: the command exists precisely for repeated runs
    // while tuning the threshold.
    try? MeetingErrorFile.remove(in: folder)
    let record = folder.appendingPathComponent(ProcessedRecord.fileName)
    try? fileManager.removeItem(at: record)

    // Two queues over one directory corrupt a good meeting — see `MeetingQueue.config`. This is a
    // second process, so nothing here can prevent that; saying so is the proportionate answer for
    // a tool with one user, where a lock file would be state to clean up after a crash.
    note("Не запускайте эту команду, пока работает приложение: оно разбирает ту же очередь.")

    let queue = MeetingQueue(
        queue: folder.deletingLastPathComponent(),
        archive: folder.deletingLastPathComponent().deletingLastPathComponent(),
        config: config,
        makeTranscriber: { try await ParakeetTranscriber.load(language: language) },
        makeDiarizer: { try await FluidDiarizer.load() },
        report: { outcome in
            if let failure = outcome.failure {
                note("не вышло: \(failure)")
            } else {
                note("готово: \(outcome.minutes ?? 0) мин")
            }
        }
    )
    await queue.enqueue(folder)
}

/// `nohands meeting levels` — a tool for tuning `micThresholdDBFS`.
///
/// Prints the microphone track's utterances next to their level: both the number and the text
/// are visible, so it is clear whether it is the owner's own speech or the room. Printing on an
/// explicit command is not logging; none of this is written anywhere.
func runMeetingLevels(_ folder: URL) async throws {
    let config = try MeetingsConfig.loadOrCreate()
    let language = (try? DictationConfig.loadOrCreate())?.language
    let microphone = folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName)
    guard FileManager.default.fileExists(atPath: microphone.path) else {
        fail("В папке нет \(MeetingAudioRecorder.microphoneFileName) — возможно, дорожки уже сжаты")
    }

    let transcriber = try await ParakeetTranscriber.load(language: language)
    let words = try await transcriber.transcribeTimed(audio: microphone)
    let utterances = Utterance.split(
        words: words, speaker: .me,
        gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
    )

    note("порог сейчас: \(config.micThresholdDBFS) dBFS, реплик: \(utterances.count)")
    for utterance in utterances {
        let level = try PhraseLevel.peakDBFS(of: microphone, from: utterance.start, to: utterance.end)
        let mark = Float(config.micThresholdDBFS) <= level ? " " : "×"
        print(
            String(format: "%@ %6.1f dBFS  [%@]  %@",
                   mark,
                   level.isFinite ? level : -99,
                   MeetingMarkdown.timestamp(utterance.start),
                   utterance.text)
        )
    }
}

/// `nohands meeting summarize` — a tool for tuning `quoteMatchRatio`.
///
/// Unlike the application, this rewrites sections that are already there: the command exists for
/// repeated runs over the same file while the threshold is being chosen, exactly like
/// `meeting process` exists for repeated runs while `micThresholdDBFS` is being chosen.
func runMeetingSummarize(_ file: URL) async throws {
    let config = try MeetingsConfig.loadOrCreate()
    let text = try String(contentsOf: file, encoding: .utf8)
    let index = TranscriptIndex.parse(text)
    guard !index.lines.isEmpty else {
        fail("В файле нет строк транскрипта: \(file.lastPathComponent)")
    }

    let runner = MLXSummaryRunner(
        uvPath: config.uvPath,
        model: config.summaryModel,
        timeout: config.summaryTimeoutSeconds,
        contextTokens: config.summaryContextTokens
    )
    // This command and `MeetingSummarizer` inside the running application each spawn their own
    // 4.3 GB model subprocess; two at once do not fit beside the owner's work on a 16 GB machine.
    note("Не запускайте эту команду, пока работает приложение: две модели по 4,3 ГБ не помещаются в память вместе.")

    let chunks = TranscriptChunks.split(
        index,
        maxSeconds: config.summaryChunkSeconds,
        maxCharacters: Int(Double(config.summaryContextTokens) * MLXSummaryRunner.charactersPerToken)
    )
    note("кусков: \(chunks.count)")
    let started = Date()
    let summary = try await runner.summarize(chunks: chunks)
    note("ответ за \(Int(Date().timeIntervalSince(started))) с")

    let checked = QuoteMatch.check(
        summary.decisions, against: index, threshold: config.quoteMatchRatio
    )
    let checkedTasks = QuoteMatch.check(
        tasks: summary.tasks, against: index, threshold: config.quoteMatchRatio
    )
    note("название: \(summary.title)")
    for decision in checked {
        let stamp = decision.timecode.map { "[\(MeetingMarkdown.timestamp($0))]" } ?? "нет"
        let mark = decision.timecode == nil ? "×" : " "
        note(String(format: "%@ %.2f %@ решение: %@", mark, decision.ratio, stamp, decision.text))
    }
    for task in checkedTasks {
        let stamp = task.timecode.map { "[\(MeetingMarkdown.timestamp($0))]" } ?? "нет"
        let mark = task.timecode == nil ? "×" : " "
        note(String(format: "%@ %.2f %@ задача: %@", mark, task.ratio, stamp, task.text))
    }
    // The six new keys never appear in the owner's config file: `loadOrCreate` only ever writes
    // the whole `meetings` section, and only when it is absent entirely — an existing section
    // gets missing keys from the in-memory default instead. So the knob this command exists to
    // help tune is real but invisible in the owner's file, and naming where it lives is the only
    // way to know it can be turned at all.
    if checked.contains(where: { $0.timecode == nil }) || checkedTasks.contains(where: { $0.timecode == nil }) {
        note("порог quoteMatchRatio правится в \(MeetingsConfig.configFileURL.path), секция meetings")
    }

    let updated = try SummaryInsertion.apply(
        summary: summary,
        decisions: checked,
        tasks: checkedTasks,
        to: text,
        named: file.lastPathComponent,
        mode: .replace
    )
    try Data(updated.utf8).write(to: file, options: .atomic)
    note("записано: \(file.path)")
}

/// `nohands meeting diarize` — labels the voices on the interlocutor track.
///
/// Reads compressed tracks too: both Parakeet and the diarizer open the file through
/// `AVAudioFile`. That is what makes this a tuning tool at all — any meeting in the archive can
/// be labelled, not only the one whose raw tracks have not been deleted yet.
///
/// Prints only, by default. Tuning a threshold against an archive the tool itself rewrites is
/// impossible: the first bad attempt would destroy the very thing being compared against.
func runMeetingDiarize(_ folder: URL, threshold: Double?, write: Bool) async throws {
    var config = try MeetingsConfig.loadOrCreate()
    if let threshold { config.voiceMatchThreshold = threshold }
    let language = (try? DictationConfig.loadOrCreate())?.language

    let system = trackURL(in: folder, named: MeetingAudioRecorder.systemFileName)
    guard let system else {
        fail("В папке нет дорожки собеседников — ни system.wav, ни system.m4a")
    }

    let diarizer = try await FluidDiarizer.load()
    let voices = VoiceClustering.voices(
        from: try await diarizer.segments(of: system),
        threshold: Float(config.voiceMatchThreshold)
    )
    note("порог: \(config.voiceMatchThreshold), голосов: \(voices.count)")

    let store = VoiceStore()
    var book = try await store.book()
    for voice in voices {
        let known = book.match(voice.print, threshold: Float(config.voiceMatchThreshold))
        let name = known.flatMap(\.name) ?? (known == nil ? "новый голос" : "без имени")
        note(
            String(
                format: "  %@: %.0f с речи, %d сегментов — %@",
                voice.id, voice.speechSeconds, voice.segments.count, name
            )
        )
    }
    // Cosines between every pair of this meeting's voices: the number the threshold is
    // actually chosen from.
    for (index, left) in voices.enumerated() {
        for right in voices[(index + 1)...] {
            note(
                String(
                    format: "  %@ ~ %@: %.3f", left.id, right.id,
                    VoicePrint.cosine(left.print, right.print)
                )
            )
        }
    }

    guard write else {
        note("ничего не записано — добавьте --write, чтобы переписать транскрипт и базу")
        return
    }

    let transcriber = try await ParakeetTranscriber.load(language: language)
    let words = try await transcriber.transcribeTimed(audio: system)
    let resolution = MeetingVoices.resolve(
        voices: voices, meeting: folder.lastPathComponent, book: &book, config: config
    )
    let theirs = Utterance.split(
        assigned: VoiceAssignment.assign(words: words, to: voices),
        gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
    )

    let microphone = trackURL(in: folder, named: MeetingAudioRecorder.microphoneFileName)
    var mine: [Utterance] = []
    if let microphone {
        let all = Utterance.split(
            words: try await transcriber.transcribeTimed(audio: microphone),
            speaker: .me, gap: config.phraseGapSeconds, maxLength: config.maxPhraseSeconds
        )
        mine = try PhraseLevel.passing(all, thresholdDBFS: Float(config.micThresholdDBFS)) {
            try PhraseLevel.peakDBFS(of: microphone, from: $0.start, to: $0.end)
        }
    }

    let metadata = try MeetingMetadata.read(
        from: folder.appendingPathComponent(MeetingMetadata.fileName)
    )
    let merged = MeetingTranscript.merge(
        mine: mine, theirs: theirs,
        microphoneStartedAt: metadata.microphoneStartedAt,
        systemStartedAt: metadata.systemStartedAt
    )
    let labels = SpeakerLabels.make(transcript: merged, names: resolution.names)

    let file = MeetingFolder.archiveURL.appendingPathComponent(folder.lastPathComponent + ".md")
    let existing = try String(contentsOf: file, encoding: .utf8)
    let updated = try TranscriptSection.replace(
        in: existing,
        transcript: merged,
        labels: labels,
        named: file.lastPathComponent
    )
    try Data(updated.utf8).write(to: file, options: .atomic)

    // The same rows the queue writes, by the same rule: positions come from the file's own
    // header, not from the diarizer's voice list — otherwise the archive pass would read an
    // untouched file as a rename.
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: labels.order.enumerated().map { position, voice in
                MeetingLabels.Label(
                    position: position + 1,
                    voiceId: resolution.identities[voice],
                    renderedName: labels.label(for: .voice(voice))
                )
            }
        )
    )
    try await store.save(book)
    note("переписано: \(file.lastPathComponent), участников \(labels.participants.count)")
}

/// The raw track, or the compressed one when the raw copy is already gone.
private func trackURL(in folder: URL, named name: String) -> URL? {
    let raw = folder.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: raw.path) { return raw }
    let compressed = raw.deletingPathExtension().appendingPathExtension("m4a")
    return FileManager.default.fileExists(atPath: compressed.path) ? compressed : nil
}
