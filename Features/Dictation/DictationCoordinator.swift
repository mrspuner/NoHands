import Core
import Foundation

/// Performs what the state machine decides.
///
/// Everything here is glue: it holds no rules of its own, and every branch it takes is one the
/// machine already chose. The panel is the single thing it cannot do itself, so drawing arrives
/// as closures from the `App` target — a protocol with one implementation would only obscure
/// which way the dependency runs.
@MainActor
public final class DictationCoordinator {
    private let recorder: MicrophoneRecorder
    private let transcriber: any Transcriber
    private let cleaner: DeepSeekClient
    private let inserter: TextInserter
    private let sounds: SoundPlayer
    private let showPanel: (PanelState) -> Void
    private let hidePanel: (TimeInterval) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private var machine: DictationMachine
    private var monitor: FnKeyMonitor?
    private var ticker: Timer?
    private var work: Task<Void, Never>?
    /// The task running `recorder.start`, from the moment `.startRecording` is performed until
    /// it finishes. `.startRecording` and `.discardRecording` are each performed in their own
    /// bare `Task {}`, and Swift guarantees no ordering between two independent tasks touching
    /// the same actor — `FnKeyMonitor` documents the identical hazard in its own delivery path.
    /// A sub-threshold fn brush emits both in quick succession; if the discard task ever ran
    /// its `recorder.discard()` before the start task's `recorder.start()`, `discard()` would
    /// return early on a session that does not exist yet, and `start()` would then install a
    /// tap nobody removes. Tracked here so `.discardRecording` and `stop()` can `await` it
    /// first and make that inversion impossible. The window is widest on the very first run,
    /// where `recorder.start` blocks on the microphone permission dialog.
    private var startTask: Task<Void, Never>?
    /// Ownership of the file at this URL, since nothing else states the rule:
    /// - Set only by `startRecording()`, the moment the temp path is chosen — before the
    ///   recorder has necessarily started writing to it.
    /// - Cleared to nil, and the file deleted, by whichever effect finishes with it:
    ///   `.discardRecording` (after `recorder.discard()` returns), `.remember` (which hands the
    ///   file to `RecentDictations` instead — ownership passes, the file is not deleted here), or
    ///   `discardAudioFile()`, the direct-delete helper used by `.cancelWork` and by `stop()`.
    /// - `.cancelWork` deletes the file directly instead of calling `recorder.discard()`
    ///   because by the time it runs the machine has already left `.recording`: the recorder
    ///   was already told to stop (`.stopRecording`) or has already handed back its file
    ///   (`.transcribe`), so there is no live session left for `discard()` to tear down — it
    ///   would just return early. `.discardRecording` is the opposite case: it fires from
    ///   inside `.recording`, the session is still live, and `discard()` is what tears it down;
    ///   deleting the file without it would leave the engine still running.
    private var audioURL: URL?
    private let recent: RecentDictations

    public init(
        config: DictationConfig,
        recorder: MicrophoneRecorder,
        transcriber: any Transcriber,
        cleaner: DeepSeekClient,
        inserter: TextInserter,
        recent: RecentDictations,
        sounds: SoundPlayer,
        showPanel: @escaping (PanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.recent = recent
        self.sounds = sounds
        self.showPanel = showPanel
        self.hidePanel = hidePanel
        self.onLevel = onLevel
        self.machine = DictationMachine(limits: DictationMachine.Limits(config: config))
    }

    public func start() throws {
        let monitor = FnKeyMonitor { [weak self] kind in
            MainActor.assumeIsolated {
                self?.received(kind)
            }
        }
        try monitor.start()
        self.monitor = monitor
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        ticker?.invalidate()
        ticker = nil
        work?.cancel()
        let pendingStart = startTask
        startTask = nil
        // Quitting or reloading mid-dictation must not leave the engine running or a partial
        // recording of the owner's own speech behind on disk. Awaiting a still-in-flight start
        // first keeps `recorder.start` from ever running after this `discard` — see the comment
        // on `startTask` for the failure that would otherwise cause.
        Task { [recorder, pendingStart] in
            await pendingStart?.value
            await recorder.discard()
        }
        discardAudioFile()
        // The texts are the owner's safety net and must survive a config reload; the recording
        // belongs to this coordinator and must not outlive it.
        recent.discardAudio()
    }

    private func received(_ kind: KeyEventKind) {
        let now = Date()
        switch kind {
        case .fnDown:
            apply(.fnDown(at: now))
        case .fnUp:
            apply(.fnUp(at: now))
        case .spaceDown:
            apply(.spaceDown)
        case .escapeDown:
            apply(.escapeDown)
        }
    }

    private func apply(_ event: DictationMachine.Event) {
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    private func perform(_ effect: DictationMachine.Effect) {
        switch effect {
        case .startRecording:
            startRecording()

        case .stopRecording:
            stopTicker()
            run { [recorder] in
                do {
                    let url = try await recorder.stop()
                    return .recordingStopped(url)
                } catch {
                    return .recordingFailed(error.localizedDescription)
                }
            }

        case .discardRecording:
            stopTicker()
            let url = audioURL
            audioURL = nil
            let pendingStart = startTask
            startTask = nil
            Task { [recorder, pendingStart] in
                // The start this discard is meant to undo may still be in flight — awaiting it
                // first guarantees `recorder.start` has run before `recorder.discard` does, so
                // a fast discard can never overtake a slow start. See the comment on
                // `startTask`.
                await pendingStart?.value
                await recorder.discard()
                if let url { try? FileManager.default.removeItem(at: url) }
            }

        case .cancelWork:
            work?.cancel()
            work = nil
            discardAudioFile()

        case .transcribe(let url):
            run { [transcriber] in
                do {
                    return .transcribed(try await transcriber.transcribe(audio: url))
                } catch {
                    return .transcriptionFailed(error.localizedDescription)
                }
            }

        case .clean(let text):
            run { [cleaner] in
                do {
                    return .cleaned(try await cleaner.clean(text))
                } catch {
                    return .cleanupFailed(error.localizedDescription)
                }
            }

        case .insert(let text, _):
            run { [inserter] in
                do {
                    try await inserter.insert(text)
                    return .inserted
                } catch {
                    return .insertionFailed(error.localizedDescription)
                }
            }

        case .show(let state):
            showPanel(state)

        case .hidePanel(let delay):
            hidePanel(delay)

        case .play(let sound):
            sounds.play(sound)

        case .swallow(let space, let escape):
            monitor?.setSwallow(space: space, escape: escape)

        case .remember(let raw, let cleaned):
            let audio = audioURL
            audioURL = nil
            recent.remember(raw: raw, cleaned: cleaned, audio: audio)
        }
    }

    private func startRecording() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nohands-dictation-\(UUID().uuidString).wav")
        audioURL = url
        let level = onLevel
        startTask = Task { [weak self, recorder] in
            do {
                try await recorder.start(to: url) { value in
                    DispatchQueue.main.async { level(value) }
                }
            } catch {
                await MainActor.run { self?.apply(.recordingFailed(error.localizedDescription)) }
            }
        }
        // Both thresholds — the accidental brush and the five-minute cut-off — are noticed by
        // the machine, which needs a clock to notice them with. Registered in `.common` rather
        // than left in `Timer.scheduledTimer`'s default `.default` mode: the tap's own run loop
        // source already uses `.commonModes`, and a `.default`-mode timer stops firing while the
        // menu is open or a window is being dragged — exactly when this app's one visible
        // surface is in use.
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(.tick(Date()))
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func discardAudioFile() {
        guard let url = audioURL else { return }
        audioURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs one step of the pipeline and feeds its outcome back as an event. Cancellation is
    /// checked before feeding: escape must leave nothing behind.
    private func run(_ body: @escaping @Sendable () async -> DictationMachine.Event) {
        work?.cancel()
        work = Task { [weak self] in
            let event = await body()
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.apply(event) }
        }
    }
}
