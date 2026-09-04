import Core
import Foundation

/// Performs what `MeetingMachine` decides.
///
/// Glue, like `DictationCoordinator`: every branch below is one the machine already chose, and
/// the only decisions taken here are about things a pure function must not own — the folder of
/// a half-written recording, the order two asynchronous halves finish in, and a draft found on
/// disk that no machine is in the middle of.
///
/// That last one is the reason this type is longer than a plain `switch`. A folder left behind
/// by a crash has no capture, no meeting clock and no state to return to; putting it in the
/// machine would mean inventing a recording that is not being recorded. It lives here instead,
/// and the answers to its prompt take their own path — see `answer`.
@MainActor
public final class MeetingCoordinator {
    public enum Answer: Sendable {
        case confirm
        case decline
        case keep
        case delete
    }

    /// How many polls in a row may fail before the owner hears about it.
    ///
    /// A single refusal from CoreAudio is survivable and not worth interrupting for: the process
    /// list is rebuilt whenever a device is plugged in or removed, and a one-second gap in
    /// detection costs nothing, because a meeting is recognised by devices that stay busy for
    /// minutes. Ten seconds of solid refusal is a different animal — nothing transient lasts
    /// that long, and from then on no meeting will ever be noticed again. That has to be said,
    /// and said once: repeating it every second would bury the panel in the same sentence.
    static let monitorFailureLimit = 10

    /// The folder name of a recording started by hand while nothing recognisable was holding the
    /// audio devices.
    private static let manualSlug = "manual"

    private let config: MeetingsConfig
    private let queue: URL
    private let showPanel: (MeetingPanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    /// The input's sample rate when it is below the narrowband threshold, nil when the band is
    /// fine. A fact rather than a sentence, exactly as `DictationCoordinator` reports it: the
    /// wording belongs to the `App` target.
    private let onNarrowbandInput: (Double?) -> Void
    private let onDictationBlocked: (Bool) -> Void
    private let isDictating: () -> Bool
    private let readInputDevice: () -> AudioInputDevice?
    private let readProcesses: () -> [AudioProcessMonitor.State]?
    private let makeCapture: (URL, [String], @escaping @Sendable (String) -> Void) -> any MeetingCapture
    /// The hand-off to phase 2б. Called with the folder's final name, after the rename that
    /// makes it visible to the queue — never with the draft.
    private let onFolderReady: (URL) -> Void

    private var machine: MeetingMachine
    private var poller: Timer?

    private var capture: (any MeetingCapture)?
    /// The task running `capture.start()`. Kept so the stop below can wait for it: `stop` before
    /// `start` would tear down a stream that does not exist yet and leave the one still being
    /// built with nobody to close it. `DictationCoordinator` documents the same hazard.
    private var captureTask: Task<Void, Never>?
    /// The task that closes the capture and writes the final metadata, returning whatever went
    /// wrong. The hand-off waits for it and is what shows the failure — see `keepDraft`.
    private var closing: Task<String?, Never>?
    /// The task that renames or removes the folder once `closing` has finished.
    private var housekeeping: Task<Void, Never>?

    private var folder: URL?
    private var metadata: MeetingMetadata?
    private var knownPIDs: Set<Int32> = []

    /// Which capture the coordinator is listening to, or `nil` while nothing is recording.
    ///
    /// A dying stream reports from its own queue, and the message reaches the main actor a hop
    /// later. In that window this meeting may have ended — and the next one may already be
    /// recording, in which case acting on the message would stop a healthy capture and file a
    /// live meeting as failed. Identity rather than "is anything recording" is what tells those
    /// two apart; `stopCapture` documents the same hazard about metadata.
    private var liveCaptureID: Int?
    private var capturesStarted = 0

    /// Drafts found on disk at startup, oldest first, waiting for the owner to say keep or
    /// delete. Emptied one at a time: each answer resolves the first and offers the next.
    private var pendingOrphans: [URL] = []
    private var orphanOfferedAt: Date?
    /// Nothing is offered before this moment. Set when answering one draft went wrong, so the
    /// named reason gets the same dwell as any other failure instead of being pushed off the
    /// panel by the next prompt a second later.
    private var orphanQuietUntil: Date?

    private var monitorFailures = 0
    private var monitorFailureReported = false

    /// Events raised while an earlier one is still having its effects performed, and whether
    /// that is happening right now.
    ///
    /// An effect can fail on the spot: `startCapture` throws when the meeting folder cannot be
    /// created — no disk space, no `~/Meetings` — and the machine has to hear about it. Handing
    /// it back the moment it happened ran the failure's whole recovery from inside the loop, and
    /// the loop then went on performing the rest of the *first* event's list over the top of it:
    /// dictation blocked again with nothing left to unblock it, and a prompt put back that the
    /// machine no longer answers, holding the panel over the Dock until a restart. Queued
    /// instead, so a failure is always handled after the list it happened in, never inside it.
    ///
    /// `DictationCoordinator` splits the same two jobs — `apply` decides, `perform` does — and
    /// never needed a queue: every failure it can raise comes back through a task, so it is
    /// already a separate turn on the main actor by the time it arrives. This is the only
    /// synchronous one in either coordinator.
    private var pending: [MeetingMachine.Event] = []
    private var applying = false

    /// - Parameters:
    ///   - queue: where meeting folders are created. Injected only so tests can work in a
    ///     temporary directory instead of the owner's `~/Meetings`.
    ///   - isDictating: whether a dictation is in flight this second. Asked rather than pushed,
    ///     for the reason `activity` gives about its own direction: a copy kept here would be a
    ///     second version of a fact that lives in the dictation machine.
    ///   - readProcesses: `nil` from this is a failed system call, never an empty room — see
    ///     `AudioProcessMonitor.current`.
    ///   - makeCapture: takes the folder, the exclusion list and the handler for a stream that
    ///     dies mid-meeting, in that order. The list is handed straight through from the config:
    ///     it cuts applications out of the audio mix, so anything added to it "just in case"
    ///     would produce a valid recording full of silence, and nothing downstream would notice.
    ///   - onFolderReady: called once per hand-off, with the folder's final URL. Defaults to
    ///     doing nothing — this initializer already has a dozen parameters and about fifteen call
    ///     sites in the tests, and "hand off to nobody" is exactly the behaviour that existed
    ///     before phase 2б had a queue to hand off to.
    public init(
        config: MeetingsConfig,
        queue: URL = MeetingFolder.queueURL,
        showPanel: @escaping (MeetingPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onNarrowbandInput: @escaping (Double?) -> Void,
        onDictationBlocked: @escaping (Bool) -> Void,
        isDictating: @escaping () -> Bool,
        readInputDevice: @escaping () -> AudioInputDevice? = AudioInputDevice.current,
        readProcesses: @escaping () -> [AudioProcessMonitor.State]? = AudioProcessMonitor.current,
        makeCapture: @escaping (URL, [String], @escaping @Sendable (String) -> Void) -> any MeetingCapture = {
            MeetingAudioRecorder(folder: $0, excludedBundleIDs: $1, onFailureWhileRecording: $2)
        },
        onFolderReady: @escaping (URL) -> Void = { _ in }
    ) {
        self.config = config
        self.queue = queue
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.onNarrowbandInput = onNarrowbandInput
        self.onDictationBlocked = onDictationBlocked
        self.isDictating = isDictating
        self.readInputDevice = readInputDevice
        self.readProcesses = readProcesses
        self.makeCapture = makeCapture
        self.onFolderReady = onFolderReady
        self.machine = MeetingMachine(limits: MeetingMachine.Limits(config: config))
    }

    /// One timer drives both jobs: reading who holds the audio devices and ticking the machine.
    /// A second of granularity is plenty for thresholds measured in tens of seconds.
    ///
    /// Registered in `.common` rather than the default mode for the reason `DictationCoordinator`
    /// gives: a `.default`-mode timer stops firing while a menu is open, and this application's
    /// menu is one of its two surfaces.
    public func start() {
        adoptOrphans()
        let poller = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
    }

    /// Stops watching. A recording in flight is deliberately left as it is rather than closed:
    /// quitting mid-meeting leaves the same draft a crash would, and the same prompt picks it up
    /// on the next launch, headers repaired. Closing it here would need a rule about what a quit
    /// means for an unconfirmed recording, and that rule belongs to the machine.
    public func stop() {
        poller?.invalidate()
        poller = nil
    }

    public func startPressed(at now: Date = Date()) {
        let app = MeetingWatcher
            .match(states: readProcesses() ?? [], config: config)
            .first { $0.input || $0.output }?
            .app
        apply(.startPressed(app: app, at: now))
    }

    public func stopPressed(at now: Date = Date()) {
        apply(.stopPressed(at: now))
    }

    public func answer(_ answer: Answer, at now: Date = Date()) {
        // A found folder is not a recording, so it is answered outside the machine — which in
        // this state ignores `keep` and `delete` anyway, and rightly: it has no capture to stop
        // and no meeting to end. Anything the machine is in the middle of wins the answer.
        if machine.state == .idle, orphanOfferedAt != nil {
            switch answer {
            case .keep: keepOrphan(now: now)
            case .delete: deleteOrphan(now: now)
            // The orphan prompt offers exactly two buttons; nothing sends these.
            case .confirm, .decline: break
            }
            return
        }
        switch answer {
        case .confirm: apply(.confirmPressed(at: now))
        case .decline: apply(.declinePressed(at: now))
        case .keep: apply(.keepPressed(at: now))
        case .delete: apply(.deletePressed(at: now))
        }
    }

    /// What the menu bar may offer about meetings right now.
    ///
    /// A pass-through, not a copy: the answer is a function of the machine's state and lives
    /// there, the way `DictationCoordinator.isBlocked` passes through to its own machine. Read
    /// rather than pushed — a second copy of "is a meeting being recorded" would be a second
    /// thing that can be wrong, and the wrong one would be the one deciding whether dictation
    /// is allowed to run.
    public var activity: MeetingMachine.Activity {
        machine.state.activity
    }

    /// Whether this coordinator may be thrown away and built again from a re-read config.
    ///
    /// A different question from `activity`, and answering it with that one is a defect rather
    /// than a shortcut: to the menu a refusal is `.ready`, because the manual start is exactly
    /// what the owner reaches for after refusing by mistake — but a rebuild would erase the
    /// refusal, the meeting application is still holding the devices, and the very next poll
    /// would start recording the meeting that was just refused. Silence would then save it.
    ///
    /// Rebuilding is safe only when nothing lives in this object that the new one could not
    /// find for itself. Two things do: whatever the machine remembers, and the orphan prompt,
    /// which is offered from here rather than by the machine. Everything else — the drafts on
    /// disk, the processes holding the devices — the new coordinator reads again at startup.
    public var canBeRebuilt: Bool {
        machine.state == .idle && orphanOfferedAt == nil
    }

    // MARK: - Polling

    func poll(now: Date = Date()) {
        // Spec §6: a meeting that begins while a dictation is in flight waits for it — "ждать
        // секунды" — instead of cutting the owner off in the middle of a sentence. This is the
        // source going quiet, not a rule: while the microphone belongs to a dictation, this poll
        // has nothing it may say about who is holding the audio devices, so it says nothing, and
        // the machine hears exactly what it would hear from a meeting that has not started yet.
        // Written here rather than as a case in the machine because it is not a decision about
        // meetings at all: it is one feature declining to speak while the other has the input.
        //
        // The clock keeps running for the same reason it does when the monitor refuses below:
        // the length limit and the auto-stop must depend on nothing but time.
        guard !isDictating() else {
            apply(.tick(now))
            refreshOrphanPrompt(now: now)
            return
        }
        guard let states = readProcesses() else {
            noteMonitorFailure()
            // The clock keeps running regardless: the length limit and the auto-stop must not
            // depend on whether CoreAudio felt like answering this second.
            apply(.tick(now))
            refreshOrphanPrompt(now: now)
            return
        }
        monitorFailures = 0
        monitorFailureReported = false

        let matches = MeetingWatcher.match(states: states, config: config)
        let live = Set(matches.map(\.app.pid))
        for gone in knownPIDs.subtracting(live).sorted() {
            apply(.appExited(pid: gone, at: now))
        }
        knownPIDs = live
        for match in matches {
            apply(.streamsChanged(app: match.app, input: match.input, output: match.output, at: now))
        }
        apply(.tick(now))
        refreshOrphanPrompt(now: now)
    }

    private func noteMonitorFailure() {
        monitorFailures += 1
        guard monitorFailures >= Self.monitorFailureLimit, !monitorFailureReported else { return }
        monitorFailureReported = true
        report(
            "Cannot read the audio process list — meetings will not be noticed on their own. " +
            "Start one from the menu."
        )
    }

    // MARK: - Performing what the machine decided

    private func apply(_ event: MeetingMachine.Event) {
        pending.append(event)
        guard !applying else { return }
        applying = true
        defer { applying = false }
        while !pending.isEmpty {
            for effect in machine.handle(pending.removeFirst()) {
                perform(effect)
            }
        }
    }

    private func perform(_ effect: MeetingMachine.Effect) {
        switch effect {
        case .startCapture(let app, let at): startCapture(app: app, at: at)
        case .stopCapture(let at, let reason): stopCapture(at: at, reason: reason)
        case .keepDraft: keepDraft()
        case .discardDraft: discardDraft()
        case .show(let state): showPanel(state)
        case .hide(let after): hidePanel(after)
        case .blockDictation(let blocked): onDictationBlocked(blocked)
        }
    }

    private func startCapture(app: MeetingMachine.MeetingApp?, at: Date) {
        do {
            let draft = try MeetingFolder.createDraft(
                in: queue, startedAt: at, slug: app?.slug ?? Self.manualSlug
            )
            folder = draft
            let device = readInputDevice()
            // Spec §10: the same warning dictation shows, and said here for the same reason —
            // a Bluetooth microphone drops the whole device into narrowband, the recording goes
            // ahead regardless, and the owner is the only one who can swap the microphone while
            // that still helps. Written into `meeting.json` as well, but a file nobody reads
            // during the meeting is not a warning. Once, at the start, as in dictation.
            onNarrowbandInput(device.flatMap { $0.isNarrowband ? $0.sampleRate : nil })
            let metadata = MeetingMetadata(
                startedAt: at,
                stoppedAt: nil,
                app: app.map {
                    MeetingMetadata.App(bundleID: $0.bundleID, name: $0.name, slug: $0.slug)
                },
                sampleRate: MeetingAudioRecorder.sampleRate,
                channelCount: Int(MeetingAudioRecorder.channelCount),
                inputDevice: device.map {
                    MeetingMetadata.InputDevice(
                        name: $0.name, sampleRate: $0.sampleRate, isNarrowband: $0.isNarrowband
                    )
                },
                stopReason: nil,
                excludedApps: config.excludedApps,
                gaps: [],
                systemStartedAt: nil,
                microphoneStartedAt: nil
            )
            // Written now and rewritten at the end, rather than only at the end: a draft left
            // behind by a crash is otherwise two nameless wav files, with no record of when the
            // meeting began or which device was recording — the two things that make a bad
            // recording explainable afterwards.
            try metadata.write(to: draft.appendingPathComponent(MeetingMetadata.fileName))
            self.metadata = metadata

            capturesStarted += 1
            let id = capturesStarted
            liveCaptureID = id
            let capture = makeCapture(draft, config.excludedApps) { message in
                // The capture reports from its own queue, so this is the crossing to the main
                // actor, written out rather than assumed. `@MainActor` on the coordinator makes
                // a weak reference to it safe to carry across.
                Task { @MainActor [weak self] in self?.captureDied(message, id: id) }
            }
            self.capture = capture
            captureTask = Task { @MainActor [weak self] in
                do {
                    try await capture.start()
                } catch {
                    // Nothing reached the disk, so the draft is worth nothing: this is the
                    // failure that throws it away, as opposed to a stream that dies later.
                    self?.apply(.captureFailedAtStart(Self.describe(error)))
                }
            }
        } catch {
            apply(.captureFailedAtStart(Self.describe(error)))
        }
    }

    /// The stream died while the meeting was still being recorded.
    ///
    /// Nothing is decided here beyond whether the message still belongs to anything: what a dead
    /// stream costs — the recording stops, the folder is kept as it is rather than thrown away —
    /// is the machine's rule, and it differs from a capture that never started by exactly that.
    ///
    /// The timestamp is taken here because there is nowhere else to take it from: unlike every
    /// other event, this one is not raised by a poll or a click that already knows the time.
    private func captureDied(_ message: String, id: Int) {
        guard liveCaptureID == id else { return }
        apply(.captureFailedWhileRecording(message, at: Date()))
    }

    /// Closes the capture and writes the finished `meeting.json`.
    ///
    /// Everything this recording needs is taken out of `self` and into the task **before** it is
    /// created, and the task never reads any of it back. The suspension at `capture.stop()`
    /// releases the main actor for as long as a real `SCStream` takes to close, and a single
    /// tick in that window is enough to start the next meeting: the machine is already at rest
    /// after a limit, an auto-stop or a manual stop, while the meeting application often still
    /// holds the devices. Reading `self.metadata` after the suspension would then write the new
    /// meeting's start time into the old meeting's file and blank the new one's.
    ///
    /// The failure, if any, is *returned* rather than shown. Whoever decides the folder's fate
    /// shows it — see `keepDraft` — because a folder about to be thrown away needs no complaint,
    /// and because a failure shown while `.savePrompt` is up would replace the prompt and leave
    /// the owner with no way to answer it.
    private func stopCapture(at: Date, reason: MeetingMetadata.StopReason) {
        guard let capture, let folder else { return }
        self.capture = nil
        // From here on this capture speaks about a meeting that is over.
        liveCaptureID = nil
        let pendingStart = captureTask
        captureTask = nil
        let metadataURL = folder.appendingPathComponent(MeetingMetadata.fileName)
        var finished = metadata
        finished?.stoppedAt = at
        finished?.stopReason = reason
        metadata = nil
        closing = Task { @MainActor in
            await pendingStart?.value
            var record = finished
            var failure: String?
            do {
                let outcome = try await capture.stop()
                record?.systemStartedAt = outcome.systemStartedAt
                record?.microphoneStartedAt = outcome.microphoneStartedAt
                failure = outcome.failure
            } catch {
                failure = Self.describe(error)
            }
            do {
                try record?.write(to: metadataURL)
            } catch {
                failure = failure ?? "Cannot write \(MeetingMetadata.fileName): " +
                    "\(error.localizedDescription)"
            }
            return failure
        }
    }

    private func keepDraft() {
        guard let folder else { return }
        self.folder = nil
        let closing = self.closing
        self.closing = nil
        housekeeping = Task { @MainActor [weak self] in
            // The rename is the hand-off to phase 2б, and the leading dot exists precisely so a
            // folder still being written is never picked up as finished. Waiting for the task
            // that closes the capture and rewrites the metadata is the whole guarantee; a sleep
            // in its place would only make the race rarer and harder to see.
            var failures: [String] = []
            if let stopFailure = await closing?.value ?? nil { failures.append(stopFailure) }
            do {
                let ready = try MeetingFolder.promote(folder)
                self?.onFolderReady(ready)
            } catch {
                failures.append(
                    "Cannot hand over \(folder.lastPathComponent): \(error.localizedDescription)"
                )
            }
            // Spec §10: a capture that went wrong stops the recording and keeps the folder as it
            // is, with the reason named. The machine has already decided the folder's fate, so
            // all that is left is to say what happened — and saying nothing is how an hour of
            // silence would pass for a meeting.
            if !failures.isEmpty { self?.report(failures.joined(separator: "; ")) }
        }
    }

    private func discardDraft() {
        guard let folder else { return }
        self.folder = nil
        metadata = nil
        // A capture that never started is discarded without a `.stopCapture` before it, so this
        // is the only place that lets go of it. Not awaited: there is nothing to wait for — the
        // start has already thrown, which is what brought us here.
        capture = nil
        captureTask = nil
        liveCaptureID = nil
        let closing = self.closing
        self.closing = nil
        housekeeping = Task { @MainActor [weak self] in
            // Same wait as the hand-off, for the opposite reason: removing a folder the capture
            // is still writing into would let the next buffer recreate what was just deleted.
            //
            // Whatever the capture had to complain about is dropped on purpose. The owner
            // pressed "no"; telling them the stream had trouble writing a folder that no longer
            // exists answers a question nobody asked.
            _ = await closing?.value
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                // Left alone, an undeleted draft turns up as an orphan prompt at the next
                // launch, about a recording the owner already refused.
                self?.report(
                    "Cannot remove \(folder.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - The draft a crash left behind

    /// Finds drafts left over from a previous run and offers the first one.
    ///
    /// Only ever called with nothing recording: the folder of a live meeting is a draft too, and
    /// adopting it would offer the owner a prompt about the meeting they are in.
    public func adoptOrphans(at now: Date = Date()) {
        guard machine.state == .idle, folder == nil else { return }
        do {
            pendingOrphans = try MeetingFolder.drafts(in: queue)
        } catch {
            report("Cannot read \(queue.path): \(error.localizedDescription)")
            return
        }
        refreshOrphanPrompt(now: now)
    }

    private func refreshOrphanPrompt(now: Date) {
        // Never over the top of a live meeting: a prompt about last week's folder must not cover
        // the recording happening now. What is pending stays pending — but the offer itself is
        // forgotten, because the meeting has taken the panel and the prompt is no longer on
        // screen. Leaving it standing would let it time out from behind a recording, turning
        // "unanswered" into "never seen"; forgetting it puts the prompt back up, countdown and
        // all, once the machine is resting again.
        guard machine.state == .idle else {
            orphanOfferedAt = nil
            return
        }
        if let offeredAt = orphanOfferedAt {
            // Silence keeps here as well. An unanswered prompt is not a refusal, and the only
            // thing in this whole feature that deletes is an explicit "delete".
            guard now.timeIntervalSince(offeredAt) >= config.autoStopSeconds else { return }
            keepOrphan(now: now)
            return
        }
        if let quietUntil = orphanQuietUntil {
            guard now >= quietUntil else { return }
            orphanQuietUntil = nil
        }
        guard let draft = pendingOrphans.first else { return }
        orphanOfferedAt = now
        showPanel(.orphanFound(duration: Self.recordedSpan(of: draft, now: now)))
    }

    private func keepOrphan(now: Date) {
        guard !pendingOrphans.isEmpty else { return }
        let draft = pendingOrphans.removeFirst()
        // Measured before the hand-off: after the rename this path no longer exists.
        let span = Self.recordedSpan(of: draft, now: now)
        var failures: [String] = []
        for name in [MeetingAudioRecorder.systemFileName, MeetingAudioRecorder.microphoneFileName] {
            let url = draft.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                // A file whose writer never closed it declares a `data` length of zero and reads
                // as an empty recording, however many samples are actually in it. Repairing
                // before the hand-off is the difference between keeping a meeting and keeping a
                // file that opens to silence. Already-healthy files are left untouched.
                try WavHeaderRepair.repair(at: url)
            } catch {
                failures.append("Cannot repair \(name): \(Self.describe(error))")
            }
        }
        do {
            // Handed over even when a repair failed: the owner asked to keep this recording, and
            // a track that cannot be repaired is still a track. The reason is named rather than
            // turned into a silent refusal to save.
            let ready = try MeetingFolder.promote(draft)
            onFolderReady(ready)
        } catch {
            failures.append(
                "Cannot hand over \(draft.lastPathComponent): \(error.localizedDescription)"
            )
        }
        finishOrphan(
            now: now,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; "),
            saved: span
        )
    }

    private func deleteOrphan(now: Date) {
        guard !pendingOrphans.isEmpty else { return }
        let draft = pendingOrphans.removeFirst()
        var failure: String?
        do {
            try FileManager.default.removeItem(at: draft)
        } catch {
            failure = "Cannot remove \(draft.lastPathComponent): \(error.localizedDescription)"
        }
        finishOrphan(now: now, failure: failure, saved: nil)
    }

    /// - Parameter saved: how long the kept recording ran, or nil when it was deleted.
    private func finishOrphan(now: Date, failure: String?, saved: TimeInterval?) {
        orphanOfferedAt = nil
        if let failure {
            // The named reason keeps the panel for its dwell, and the next prompt waits behind
            // it. A reason the owner has one second to read is a reason nobody reads.
            report(failure)
            orphanQuietUntil = now.addingTimeInterval(MeetingMachine.noticeDwell)
            return
        }
        // An answer is followed by a word about what it did — the same rule the meeting paths
        // follow since the first live recording, where a panel that just collapsed left the
        // owner unable to tell a saved recording from a deleted one. The quiet window is what
        // keeps the next orphan prompt from replacing that word before it is read.
        showPanel(saved.map { .saved(duration: $0) } ?? .deleted)
        hidePanel(MeetingMachine.noticeDwell)
        orphanQuietUntil = now.addingTimeInterval(MeetingMachine.noticeDwell)
    }

    /// How long the recording in this folder ran: from when it started to the last time anything
    /// in it was written. Measured rather than taken from the clock, because a draft found at
    /// startup may have been left there days ago, and "47 minutes" is what the owner needs to
    /// decide whether to keep it — not how long ago the crash was.
    private static func recordedSpan(of draft: URL, now: Date) -> TimeInterval {
        let started = startOfRecording(in: draft) ?? now
        let last = lastWrite(in: draft) ?? started
        return max(0, last.timeIntervalSince(started))
    }

    private static func startOfRecording(in draft: URL) -> Date? {
        let url = draft.appendingPathComponent(MeetingMetadata.fileName)
        if let metadata = try? MeetingMetadata.read(from: url) { return metadata.startedAt }
        // No readable metadata: the folder itself was created when the recording began.
        return (try? draft.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private static func lastWrite(in draft: URL) -> Date? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: draft, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return nil }
        return entries.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    // MARK: - Odds and ends

    private func report(_ message: String) {
        showPanel(.failure(message))
        hidePanel(MeetingMachine.noticeDwell)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Waits for whatever the last effect started. For the tests: the folder work is
    /// deliberately asynchronous, and a test that looked at the disk straight away would be
    /// looking before the coordinator got there.
    func settle() async {
        await captureTask?.value
        _ = await closing?.value
        await housekeeping?.value
    }
}
