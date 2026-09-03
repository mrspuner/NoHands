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
    triggerApps: [MeetingsConfig.TriggerApp(bundleID: "ru.yandex.telemost", slug: "telemost")],
    excludedApps: ["com.spotify.client"],
    silenceSeconds: 60,
    autoStopSeconds: 120,
    startPromptSeconds: 30,
    maxMeetingSeconds: 14400
)

private let telemost = AudioProcessMonitor.State(
    pid: 4242,
    bundleID: "ru.yandex.telemost",
    name: "Телемост",
    isRunningInput: true,
    isRunningOutput: true
)

/// The same process holding nothing: what letting go of both devices looks like to the watcher.
private let telemostIdle = AudioProcessMonitor.State(
    pid: 4242,
    bundleID: "ru.yandex.telemost",
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

    init(folder: URL, excluded: [String]) {
        self.folder = folder
        self.excluded = excluded
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
            failure: failure
        )
    }
}

@MainActor
private final class Harness {
    let queue: URL
    private(set) var shown: [MeetingPanelState] = []
    private(set) var hidden: [TimeInterval] = []
    private(set) var blocked: [Bool] = []
    private(set) var captures: [FakeCapture] = []
    /// What the next `poll` reads. `nil` is a failed system call, `[]` is nobody holding a
    /// device — the distinction several tests below exist for.
    var processes: [AudioProcessMonitor.State]? = []
    var startError: Error?
    var stopError: Error?
    var captureFailure: String?
    var coordinator: MeetingCoordinator!

    init(config: MeetingsConfig = config) throws {
        queue = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        coordinator = MeetingCoordinator(
            config: config,
            queue: queue,
            showPanel: { [weak self] in self?.shown.append($0) },
            hidePanel: { [weak self] in self?.hidden.append($0) },
            onDictationBlocked: { [weak self] in self?.blocked.append($0) },
            readProcesses: { [weak self] in
                guard let self else { return [] }
                return processes
            },
            makeCapture: { [weak self] folder, excluded in
                let capture = FakeCapture(folder: folder, excluded: excluded)
                capture.startError = self?.startError
                capture.stopError = self?.stopError
                capture.failure = self?.captureFailure
                self?.captures.append(capture)
                return capture
            }
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
        app: MeetingMetadata.App(bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost"),
        sampleRate: 16000,
        channelCount: 1,
        inputDevice: nil,
        stopReason: nil,
        excludedApps: [],
        gaps: [],
        systemStartedAt: nil,
        microphoneStartedAt: nil
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

    harness.coordinator.poll(now: noon.addingTimeInterval(MeetingMachine.failureDwell + 1))
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
        bundleID: "ru.yandex.telemost", name: "Телемост", slug: "telemost"
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

// Spec §10: a stream that died mid-meeting stops the recording and keeps the folder as it is,
// with the reason named. Forty minutes of audio are not thrown away because the last minute
// went wrong.
@Test @MainActor func aCaptureThatDiedMidMeetingKeepsTheFolderAndNamesTheReason() async throws {
    let harness = try Harness()
    harness.captureFailure = "the capture stopped: display disconnected"
    harness.coordinator.startPressed(at: noon)

    harness.coordinator.stopPressed(at: noon.addingTimeInterval(2400))
    await harness.coordinator.settle()

    #expect(harness.handedOver.count == 1)
    #expect(harness.shown.contains(.failure("the capture stopped: display disconnected")))
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
