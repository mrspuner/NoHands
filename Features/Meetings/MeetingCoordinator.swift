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
    private let onDictationBlocked: (Bool) -> Void
    private let readProcesses: () -> [AudioProcessMonitor.State]?
    private let makeCapture: (URL, [String]) -> any MeetingCapture

    private var machine: MeetingMachine
    private var poller: Timer?

    private var capture: (any MeetingCapture)?
    /// The task running `capture.start()`. Kept so the stop below can wait for it: `stop` before
    /// `start` would tear down a stream that does not exist yet and leave the one still being
    /// built with nobody to close it. `DictationCoordinator` documents the same hazard.
    private var captureTask: Task<Void, Never>?
    /// The task that closes the capture and writes the final metadata. The hand-off waits for
    /// it — see `keepDraft`.
    private var closing: Task<Void, Never>?
    /// The task that renames or removes the folder once `closing` has finished.
    private var housekeeping: Task<Void, Never>?

    private var folder: URL?
    private var metadata: MeetingMetadata?
    private var knownPIDs: Set<Int32> = []

    /// Drafts found on disk at startup, oldest first, waiting for the owner to say keep or
    /// delete. Emptied one at a time: each answer resolves the first and offers the next.
    private var pendingOrphans: [URL] = []
    private var orphanOfferedAt: Date?

    private var monitorFailures = 0
    private var monitorFailureReported = false

    /// - Parameters:
    ///   - queue: where meeting folders are created. Injected only so tests can work in a
    ///     temporary directory instead of the owner's `~/Meetings`.
    ///   - readProcesses: `nil` from this is a failed system call, never an empty room — see
    ///     `AudioProcessMonitor.current`.
    ///   - makeCapture: takes the folder and the exclusion list, in that order. The list is
    ///     handed straight through from the config: it cuts applications out of the audio mix,
    ///     so anything added to it "just in case" would produce a valid recording full of
    ///     silence, and nothing downstream would notice.
    public init(
        config: MeetingsConfig,
        queue: URL = MeetingFolder.queueURL,
        showPanel: @escaping (MeetingPanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onDictationBlocked: @escaping (Bool) -> Void,
        readProcesses: @escaping () -> [AudioProcessMonitor.State]? = AudioProcessMonitor.current,
        makeCapture: @escaping (URL, [String]) -> any MeetingCapture = {
            MeetingAudioRecorder(folder: $0, excludedBundleIDs: $1)
        }
    ) {
        self.config = config
        self.queue = queue
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.onDictationBlocked = onDictationBlocked
        self.readProcesses = readProcesses
        self.makeCapture = makeCapture
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
        case .keep: apply(.keepPressed)
        case .delete: apply(.deletePressed)
        }
    }

    // MARK: - Polling

    func poll(now: Date = Date()) {
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
        let effects = machine.handle(event)
        let reason = Self.stopReason(for: event, effects: effects)
        let stoppedAt = Self.stoppedAt(for: event) ?? Date()
        for effect in effects {
            switch effect {
            case .startCapture(let app, let at): startCapture(app: app, at: at)
            case .stopCapture: stopCapture(at: stoppedAt, reason: reason)
            case .keepDraft: keepDraft()
            case .discardDraft: discardDraft()
            case .show(let state): showPanel(state)
            case .hide(let after): hidePanel(after)
            case .blockDictation(let blocked): onDictationBlocked(blocked)
            }
        }
    }

    /// Why the recording stopped, in the vocabulary `meeting.json` uses.
    ///
    /// Not a rule about behaviour — the machine has already decided whether to stop and what to
    /// do with the folder. This only names the cause for the file, and the cause is a property
    /// of the event that arrived. The length limit is read off the effects rather than the
    /// event, because it and the ordinary auto-stop both arrive as a tick and only the machine
    /// knows which one it just handled.
    private static func stopReason(
        for event: MeetingMachine.Event, effects: [MeetingMachine.Effect]
    ) -> MeetingMetadata.StopReason {
        if effects.contains(.show(.limitReached)) { return .lengthLimit }
        switch event {
        case .appExited:
            return .appExited
        case .captureFailedAtStart, .captureFailedWhileRecording:
            return .failure
        case .stopPressed, .keepPressed, .deletePressed, .declinePressed:
            return .manual
        // A tick that stops anything is the silence threshold running out. The rest never stop a
        // recording at all; the value is unused on those paths.
        case .tick, .streamsChanged, .startPressed, .confirmPressed:
            return .automatic
        }
    }

    /// When the recording ended, taken from the event that ended it rather than from the clock.
    ///
    /// `.startCapture` carries its own timestamp and `.stopCapture` does not, so this is the
    /// other half of the same pair: reading `Date()` inside the effect would put the moment the
    /// effect happened to run into the file instead of the moment the meeting ended — a tick
    /// that crossed a threshold can be a second late, and the difference lands in the duration
    /// phase 2б reads. `nil` for the events that carry no time; those never stop a live capture,
    /// except a capture failure, which has no better moment than now.
    private static func stoppedAt(for event: MeetingMachine.Event) -> Date? {
        switch event {
        case .streamsChanged(_, _, _, let at), .appExited(_, let at), .startPressed(_, let at),
             .stopPressed(let at), .confirmPressed(let at), .declinePressed(let at), .tick(let at):
            return at
        case .keepPressed, .deletePressed, .captureFailedAtStart, .captureFailedWhileRecording:
            return nil
        }
    }

    private func startCapture(app: MeetingMachine.MeetingApp?, at: Date) {
        do {
            let draft = try MeetingFolder.createDraft(
                in: queue, startedAt: at, slug: app?.slug ?? Self.manualSlug
            )
            folder = draft
            let device = AudioInputDevice.current()
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

            let capture = makeCapture(draft, config.excludedApps)
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

    private func stopCapture(at: Date, reason: MeetingMetadata.StopReason) {
        guard let capture, let folder else { return }
        self.capture = nil
        let pendingStart = captureTask
        captureTask = nil
        let metadataURL = folder.appendingPathComponent(MeetingMetadata.fileName)
        metadata?.stoppedAt = at
        metadata?.stopReason = reason
        closing = Task { @MainActor [weak self] in
            await pendingStart?.value
            var failure: String?
            do {
                let outcome = try await capture.stop()
                self?.metadata?.systemStartedAt = outcome.systemStartedAt
                self?.metadata?.microphoneStartedAt = outcome.microphoneStartedAt
                failure = outcome.failure
            } catch {
                failure = Self.describe(error)
            }
            do {
                try self?.metadata?.write(to: metadataURL)
            } catch {
                failure = failure ?? "Cannot write \(MeetingMetadata.fileName): " +
                    "\(error.localizedDescription)"
            }
            self?.metadata = nil
            // Spec §10: a capture that went wrong stops the recording and keeps the folder as it
            // is, with the reason named. The machine has already decided the folder's fate, so
            // all that is left is to say what happened — and saying nothing is how an hour of
            // silence would pass for a meeting.
            if let failure { self?.report(failure) }
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
            await closing?.value
            do {
                try MeetingFolder.promote(folder)
            } catch {
                self?.report(
                    "Cannot hand over \(folder.lastPathComponent): \(error.localizedDescription)"
                )
            }
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
        let closing = self.closing
        self.closing = nil
        housekeeping = Task { @MainActor [weak self] in
            // Same wait as the hand-off, for the opposite reason: removing a folder the capture
            // is still writing into would let the next buffer recreate what was just deleted.
            await closing?.value
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
        guard let draft = pendingOrphans.first else { return }
        orphanOfferedAt = now
        showPanel(.orphanFound(duration: Self.recordedSpan(of: draft, now: now)))
    }

    private func keepOrphan(now: Date) {
        guard !pendingOrphans.isEmpty else { return }
        let draft = pendingOrphans.removeFirst()
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
            try MeetingFolder.promote(draft)
        } catch {
            failures.append(
                "Cannot hand over \(draft.lastPathComponent): \(error.localizedDescription)"
            )
        }
        finishOrphan(now: now, failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
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
        finishOrphan(now: now, failure: failure)
    }

    private func finishOrphan(now: Date, failure: String?) {
        orphanOfferedAt = nil
        if let failure {
            // The named reason keeps the panel. Anything still pending waits for the next launch
            // rather than replacing a message the owner has not read yet.
            report(failure)
            return
        }
        if pendingOrphans.isEmpty {
            hidePanel(0)
            return
        }
        refreshOrphanPrompt(now: now)
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
        hidePanel(MeetingMachine.failureDwell)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Waits for whatever the last effect started. For the tests: the folder work is
    /// deliberately asynchronous, and a test that looked at the disk straight away would be
    /// looking before the coordinator got there.
    func settle() async {
        await captureTask?.value
        await closing?.value
        await housekeeping?.value
    }
}
