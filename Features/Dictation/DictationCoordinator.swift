import AppKit
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
    private var audioURL: URL?

    public init(
        config: DictationConfig,
        recorder: MicrophoneRecorder,
        transcriber: any Transcriber,
        cleaner: DeepSeekClient,
        inserter: TextInserter,
        sounds: SoundPlayer,
        showPanel: @escaping (PanelState) -> Void,
        hidePanel: @escaping (TimeInterval) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
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
        // Quitting or reloading mid-dictation must not leave the engine running or a partial
        // recording of the owner's own speech behind on disk.
        Task { [recorder] in await recorder.discard() }
        discardAudioFile()
    }

    private func received(_ kind: KeyEventKind) {
        let now = Date()
        switch kind {
        case .fnDown:
            // The target is fixed when recording starts, not when the text is pasted: if the
            // owner switches windows mid-sentence, the text still goes where they were aiming.
            apply(.fnDown(at: now, target: Self.frontmostApp()))
        case .fnUp:
            apply(.fnUp(at: now))
        case .spaceDown:
            apply(.spaceDown)
        case .escapeDown:
            apply(.escapeDown)
        }
    }

    private static func frontmostApp() -> TargetApp {
        let app = NSWorkspace.shared.frontmostApplication
        return TargetApp(
            bundleIdentifier: app?.bundleIdentifier,
            name: app?.localizedName ?? "активное окно"
        )
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
            Task { [recorder] in
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

        case .insert(let text, let target, _):
            discardAudioFile()
            run { [inserter] in
                do {
                    try await inserter.insert(text, into: target)
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
        }
    }

    private func startRecording() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nohands-dictation-\(UUID().uuidString).wav")
        audioURL = url
        let level = onLevel
        Task { [weak self, recorder] in
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
