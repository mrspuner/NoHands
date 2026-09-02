import AppKit
import Core
import Dictation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private var coordinator: DictationCoordinator?
    private var buildTask: Task<Void, Never>?
    private let panel = DictationPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(
            onQuit: { [weak self] in self?.coordinator?.stop() },
            // Re-reading means rebuilding: the thresholds live in the machine, the prompt and
            // the model live in the client, and none of them is consulted again after start.
            onReloadConfig: { [weak self] in
                guard let self, let menu = self.statusMenu else { return }
                self.startBuild(menu: menu)
            }
        )
        statusMenu = menu
        menu.setStatus("Загружаю модель…")
        startBuild(menu: menu)
    }

    // A build already in flight is ignored rather than cancelled: `ParakeetTranscriber.load`
    // downloads and loads a model with no cancellation point of its own, so cancelling the task
    // would not actually stop the work in progress — it would just leave two builds racing to
    // finish, with no guarantee which coordinator survives. Ignoring keeps exactly one build
    // running at a time; the owner can retry the reload once it settles.
    private func startBuild(menu: StatusMenu) {
        guard buildTask == nil else { return }
        buildTask = Task { [weak self] in
            await self?.buildCoordinator(menu: menu)
            self?.buildTask = nil
        }
    }

    private func buildCoordinator(menu: StatusMenu) async {
        coordinator?.stop()
        coordinator = nil
        do {
            let config = try DictationConfig.loadOrCreate()
            // Loaded once and kept resident: 470 MB against 16 GB, and the alternative is
            // paying the load on every dictation, which is when waiting is least acceptable.
            let transcriber = try await ParakeetTranscriber.load(language: config.language)
            let cleaner = try DeepSeekClient.fromKeychain(
                model: config.model, prompt: config.prompt, timeout: config.timeoutSeconds
            )
            let coordinator = DictationCoordinator(
                config: config,
                recorder: MicrophoneRecorder(),
                transcriber: transcriber,
                cleaner: cleaner,
                inserter: TextInserter(),
                sounds: SoundPlayer(sounds: config.sounds),
                showPanel: { [panel] state in panel.show(state) },
                hidePanel: { [panel] delay in panel.hide(after: delay) },
                onLevel: { [panel] level in
                    // `onLevel` is `@Sendable`: DictationCoordinator already hops to the main
                    // queue before invoking it, so this is the same "known to be on the main
                    // actor, provably or not" situation the coordinator itself expresses with
                    // `MainActor.assumeIsolated` for its timer and key-event delivery.
                    MainActor.assumeIsolated {
                        panel.setLevel(level)
                    }
                }
            )
            try coordinator.start()
            self.coordinator = coordinator
            menu.setStatus("Готов")
        } catch {
            menu.setStatus(error.localizedDescription)
        }
    }
}
