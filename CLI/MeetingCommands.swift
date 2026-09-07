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
