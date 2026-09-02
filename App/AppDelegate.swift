import AppKit
import Core
import Dictation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    private var coordinator: DictationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(
            onQuit: { [weak self] in self?.coordinator?.stop() },
            // Re-reading means rebuilding: the thresholds live in the machine, the prompt and
            // the model live in the client, and none of them is consulted again after start.
            onReloadConfig: { [weak self] in
                guard let self, let menu = self.statusMenu else { return }
                Task { await self.buildCoordinator(menu: menu) }
            }
        )
        statusMenu = menu
        menu.setStatus("Загружаю модель…")
        Task { await self.buildCoordinator(menu: menu) }
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
                showPanel: { _ in },
                hidePanel: { _ in },
                onLevel: { _ in }
            )
            try coordinator.start()
            self.coordinator = coordinator
            menu.setStatus("Готов")
        } catch {
            menu.setStatus(error.localizedDescription)
        }
    }
}
