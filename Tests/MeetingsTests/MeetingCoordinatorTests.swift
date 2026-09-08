import Core
import Foundation
import Testing
@testable import Meetings

// What a coordinator test can and cannot reach: the folder, the metadata, the panel and the
// order the two asynchronous halves run in are all here; `SCStream` and CoreAudio are not, and
// are checked by the owner on a live meeting. The seams that make the rest testable are the
// queue directory, the capture factory and the process reader, and nothing else is faked.

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

private let config = MeetingsConfig(
    triggerApps: [MeetingsConfig.TriggerApp(bundleID: "ru.yandex.desktop.telemost", slug: "telemost")],
    excludedApps: ["com.spotify.client"],
    silenceSeconds: 60,
    autoStopSeconds: 120,
    startPromptSeconds: 30,
    maxMeetingSeconds: 14400,
    phraseGapSeconds: 1.0,
    maxPhraseSeconds: 40,
    micThresholdDBFS: -30,
    audioRetentionDays: 7,
    aacBitrate: 32000
)

private let telemost = AudioProcessMonitor.State(
    pid: 4242,
    bundleID: "ru.yandex.desktop.telemost",
    name: "Телемост",
    isRunningInput: true,
    isRunningOutput: true
)

/// The same process holding nothing: what letting go of both devices looks like to the watcher.
private let telemostIdle = AudioProcessMonitor.State(
    pid: 4242,
    bundleID: "ru.yandex.desktop.telemost",
    name: "Телемост",
    isRunningInput: false,
    isRunningOutput: false
)

/// Stands in for `MeetingAudioRecorder`, which needs a screen recording permission and a real
/// `SCStream`. Creates the two track files the way the real one does — on the first buffer, not
/// at start — so tests about the folder see the same shape on disk.
@MainActor
private final class FakeCapture: MeetingCapture {
    let folder: URL
    let excluded: [String]
    var startError: Error?
    var stopError: Error?
    var failure: String?
    private(set) var started = false
    private(set) var stopped = false
    /// What the queue directory held at the moment the capture was asked to close. A rename that
    /// did not wait for this would show up here as a folder without its leading dot.
    private(set) var queueWhenStopped: [String] = []
    /// What the real recorder hands its stream delegate.
    private let onFailureWhileRecording: @Sendable (String) -> Void
    /// What the next `microphoneSilentSeconds()` answers. The tests set it directly: this fake
    /// has no audio to be silent about.
    var silentSeconds: TimeInterval = 0
    /// What the next `stop()` reports as `Outcome.microphoneSilentSeconds` — the number
    /// `keepDraft` turns into a sentence on the panel. Separate from `silentSeconds`, which
    /// answers the polling question asked while the meeting is still live.
    var silentAtStop: TimeInterval = 0
    /// What the next `stop()` reports as `Outcome.microphoneSawAudio`. Defaults to the ordinary
    /// case — a track that heard something — so that the tests which care about an empty track
    /// have to say so, rather than getting the harsher sentence by omission.
    var sawAudioAtStop = true
    /// Set to make `microphoneSilentSeconds()` suspend instead of answering at once, holding the
    /// continuation in `pendingSilenceCheck` until `resumeMicrophoneCheck()` releases it. Models
    /// the real gap between a poll asking the question and the answer arriving — the gap in
    /// which a meeting can end before the answer does, which is what the coordinator's
    /// stale-check guard exists for.
    var suspendMicrophoneCheck = false
    private var pendingSilenceCheck: CheckedContinuation<TimeInterval, Never>?
    /// How many times `microphoneSilentSeconds()` was called, suspended or not. A second check
    /// running concurrently with a first shows up here as 2 — the direct measurement of the
    /// reentrancy guard holding, which nothing else in this fake can prove.
    private(set) var microphoneSilentSecondsCallCount = 0
    /// Every uid the coordinator asked to rebind to, in order.
    private(set) var rebinds: [String] = []
    /// Set to make a rebind fail the way a stream that died would.
    var rebindError: Error?
    /// Set to make `rebindMicrophone(to:)` suspend instead of returning at once, holding the
    /// continuation in `pendingRebind` until `resumeRebind()` releases it. Models the real gap
    /// inside `updateConfiguration` — the same kind of gap `suspendMicrophoneCheck` models on the
    /// read side, but here on the write side, where a stale check can still be sitting when the
    /// meeting it was asked about ends.
    var suspendRebind = false
    private var pendingRebind: CheckedContinuation<Void, Never>?

    init(folder: URL, excluded: [String], onFailureWhileRecording: @escaping @Sendable (String) -> Void) {
        self.folder = folder
        self.excluded = excluded
        self.onFailureWhileRecording = onFailureWhileRecording
    }

    /// The stream dying mid-meeting, as the delegate would report it.
    ///
    /// Deliberately as dumb as `SCStream` is: it reports whenever it likes, including after the
    /// capture was stopped and including twice. The real recorder is what filters those, and it
    /// is tested for it separately — here the point is that the coordinator survives them too,
    /// so anything this fake refused to send would leave that untested.
    func die(_ message: String) {
        onFailureWhileRecording(message)
    }

    func start() async throws {
        started = true
        if let startError { throw startError }
        for name in [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName] {
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent(name).path, contents: Data([0, 1, 2, 3])
            )
        }
    }

    func stop() async throws -> MeetingAudioRecorder.Outcome {
        // Closing a real capture takes time. Yielding gives anything that failed to wait for it
        // room to run first, so the snapshot below would catch a rename that jumped the queue.
        for _ in 0..<8 { await Task.yield() }
        queueWhenStopped = (try? FileManager.default.contentsOfDirectory(
            atPath: folder.deletingLastPathComponent().path
        )) ?? []
        stopped = true
        if let stopError { throw stopError }
        return MeetingAudioRecorder.Outcome(
            systemURL: folder.appendingPathComponent(MeetingAudioRecorder.systemFileName),
            microphoneURL: folder.appendingPathComponent(MeetingAudioRecorder.microphoneFileName),
            systemStartedAt: 0.25,
            microphoneStartedAt: 0.5,
            failure: failure,
            microphoneSilentSeconds: silentAtStop,
            microphoneSawAudio: sawAudioAtStop
        )
    }

    func microphoneSilentSeconds() async -> TimeInterval {
        microphoneSilentSecondsCallCount += 1
        guard suspendMicrophoneCheck else { return silentSeconds }
        return await withCheckedContinuation { pendingSilenceCheck = $0 }
    }

    /// Releases a `microphoneSilentSeconds()` call suspended by `suspendMicrophoneCheck`, with
    /// whatever `silentSeconds` holds at the moment of release rather than at the moment of the
    /// call — the answer arrives late, and a late answer reflects the microphone at the time it
    /// was finally read, not at the time it was asked.
    func resumeMicrophoneCheck() {
        pendingSilenceCheck?.resume(returning: silentSeconds)
        pendingSilenceCheck = nil
    }

    func rebindMicrophone(to deviceUID: String) async throws {
        if suspendRebind {
            await withCheckedContinuation { pendingRebind = $0 }
        }
        if let rebindError { throw rebindError }
        rebinds.append(deviceUID)
        // The real recorder restarts the count from the new binding; a fake that did not would
        // let one test's rebind look like three.
        silentSeconds = 0
    }

    /// Releases a `rebindMicrophone(to:)` call suspended by `suspendRebind`.
    func resumeRebind() {
        pendingRebind?.resume()
        pendingRebind = nil
    }
}

@MainActor
private final class Harness {
    let queue: URL
    private(set) var shown: [MeetingPanelState] = []
    private(set) var hidden: [TimeInterval] = []
    private(set) var blocked: [Bool] = []
    /// Folders handed to phase 2б. The rename is the only hand-off point, and it has two branches.
    private(set) var handedToQueue: [URL] = []
    /// The input's sample rate when it is narrowband, nil when the band is fine — one entry per
    /// time the coordinator said so.
    private(set) var narrowband: [Double?] = []
    /// Одна запись на каждый раз, когда координатор сказал про немой микрофон. Массив, а не
    /// флаг, по той же причине, что и `narrowband`: проверяется не только что он сказал, но и
    /// сколько раз — надпись не должна мигать раз в секунду весь час.
    private(set) var microphoneSilent: [Bool] = []
    private(set) var captures: [FakeCapture] = []
    /// What the coordinator reads instead of the machine's real default input. A seam for the
    /// same reason as `processes`: the warning and `meeting.json` both come from this, and the
    /// machine running the tests has whatever microphone it has.
    var inputDevice: AudioInputDevice?
    /// What the next `poll` reads. `nil` is a failed system call, `[]` is nobody holding a
    /// device — the distinction several tests below exist for.
    var processes: [AudioProcessMonitor.State]? = []
    var startError: Error?
    var stopError: Error?
    var captureFailure: String?
    /// Whether a dictation is in flight right now — what the real coordinator asks the dictation
    /// coordinator once a second.
    var dictating = false
    var coordinator: MeetingCoordinator!

    /// - Parameter queueIsAFile: puts an ordinary file where the queue directory belongs, which
    ///   is how a folder that cannot be created is produced without filling the disk. Every
    ///   `createDraft` then throws from inside the effect loop — the one synchronous failure
    ///   path either coordinator has.
    init(config: MeetingsConfig = config, queueIsAFile: Bool = false) throws {
        queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if queueIsAFile {
            FileManager.default.createFile(atPath: queue.path, contents: Data())
        } else {
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        }
        coordinator = MeetingCoordinator(
            config: config,
            queue: queue,
            showPanel: { [weak self] in self?.shown.append($0) },
            hidePanel: { [weak self] in self?.hidden.append($0) },
            onNarrowbandInput: { [weak self] in self?.narrowband.append($0) },
            onMicrophoneSilent: { [weak self] in self?.microphoneSilent.append($0) },
            onDictationBlocked: { [weak self] in self?.blocked.append($0) },
            isDictating: { [weak self] in self?.dictating ?? false },
            readInputDevice: { [weak self] in self?.inputDevice },
            readProcesses: { [weak self] in
                guard let self else { return [] }
                return processes
            },
            makeCapture: { [weak self] folder, excluded, onFailureWhileRecording in
                let capture = FakeCapture(
                    folder: folder,
                    excluded: excluded,
                    onFailureWhileRecording: onFailureWhileRecording
                )
                capture.startError = self?.startError
                capture.stopError = self?.stopError
                capture.failure = self?.captureFailure
                self?.captures.append(capture)
                return capture
            },
            onFolderReady: { [weak self] in self?.handedToQueue.append($0) }
        )
    }

    deinit { try? FileManager.default.removeItem(at: queue) }

    var entries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: queue.path)) ?? []).sorted()
    }

    var drafts: [String] { entries.filter { $0.hasPrefix(".draft-") } }
    var handedOver: [String] { entries.filter { !$0.hasPrefix(".draft-") } }

    func metadata(of folder: String) throws -> MeetingMetadata {
        try MeetingMetadata.read(
            from: queue.appendingPathComponent(folder).appendingPathComponent(MeetingMetadata.fileName)
        )
    }
}

/// A WAV whose `data` length field is still at the placeholder a crash leaves behind: the audio
/// bytes are on disk, the header says there are none. Hand-built rather than written through
/// `AVAudioFile`, because all this needs to prove is that the repair was reached.
private func brokenWav(at url: URL, audioBytes: Int = 64) throws {
    var data = Data()
    func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: UInt32) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
    func append16(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
    append("RIFF")
    // The size a writer puts down when it creates the file and never gets to update: the header
    // alone, before any audio.
    append32(36)
    append("WAVE")
    append("fmt ")
    append32(16)
    append16(1)
    append16(1)
    append32(16000)
    append32(32000)
    append16(2)
    append16(16)
    append("data")
    append32(0)
    data.append(Data(repeating: 7, count: audioBytes))
    try data.write(to: url)
}

private func declaredDataSize(at url: URL) throws -> UInt32 {
    let data = try Data(contentsOf: url)
    var value: UInt32 = 0
    for byte in data[40..<44].reversed() { value = (value << 8) | UInt32(byte) }
    return value
}

private func orphanDraft(in queue: URL, startedAt: Date = noon, broken: Bool = false) throws -> URL {
    let draft = try MeetingFolder.createDraft(in: queue, startedAt: startedAt, slug: "telemost")
    try MeetingMetadata(
        startedAt: startedAt,
        stoppedAt: nil,
        app: MeetingMetadata.App(bundleID: "ru.yandex.desktop.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: nil,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil,
        trailingMicrophoneSilenceSeconds: nil
    ).write(to: draft.appendingPathComponent(MeetingMetadata.fileName))
    if broken {
        for name in [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName] {
            try brokenWav(at: draft.appendingPathComponent(name))
        }
    }
    return draft
}

// MARK: - The orphan a crash left behind

// Spec §10: a draft left by a crashed application is neither deleted nor adopted in silence.
@Test @MainActor func anOrphanDraftIsOfferedRatherThanDeletedOrAdopted() throws {
    let harness = try Harness()
    let draft = try orphanDraft(in: harness.queue)

    harness.coordinator.adoptOrphans(at: noon.addingTimeInterval(600))

    #expect(harness.shown.count == 1)
    guard case .orphanFound(let duration) = harness.shown.first else {
        Issue.record("expected an orphan prompt, got \(harness.shown)")
        return
    }
    #expect(duration >= 0)
    #expect(FileManager.default.fileExists(atPath: draft.path))
    #expect(harness.handedOver.isEmpty)
}

// An unclosed WAV declares no audio at all, so handing one over without repairing it would hand
// phase 2б a meeting that opens to silence.
@Test @MainActor func savingAnOrphanRepairsBothHeadersBeforeHandingTheFolderOver() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue, broken: true)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.keep, at: noon)

    #expect(harness.drafts.isEmpty)
    #expect(harness.handedOver.count == 1)
    let folder = harness.queue.appendingPathComponent(harness.handedOver[0])
    for name in [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName] {
        #expect(try declaredDataSize(at: folder.appendingPathComponent(name)) == 64)
    }
}

// An orphaned draft the owner chose to keep is the rename's second branch, and it is just as
// obligated to reach the queue.
@Test @MainActor func keepingAnOrphanedDraftAlsoHandsItToTheQueue() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.keep, at: noon)

    #expect(harness.handedToQueue.count == 1)
    #expect(harness.handedToQueue[0].lastPathComponent.hasPrefix(".draft-") == false)
}

// The panel says what an answer did, on the orphan path too. A panel that just collapsed left
// the owner unable to tell a saved recording from a deleted one — the complaint that produced
// the meeting notices in the first place, and this was the last path still silent.
@Test @MainActor func answeringAnOrphanPromptSaysWhatItDid() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.keep, at: noon)

    if case .saved = harness.shown.last {
    } else {
        Issue.record("keeping an orphan draft said nothing: \(String(describing: harness.shown.last))")
    }
}

@Test @MainActor func deletingAnOrphanSaysSoRatherThanCollapsingSilently() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.delete, at: noon)

    #expect(harness.shown.last == .deleted)
}

@Test @MainActor func deletingAnOrphanIsTheOnlyThingThatRemovesIt() throws {
    let harness = try Harness()
    let draft = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.delete, at: noon)

    #expect(!FileManager.default.fileExists(atPath: draft.path))
    #expect(harness.entries.isEmpty)
}

// The same rule as everywhere else in this feature: silence saves.
@Test @MainActor func anUnansweredOrphanPromptSavesRatherThanDeletes() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.poll(now: noon.addingTimeInterval(config.autoStopSeconds))

    #expect(harness.drafts.isEmpty)
    #expect(harness.handedOver.count == 1)
}

@Test @MainActor func anOrphanPromptWaitsOutTheThresholdBeforeSavingItself() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.poll(now: noon.addingTimeInterval(config.autoStopSeconds - 1))

    #expect(harness.handedOver.isEmpty)
    #expect(harness.drafts.count == 1)
}

// A meeting takes the panel, so the prompt is no longer on screen. Letting it time out from
// behind a recording would turn "unanswered" into "never seen", and the decision would be made
// for a prompt nobody could read. It goes back up once the machine is resting again.
@Test @MainActor func anOrphanPromptCoveredByAMeetingIsOfferedAgainAfterwards() async throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    harness.processes = [telemost]
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    harness.coordinator.poll(now: noon.addingTimeInterval(config.autoStopSeconds + 1))
    #expect(harness.drafts.count == 2)

    harness.coordinator.answer(.decline, at: noon.addingTimeInterval(config.autoStopSeconds + 2))
    await harness.coordinator.settle()
    // The refusal is remembered until the application lets both devices go, so the machine gets
    // there before it is resting again.
    harness.processes = [telemostIdle]
    harness.coordinator.poll(now: noon.addingTimeInterval(config.autoStopSeconds + 3))

    #expect(harness.drafts.count == 1)
    #expect(harness.shown.filter { if case .orphanFound = $0 { return true } else { return false } }.count == 2)
}

// A named reason is worth nothing if the next prompt pushes it off the panel a second later.
// It gets the same dwell as any other failure, and the queue waits behind it.
@Test @MainActor func aFailedOrphanReasonKeepsThePanelBeforeTheNextPromptAppears() throws {
    let harness = try Harness()
    let first = try orphanDraft(in: harness.queue, startedAt: noon)
    _ = try orphanDraft(in: harness.queue, startedAt: noon.addingTimeInterval(3600))
    // Block the hand-off of the first draft: the name it would be renamed to is already taken.
    try FileManager.default.createDirectory(
        at: harness.queue.appendingPathComponent(
            String(first.lastPathComponent.dropFirst(MeetingFolder.draftPrefix.count))
        ),
        withIntermediateDirectories: false
    )
    harness.coordinator.adoptOrphans(at: noon)

    harness.coordinator.answer(.keep, at: noon)
    #expect(isFailure(harness.shown.last))

    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    #expect(isFailure(harness.shown.last))

    harness.coordinator.poll(now: noon.addingTimeInterval(MeetingMachine.noticeDwell + 1))
    guard case .orphanFound = harness.shown.last else {
        Issue.record("expected the second draft to be offered, got \(harness.shown)")
        return
    }
}

private func isFailure(_ state: MeetingPanelState?) -> Bool {
    if case .failure = state { return true }
    return false
}

// MARK: - The folder of a live meeting

@Test @MainActor func startingARecordingCreatesADraftThatAlreadyKnowsWhenItBegan() async throws {
    let harness = try Harness()
    harness.processes = [telemost]

    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    #expect(harness.drafts.count == 1)
    #expect(harness.drafts[0].hasSuffix("-telemost"))
    let metadata = try harness.metadata(of: harness.drafts[0])
    #expect(metadata.startedAt == noon)
    #expect(metadata.stoppedAt == nil)
    #expect(harness.captures.count == 1)
    #expect(harness.captures[0].started)
    #expect(harness.blocked == [true])
}

// Decision of this task, and the one the leading dot exists for: the rename is the hand-off to
// phase 2б, so it may not happen until the capture has closed its files and the metadata has
// been written. A sleep would only have made the race rarer.
@Test @MainActor func theFolderIsHandedOverOnlyAfterTheCaptureFinishedClosingIt() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.startPressed(at: noon)

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2820))
    await harness.coordinator.settle()

    #expect(harness.captures[0].stopped)
    // Everything the queue held while the capture was still closing was still a draft.
    #expect(harness.captures[0].queueWhenStopped.allSatisfy { $0.hasPrefix(".draft-") })
    #expect(harness.handedOver.count == 1)
    // The offsets exist only in the outcome `stop` returns, so a folder carrying them proves the
    // metadata was rewritten before the rename rather than after it.
    let metadata = try harness.metadata(of: harness.handedOver[0])
    #expect(metadata.systemStartedAt == 0.25)
    #expect(metadata.microphoneStartedAt == 0.5)
    #expect(metadata.stoppedAt == noon.addingTimeInterval(2820))
}

// The rename is the only hand-off point into 2б. Without this call, a recording only reaches the
// archive on the next app launch, and nothing about a live meeting would show that — the file
// does show up, just a day later.
@Test @MainActor func stoppingARecordingHandsTheFolderToTheQueue() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.startPressed(at: noon)

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2820))
    await harness.coordinator.settle()

    #expect(harness.handedToQueue.count == 1)
    // The final name is handed over, not the draft: the queue must never see a folder still being written to.
    #expect(harness.handedToQueue[0].lastPathComponent.hasPrefix(".draft-") == false)
    #expect(harness.handedToQueue[0].lastPathComponent == harness.handedOver[0])
}

@Test @MainActor func refusingAMeetingRemovesItsDraft() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    #expect(harness.shown == [.startPrompt(appName: "Телемост")])

    harness.coordinator.answer(.decline, at: noon.addingTimeInterval(4))
    await harness.coordinator.settle()

    #expect(harness.entries.isEmpty)
    #expect(harness.blocked == [true, false])
}

@Test @MainActor func theMetadataOfAFinishedMeetingCarriesWhatPhaseTwoBNeeds() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(5))

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    await harness.coordinator.settle()

    let metadata = try harness.metadata(of: harness.handedOver[0])
    #expect(metadata.startedAt == noon)
    #expect(metadata.stoppedAt == noon.addingTimeInterval(600))
    #expect(metadata.app == MeetingMetadata.App(
        bundleID: "ru.yandex.desktop.telemost", name: "Телемост", slug: "telemost"
    ))
    #expect(metadata.sampleRate == MeetingAudioRecorder.sampleRate)
    #expect(metadata.channelCount == Int(MeetingAudioRecorder.channelCount))
    #expect(metadata.stopReason == .manual)
    #expect(metadata.excludedApps == ["com.spotify.client"])
    #expect(metadata.gaps.isEmpty)
    #expect(metadata.systemStartedAt == 0.25)
}

// The list cuts applications out of the audio mix, so a bundle identifier added to it "just in
// case" would produce a valid recording full of silence. It goes to the capture exactly as the
// owner wrote it.
@Test @MainActor func theExclusionListReachesTheCaptureExactlyAsWritten() async throws {
    let harness = try Harness()
    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    #expect(harness.captures[0].excluded == ["com.spotify.client"])
}

// Closing a real capture takes as long as it takes, and the main actor is free for all of it.
// The machine is already at rest by then — after a limit, an auto-stop or a manual stop — while
// the meeting application usually still holds the devices, so the very next tick starts the next
// meeting. Anything the closing half reads out of the coordinator after that suspension belongs
// to the wrong meeting: the finished file would get the new meeting's start time, and the new
// meeting would lose its own.
@Test @MainActor func aMeetingStartingWhileTheLastOneIsStillClosingDoesNotStealItsMetadata() async throws {
    let harness = try Harness()
    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    // Let the closing task reach its suspension inside `capture.stop()` before the next meeting
    // begins — the window this test is about.
    for _ in 0..<4 { await Task.yield() }
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon.addingTimeInterval(601))
    await harness.coordinator.settle()

    let finished = try harness.metadata(of: harness.handedOver[0])
    #expect(finished.startedAt == noon)
    #expect(finished.stoppedAt == noon.addingTimeInterval(600))
    #expect(finished.stopReason == .manual)
    let running = try harness.metadata(of: harness.drafts[0])
    #expect(running.startedAt == noon.addingTimeInterval(601))
    #expect(running.stoppedAt == nil)
}

// MARK: - The microphone the meeting is being recorded through

// Spec §10: a Bluetooth microphone drops the whole device into narrowband, and the meeting is
// recorded anyway — a narrow band is worse than a full one and better than nothing. Naming it is
// the entire remedy, and it is the same warning dictation has shown since phase 1. The value was
// already going into `meeting.json`; what was missing was saying it to the owner, who is the
// only one who can swap the microphone while it still matters.
@Test @MainActor func aNarrowbandMicrophoneIsNamedWhenTheMeetingStarts() async throws {
    let harness = try Harness()
    harness.inputDevice = AudioInputDevice(name: "AirPods", uid: "test-airpods", sampleRate: 16000, channelCount: 1)
    harness.processes = [telemost]

    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    #expect(harness.narrowband == [16000])
    #expect(try harness.metadata(of: harness.drafts[0]).inputDevice?.isNarrowband == true)
}

@Test @MainActor func aFullBandMicrophoneIsNothingToWarnAbout() async throws {
    let harness = try Harness()
    harness.inputDevice = AudioInputDevice(name: "USB", uid: "test-usb", sampleRate: 48000, channelCount: 1)
    harness.processes = [telemost]

    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    #expect(harness.narrowband == [nil])
}

// Once, at the start, exactly as dictation reports it — not once a second for an hour.
@Test @MainActor func theWarningIsSaidAtTheStartAndNotRepeated() async throws {
    let harness = try Harness()
    harness.inputDevice = AudioInputDevice(name: "AirPods", uid: "test-airpods", sampleRate: 16000, channelCount: 1)
    harness.processes = [telemost]

    harness.coordinator.poll(now: noon)
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.narrowband == [16000])
}

// MARK: - A microphone track that is exactly zero

// Приложение знало о немой дорожке на первой секунде и молчало полтора часа — ровно то, что
// стоило владельцу его собственного голоса на встрече 7 сентября.
@Test @MainActor func aSilentMicrophoneIsNamedWhileTheMeetingIsStillRecording() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [])

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true])
}

@Test @MainActor func aMicrophoneThatStartsSpeakingClearsTheWarning() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 0
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true, false])
}

// Девять секунд — это не немота, а пауза между буферами плюс запас.
@Test @MainActor func aShortGapIsNotCalledSilence() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 9
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [])
}

// The direct analogue of `theWarningIsSaidAtTheStartAndNotRepeated` above: this is the property
// that keeps the panel from rewriting itself once a second for the length of the recording.
@Test @MainActor func theMicrophoneWarningIsNotRepeatedWhileItStaysSilent() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    await harness.coordinator.settle()
    harness.coordinator.poll(now: noon.addingTimeInterval(3))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true])
}

// Cancelling `microphoneCheck` in `stopCapture` is cooperative — the task's own `await` still
// resolves once the fake finally answers, well after the meeting it was asked about is over.
// That stale answer must not be acted on, and must not stand in for whatever the next meeting's
// own check is doing with the coordinator's single `microphoneCheck` slot.
@Test @MainActor func aStaleMicrophoneAnswerAfterTheMeetingEndedIsDiscarded() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    harness.captures[0].suspendMicrophoneCheck = true
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    // `settle()` cannot be used here — it would wait forever for a check that is deliberately
    // not answering yet. Yielding instead lets the check reach its suspension inside the fake,
    // the same pattern `FakeCapture.stop()` uses to let a race run first.
    for _ in 0..<8 { await Task.yield() }

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(3))
    await harness.coordinator.settle()
    // The withdrawal `stopCapture` itself fires when the meeting ends — one entry, before the
    // stale check has answered anything at all.
    #expect(harness.microphoneSilent == [false])

    harness.captures[0].silentSeconds = 10
    harness.captures[0].resumeMicrophoneCheck()
    for _ in 0..<8 { await Task.yield() }
    // The stale answer, about a meeting that is already over, added nothing.
    #expect(harness.microphoneSilent == [false])

    // The next meeting's own check still works — proof the stale completion did not clobber
    // `microphoneCheck` or leave the guard against a second check in flight stuck.
    harness.processes = [telemostIdle]
    harness.coordinator.poll(now: noon.addingTimeInterval(4))
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon.addingTimeInterval(5))
    await harness.coordinator.settle()

    harness.captures[1].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(6))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [false, true])
}

// MARK: - Rebinding a microphone that appeared mid-meeting

private let airpods = AudioInputDevice(
    name: "AirPods", uid: "F0-D3:input", sampleRate: 24000, channelCount: 1
)

// ScreenCaptureKit привязывает микрофон один раз, на старте потока: устройство, подключённое
// посреди встречи, он сам не подхватывает — измерено, проба 3 из спеки.
@Test @MainActor func aDeviceThatAppearsMidMeetingIsBoundExplicitly() async throws {
    let harness = try Harness()
    harness.inputDevice = nil
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.inputDevice = airpods
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()

    #expect(harness.captures[0].rebinds == ["F0-D3:input"])
}

// Немая дорожка без устройства — перепривязывать не на что.
@Test @MainActor func silenceWithNoDeviceDoesNotRebind() async throws {
    let harness = try Harness()
    harness.inputDevice = nil
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()

    #expect(harness.captures[0].rebinds.isEmpty)
}

// Устройство может молчать по своей причине — выключенный в железе микрофон, эксклюзивно
// занятое приложение. Тогда попытки не помогают, а updateConfiguration дёргает поток, которым
// пишется единственная уцелевшая дорожка собеседников.
@Test @MainActor func rebindingGivesUpAfterThreeAttempts() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    for attempt in 1...8 {
        harness.captures[0].silentSeconds = 10
        harness.coordinator.poll(now: noon.addingTimeInterval(TimeInterval(attempt) * 11))
        await harness.coordinator.settle()
    }

    #expect(harness.captures[0].rebinds.count == 3)
}

// Опрос идёт раз в секунду, но перепривязка — нет: новой привязке нужно время, чтобы отдать
// первый буфер, иначе тишина последней секунды прочтётся как отказ и вызовет вторую попытку.
@Test @MainActor func rebindingWaitsBetweenAttempts() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    for second in 1...5 {
        harness.captures[0].silentSeconds = 10
        harness.coordinator.poll(now: noon.addingTimeInterval(TimeInterval(second)))
        await harness.coordinator.settle()
    }

    #expect(harness.captures[0].rebinds.count == 1)
}

// Перепривязка обнуляет счётчик тишины, и это верно для счётчика: он про новую привязку. Но для
// надписи это ложное «всё в порядке» — следующий опрос читает ноль независимо от того, пошёл ли
// звук. Красная строка гасла, через десять секунд возвращалась, и так до трёх раз, при том что
// звука не было и не будет. Счётчик снова что-то значит только после полной выдержки: к этому
// моменту его либо обнулил настоящий звук, либо он перевалил порог обратно.
@Test @MainActor func aRebindDoesNotWithdrawTheWarningWhileItsCooldownRuns() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [true])
    #expect(harness.captures[0].rebinds.count == 1)

    // The fake resets its own counter inside the rebind, exactly as the real writer does. This
    // poll therefore reads a fresh zero — which is not evidence of anything.
    harness.coordinator.poll(now: noon.addingTimeInterval(12))
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [true])

    // Ten seconds on, still nothing: the counter has climbed back past the threshold, and the
    // warning was never taken down and put back up in between.
    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(22))
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [true])
}

// The other side of the same rule: once the cooldown is out, a counter reading zero really is
// audio arriving, and the warning goes away.
@Test @MainActor func aRebindThatWorkedClearsTheWarningOnceTheCooldownIsOut() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].silentSeconds = 10
    harness.coordinator.poll(now: noon.addingTimeInterval(11))
    await harness.coordinator.settle()
    #expect(harness.microphoneSilent == [true])

    harness.coordinator.poll(now: noon.addingTimeInterval(21))
    await harness.coordinator.settle()

    #expect(harness.microphoneSilent == [true, false])
}

// `rebindMicrophone` really suspends — the real one awaits `stream.updateConfiguration` — so the
// cancellation guard at the top of `checkMicrophone`'s task no longer covers everything after it:
// a rebind still in flight when `stopCapture` cancels this task resumes later, after the next
// meeting has already installed its own check. Without a second guard right before the
// unconditional `microphoneCheck = nil`, that resumption erases the next meeting's handle, the
// one-at-a-time guard in `checkMicrophone` stops holding, and a poll that lands in the gap starts
// a second, concurrent check for the same live meeting.
@Test @MainActor func aRebindStillInFlightWhenTheMeetingEndsDoesNotEraseTheNextMeetingsCheck() async throws {
    let harness = try Harness()
    harness.inputDevice = airpods
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    // Confirmed the way `aStaleMicrophoneAnswerAfterTheMeetingEndedIsDiscarded` confirms it:
    // `stopPressed` below needs a recording it is answering *for*, not a still-unconfirmed draft.
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(0.5))
    await harness.coordinator.settle()

    // Meeting A's check reaches the rebind and sits there, suspended, the way a real
    // `updateConfiguration` call would while `stopCapture` below runs.
    harness.captures[0].silentSeconds = 10
    harness.captures[0].suspendRebind = true
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    for _ in 0..<8 { await Task.yield() }

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    // Meeting B starts and its own poll schedules its own check — but that check has not run a
    // single line yet, so suspending it here still takes effect before it ever answers.
    harness.processes = [telemostIdle]
    harness.coordinator.poll(now: noon.addingTimeInterval(3))
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon.addingTimeInterval(4))
    harness.captures[1].suspendMicrophoneCheck = true

    // Release meeting A's stale rebind. With the guard in place it finds itself cancelled and
    // returns without touching `microphoneCheck`; without it, it would nil out meeting B's live
    // handle while meeting B's own check is still sitting mid-flight, suspended above.
    harness.captures[0].resumeRebind()
    for _ in 0..<8 { await Task.yield() }

    // A poll that lands in this gap must see meeting B's check still installed and decline to
    // start a second one — the direct measurement of the one-at-a-time guard still holding.
    harness.coordinator.poll(now: noon.addingTimeInterval(5))
    for _ in 0..<8 { await Task.yield() }

    #expect(harness.captures[1].microphoneSilentSecondsCallCount == 1)

    // Meeting B's own check still resolves normally once released — proof this is about the
    // stale rebind's aftermath, not about meeting B's check being broken outright.
    harness.captures[1].silentSeconds = 10
    harness.captures[1].resumeMicrophoneCheck()
    await harness.coordinator.settle()

    #expect(harness.captures[1].rebinds == ["F0-D3:input"])
}

// MARK: - A dictation already under way

// Spec §6: a meeting starting while a dictation is in flight waits for it — the draft begins a
// second later instead of cutting the owner off mid-sentence. Not politeness: without it an
// `SCStream` configured with `captureMicrophone` and the dictation's `AVAudioEngine` would hold
// the same input in the same process at the same time, which is the one thing §7 blocks
// dictation during meetings to avoid.
@Test @MainActor func aMeetingDoesNotStartWhileADictationIsStillInFlight() async throws {
    let harness = try Harness()
    harness.dictating = true
    harness.processes = [telemost]

    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    #expect(harness.captures.isEmpty)
    #expect(harness.entries.isEmpty)
    #expect(harness.shown.isEmpty)
    #expect(harness.blocked.isEmpty)
}

// "Ждать секунды", exactly as the spec puts it: the poll that follows the dictation notices the
// same meeting and starts the draft.
@Test @MainActor func theMeetingStartsOnTheFirstPollAfterTheDictationEnds() async throws {
    let harness = try Harness()
    harness.dictating = true
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)

    harness.dictating = false
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    await harness.coordinator.settle()

    #expect(harness.drafts.count == 1)
    #expect(harness.shown == [.startPrompt(appName: "Телемост")])
    // The second poll is where this meeting began, not the first: the draft that waited carries
    // the later timestamp, and phase 2б places words against it.
    #expect(try harness.metadata(of: harness.drafts[0]).startedAt == noon.addingTimeInterval(1))
}

// The source going quiet is about the devices, not about time: a prompt that stopped counting
// down while somebody dictated would stand until they happened to stop.
@Test @MainActor func timeKeepsPassingWhileTheSourceIsQuiet() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)
    harness.dictating = true

    harness.coordinator.poll(now: noon.addingTimeInterval(config.autoStopSeconds))

    #expect(harness.handedOver.count == 1)
}

// MARK: - Stopping by hand, and then the very next poll

// The poll repeats itself every second for as long as the application holds the devices, and a
// meeting is stopped in the middle of one: the conferencing window is still open, still playing.
// Nothing but the machine's memory of that process stands between "stop" and a second draft one
// second later — which would collapse its prompt after thirty seconds and record to the end of
// the meeting. The stop button would not stop anything.
@Test @MainActor func stoppingByHandSurvivesTheNextPollASecondLater() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(5))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    await harness.coordinator.settle()

    harness.coordinator.poll(now: noon.addingTimeInterval(601))
    await harness.coordinator.settle()

    #expect(harness.captures.count == 1)
    #expect(harness.drafts.isEmpty)
    #expect(harness.handedOver.count == 1)
}

// "Delete" is the other explicit no, and the recording it deletes is unconfirmed: a draft that
// starts again a second later is saved by silence, so the deleted meeting would be in the
// archive within two minutes of being deleted.
@Test @MainActor func aDeletedRecordingDoesNotComeBackOnTheNextPoll() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    harness.coordinator.answer(.delete, at: noon.addingTimeInterval(605))
    await harness.coordinator.settle()

    harness.coordinator.poll(now: noon.addingTimeInterval(606))
    harness.coordinator.poll(now: noon.addingTimeInterval(607))
    await harness.coordinator.settle()

    #expect(harness.captures.count == 1)
    #expect(harness.entries.isEmpty)
}

// The length limit exists so a forgotten recording cannot eat the disk. Coming to rest when it
// fires defeats it entirely: the meeting is still going, the application is still holding both
// devices, and the very next poll starts the next four hours. At 230 MB an hour that is nearly a
// gigabyte per piece, and the limit would only be chopping the recording up.
@Test @MainActor func theLengthLimitDoesNotStartTheNextFourHoursASecondLater() async throws {
    let harness = try Harness(config: MeetingsConfig(
        triggerApps: config.triggerApps,
        excludedApps: config.excludedApps,
        silenceSeconds: config.silenceSeconds,
        autoStopSeconds: config.autoStopSeconds,
        startPromptSeconds: config.startPromptSeconds,
        maxMeetingSeconds: 600,
        phraseGapSeconds: config.phraseGapSeconds,
        maxPhraseSeconds: config.maxPhraseSeconds,
        micThresholdDBFS: config.micThresholdDBFS,
        audioRetentionDays: config.audioRetentionDays,
        aacBitrate: config.aacBitrate
    ))
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(5))

    harness.coordinator.poll(now: noon.addingTimeInterval(600))
    await harness.coordinator.settle()
    #expect(harness.shown.last == .limitReached)

    harness.coordinator.poll(now: noon.addingTimeInterval(601))
    await harness.coordinator.settle()

    #expect(harness.captures.count == 1)
    #expect(harness.drafts.isEmpty)
    #expect(harness.handedOver.count == 1)
}

// Remembered until the devices are free, and not one second longer: the next meeting in the same
// application is a different meeting and has to be noticed.
@Test @MainActor func theNextMeetingAfterAManualStopIsStillNoticed() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(5))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    await harness.coordinator.settle()

    harness.processes = [telemostIdle]
    harness.coordinator.poll(now: noon.addingTimeInterval(601))
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon.addingTimeInterval(602))
    await harness.coordinator.settle()

    #expect(harness.captures.count == 2)
    #expect(harness.drafts.count == 1)
}

// MARK: - An application that quits while a prompt is up

private let twoTriggers = MeetingsConfig(
    triggerApps: [
        MeetingsConfig.TriggerApp(bundleID: "ru.yandex.desktop.telemost", slug: "telemost"),
        MeetingsConfig.TriggerApp(bundleID: "us.zoom.xos", slug: "zoom"),
    ],
    excludedApps: [],
    silenceSeconds: 60,
    autoStopSeconds: 120,
    startPromptSeconds: 30,
    maxMeetingSeconds: 14400,
    phraseGapSeconds: 1.0,
    maxPhraseSeconds: 40,
    micThresholdDBFS: -30,
    audioRetentionDays: 7,
    aacBitrate: 32000
)

private let zoom = AudioProcessMonitor.State(
    pid: 777, bundleID: "us.zoom.xos", name: "Zoom", isRunningInput: true, isRunningOutput: true
)

// The whole ordinary sequence, through the poll that makes it dangerous: the meeting ends, the
// devices go free, a minute of silence raises the stop prompt while the application is still
// running, and only then does the owner close it. The coordinator notices the exit exactly once —
// the pid leaves `knownPIDs` and never comes back — so an answer that remembered the process
// afterwards would leave a refusal nothing can lift. Detection would be dead until a restart, and
// dead for Zoom too: there is one refusal cell for all applications.
@Test @MainActor func aMeetingClosedWhileItsStopPromptWasUpDoesNotKillDetection() async throws {
    let harness = try Harness(config: twoTriggers)
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(5))

    // Everyone leaves: the devices go free, and a minute later the prompt comes up.
    harness.processes = [telemostIdle]
    harness.coordinator.poll(now: noon.addingTimeInterval(600))
    harness.coordinator.poll(now: noon.addingTimeInterval(661))
    #expect(harness.shown.last == .stopPrompt(duration: 661))

    // Now the window is closed. This is the one and only exit report for this pid.
    harness.processes = []
    harness.coordinator.poll(now: noon.addingTimeInterval(700))
    harness.coordinator.answer(.delete, at: noon.addingTimeInterval(710))
    await harness.coordinator.settle()
    #expect(harness.entries.isEmpty)

    // Detection has to be alive — for this application and for every other one.
    harness.processes = [zoom]
    harness.coordinator.poll(now: noon.addingTimeInterval(720))
    await harness.coordinator.settle()

    #expect(harness.drafts.count == 1)
    #expect(harness.drafts[0].hasSuffix("-zoom"))
}

// MARK: - The two capture failures are not the same failure

// Nothing was recorded, so there is nothing to protect: the draft goes.
@Test @MainActor func aCaptureThatNeverStartedTakesItsDraftWithIt() async throws {
    let harness = try Harness()
    harness.startError = MeetingCaptureError.permissionDenied
    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    #expect(harness.entries.isEmpty)
    #expect(harness.shown.contains { state in
        if case .failure(let message) = state { return message.contains("Screen") }
        return false
    })
    #expect(harness.blocked == [true, false])
}

// The one failure that happens *inside* the loop performing the effects of another event: the
// folder cannot be created, so `.startCapture` throws before the two effects behind it have run.
// Feeding that failure straight back into the machine let those two be performed on top of the
// recovery it had just finished — dictation was unblocked and then blocked again with nothing
// left to unblock it, and the start prompt went back up over a machine that no longer answers
// it, holding the panel open over the Dock until the application was restarted.
@Test @MainActor func aFolderThatCannotBeCreatedLeavesNoBlockedDictationAndNoPrompt() async throws {
    let harness = try Harness(queueIsAFile: true)
    harness.processes = [telemost]

    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    #expect(harness.blocked.last == false)
    #expect(isFailure(harness.shown.last))
    // A prompt the machine ignores is worse than no prompt: it takes the mouse and never leaves.
    #expect(harness.shown.last?.acceptsClicks == false)
    #expect(harness.hidden.last == MeetingMachine.noticeDwell)
    #expect(harness.coordinator.activity == .ready)
    #expect(harness.coordinator.canBeRebuilt)
}

// What the capture only discovers at the end — a track that received nothing at all — is named
// as well, and the folder is kept. Renamed from a title that promised the stream dying
// mid-meeting: that path arrives through the handler below, not through the stop.
@Test @MainActor func aFailureFoundOnlyWhenTheCaptureClosedIsNamedAndTheFolderKept() async throws {
    let harness = try Harness()
    harness.captureFailure = "no audio arrived on the system track"
    harness.coordinator.startPressed(at: noon)

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2400))
    await harness.coordinator.settle()

    #expect(harness.handedOver.count == 1)
    #expect(harness.shown.contains(.failure("no audio arrived on the system track")))
}

// Английская строка про формат буфера была последним, что владелец узнал о потере своей
// дорожки. Панель говорит по-русски и говорит, что именно потеряно.
@Test @MainActor func aRecordingWhoseMicrophoneStayedSilentSaysSoWhenItIsKept() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentAtStop = 600
    harness.captures[0].sawAudioAtStop = false

    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(1))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.shown.contains { state in
        if case .failure(let text) = state {
            return text.contains("Микрофон молчал всю запись — ваша дорожка пустая")
        }
        return false
    })
}

// `silentSeconds` по построению меряет непрерывный ноль **в конце** дорожки: любой ненулевой
// сэмпл обнуляет счётчик. Выдавать его за всю запись — ложь в самом обычном случае. Порог
// тишины ноль, автостоп две минуты: подсказка остановки поднимается в момент конца встречи, а
// запись идёт ещё две минуты, и AirPods, убранные в кейс, дают ровно цифровой ноль. Десяти
// секунд такого хватало, чтобы объявить пустой полностью записанную часовую дорожку.
@Test @MainActor func aTrackThatSpokeAndThenWentQuietIsCalledIncompleteNotEmpty() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentAtStop = 600
    harness.captures[0].sawAudioAtStop = true

    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(1))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    let said = harness.shown.compactMap { state -> String? in
        if case .failure(let text) = state { return text }
        return nil
    }
    #expect(said.contains { $0.contains("Микрофон замолчал в конце") && $0.contains("10 мин") })
    #expect(!said.contains { $0.contains("пустая") })
}

// The gate is ten seconds, but `ElapsedTime.minutes` rounds anything under thirty down to
// zero — a fifteen-second dropout clears the gate and still rounds to "0 мин" if nothing
// corrects for it. That sentence would claim no silence and an empty track in the same
// breath, for a dropout ordinary enough that the review this fixed was asked to check it.
@Test @MainActor func aBriefMicrophoneDropoutIsNeverReportedAsZeroMinutes() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()
    harness.captures[0].silentAtStop = 15
    harness.captures[0].sawAudioAtStop = true

    harness.coordinator.answer(.confirm, at: noon.addingTimeInterval(1))
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.shown.contains { state in
        if case .failure(let text) = state {
            return text.contains("Микрофон замолчал в конце") && text.contains("меньше минуты")
        }
        return false
    })
    #expect(!harness.shown.contains { state in
        if case .failure(let text) = state { return text.contains("0 мин") }
        return false
    })
}

// A failure shown while the save prompt is up would replace it, and the owner would be left with
// a draft they can no longer answer for — the panel takes one state at a time. The reason waits
// until the answer decides what the folder is for.
@Test @MainActor func aFailedCaptureDoesNotEatTheSavePromptItWouldHaveReplaced() async throws {
    let harness = try Harness()
    harness.captureFailure = "no audio arrived on the microphone track"
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    for _ in 0..<8 { await Task.yield() }

    #expect(harness.shown.last == .savePrompt(duration: 600))

    harness.coordinator.answer(.keep, at: noon.addingTimeInterval(605))
    await harness.coordinator.settle()

    #expect(harness.handedOver.count == 1)
    #expect(harness.shown.last == .failure("no audio arrived on the microphone track"))
}

// The owner pressed "no". Telling them the capture had trouble with a folder that no longer
// exists answers a question nobody asked, and does it with a five-second failure panel.
@Test @MainActor func refusingAMeetingDoesNotComplainAboutTheCaptureAfterwards() async throws {
    let harness = try Harness()
    harness.captureFailure = "no audio arrived on the system track"
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)

    harness.coordinator.answer(.decline, at: noon.addingTimeInterval(4))
    await harness.coordinator.settle()

    #expect(harness.entries.isEmpty)
    #expect(!harness.shown.contains { if case .failure = $0 { return true } else { return false } })
}

// MARK: - A stream that dies while the meeting is still going

/// Lets the hop from the capture's queue to the main actor land. The handler is called from
/// outside the actor, so what it starts is a task of its own, and `settle` cannot wait for a
/// task that has not been created yet.
@MainActor
private func drainMainActor() async {
    for _ in 0..<8 { await Task.yield() }
}

// Spec §10: a stream that died mid-meeting stops the recording and keeps the folder as it is,
// with the reason named. Without this path the recording would go on believing in itself until
// the owner pressed stop — an hour of silence noticed only in the archive.
@Test @MainActor func aStreamDyingMidMeetingKeepsTheFolderAndNamesTheReason() async throws {
    let harness = try Harness()
    // The real recorder remembers the death and reports it again when the capture is closed, so
    // a fake that forgot it would make this an easier meeting than production ever gets.
    harness.captureFailure = "the capture stopped: display disconnected"
    harness.coordinator.startPressed(at: noon)
    await harness.coordinator.settle()

    harness.captures[0].die("the capture stopped: display disconnected")
    await drainMainActor()
    await harness.coordinator.settle()

    #expect(harness.drafts.isEmpty)
    #expect(harness.captures[0].stopped)
    // Kept, not discarded: this is the whole difference from a capture that never started.
    let kept = try #require(harness.handedOver.first)
    #expect(harness.handedOver.count == 1)
    #expect(try harness.metadata(of: kept).stopReason == .failure)
    // Both channels say the same sentence — the machine when the death is reported, the hand-off
    // when the closed capture repeats it — so whichever lands last, the panel names the reason.
    #expect(harness.shown.last == .failure("the capture stopped: display disconnected"))
    #expect(harness.blocked == [true, false])
}

// Whatever killed this capture — a full disk above all — will kill the next one on its first
// buffer, and the meeting application is still holding both devices. Starting over on the next
// poll would mean a new folder, a new failure and a new empty recording promoted into the queue
// every few seconds, for as long as the meeting lasts.
@Test @MainActor func aCaptureThatDiedDoesNotStartTheSameMeetingOverASecondLater() async throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    await harness.coordinator.settle()

    harness.captures[0].die("cannot write system.wav: no space left on device")
    await drainMainActor()
    await harness.coordinator.settle()

    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    harness.coordinator.poll(now: noon.addingTimeInterval(2))
    await harness.coordinator.settle()

    #expect(harness.captures.count == 1)
    #expect(harness.handedOver.count == 1)
    #expect(harness.drafts.isEmpty)
}

// The meeting is over and its folder has been handed on. A straggler must not raise a panel
// about a recording nobody is making, and must not rewrite what was already filed.
@Test @MainActor func aStreamFailureArrivingAfterTheMeetingEndedChangesNothing() async throws {
    let harness = try Harness()
    harness.coordinator.startPressed(at: noon)
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    await harness.coordinator.settle()
    let shownBefore = harness.shown

    harness.captures[0].die("the capture stopped: display disconnected")
    await drainMainActor()
    await harness.coordinator.settle()

    #expect(harness.shown == shownBefore)
    #expect(harness.handedOver.count == 1)
    #expect(try harness.metadata(of: try #require(harness.handedOver.first)).stopReason == .manual)
}

// The dangerous straggler: the message crosses to the main actor asynchronously, and by then the
// next meeting may already be recording. Acting on it there would stop a healthy capture and file
// a live meeting as failed — the same hazard the closing task documents about metadata.
@Test @MainActor func aStreamThatDiedInTheLastMeetingDoesNotStopTheNextOne() async throws {
    let harness = try Harness()
    harness.coordinator.startPressed(at: noon)
    harness.coordinator.stopPressed(at: noon.addingTimeInterval(600))
    await harness.coordinator.settle()
    harness.coordinator.startPressed(at: noon.addingTimeInterval(601))
    await harness.coordinator.settle()

    harness.captures[0].die("the capture stopped: display disconnected")
    await drainMainActor()
    await harness.coordinator.settle()

    #expect(harness.captures.count == 2)
    #expect(!harness.captures[1].stopped)
    #expect(harness.drafts.count == 1)
    #expect(!harness.shown.contains { if case .failure = $0 { return true } else { return false } })
}

// MARK: - A monitor that answers, a monitor that fails

// `nil` is a failed system call, not an empty room. Read as "nobody is holding a device" it
// would look exactly like the meeting application having quit.
@Test @MainActor func aFailedReadOfTheAudioProcessesIsNotTheMeetingEnding() throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)

    harness.processes = nil
    harness.coordinator.poll(now: noon.addingTimeInterval(1))
    harness.coordinator.poll(now: noon.addingTimeInterval(2))

    #expect(harness.shown == [.startPrompt(appName: "Телемост")])
}

@Test @MainActor func anEmptyProcessListIsTheMeetingApplicationHavingGone() throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)

    harness.processes = []
    harness.coordinator.poll(now: noon.addingTimeInterval(1))

    #expect(harness.shown.contains { state in
        if case .stopPrompt = state { return true }
        return false
    })
}

// A single refusal is survivable and says nothing worth interrupting for; a monitor that has
// refused for ten seconds running will never notice a meeting again, and that has to be said —
// once, not every second.
@Test @MainActor func aMonitorThatKeepsFailingIsNamedOnceRatherThanEverySecond() throws {
    let harness = try Harness()
    harness.processes = nil

    for step in 0..<(MeetingCoordinator.monitorFailureLimit - 1) {
        harness.coordinator.poll(now: noon.addingTimeInterval(Double(step)))
    }
    #expect(harness.shown.isEmpty)

    for step in 0..<10 {
        harness.coordinator.poll(now: noon.addingTimeInterval(Double(
            MeetingCoordinator.monitorFailureLimit + step
        )))
    }
    #expect(harness.shown.count == 1)
    guard case .failure = harness.shown.first else {
        Issue.record("expected a named failure, got \(harness.shown)")
        return
    }
}

@Test @MainActor func aMonitorThatComesBackIsAllowedToFailAgainLater() throws {
    let harness = try Harness()
    harness.processes = nil
    for step in 0..<MeetingCoordinator.monitorFailureLimit {
        harness.coordinator.poll(now: noon.addingTimeInterval(Double(step)))
    }
    #expect(harness.shown.count == 1)

    harness.processes = []
    harness.coordinator.poll(now: noon.addingTimeInterval(100))
    harness.processes = nil
    for step in 0..<MeetingCoordinator.monitorFailureLimit {
        harness.coordinator.poll(now: noon.addingTimeInterval(200 + Double(step)))
    }

    #expect(harness.shown.count == 2)
}

// MARK: - When this coordinator may be thrown away and built again

// Rebuilding means a new object with an empty memory, and a refusal lives in that memory. The
// meeting application is still holding the devices, so the very next poll would start recording
// the meeting the owner has just refused — and then silence would save it. Reading the menu's
// own question here, where a refusal counts as "ready", is exactly the defect this test pins.
@Test @MainActor func aRefusedMeetingIsNotSomethingToRebuildAround() throws {
    let harness = try Harness()
    harness.processes = [telemost]
    harness.coordinator.poll(now: noon)
    harness.coordinator.answer(.decline, at: noon.addingTimeInterval(4))

    #expect(harness.coordinator.activity == .ready)
    #expect(!harness.coordinator.canBeRebuilt)
}

// An orphan prompt lives in the coordinator rather than in the machine, so a machine at rest is
// not enough of an answer: rebuilding while one is up throws away the question the owner is
// looking at.
@Test @MainActor func anOrphanPromptOnScreenIsNotSomethingToRebuildAround() throws {
    let harness = try Harness()
    _ = try orphanDraft(in: harness.queue)
    harness.coordinator.adoptOrphans(at: noon)

    #expect(harness.coordinator.activity == .ready)
    #expect(!harness.coordinator.canBeRebuilt)
}

@Test @MainActor func anIdleCoordinatorWithNothingPendingMayBeRebuilt() throws {
    let harness = try Harness()
    harness.coordinator.adoptOrphans(at: noon)

    #expect(harness.coordinator.canBeRebuilt)
}
