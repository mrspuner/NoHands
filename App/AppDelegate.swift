import AppKit
import Core
import Dictation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenu(onQuit: {}, onReloadConfig: { [weak self] in
            self?.statusMenu?.setStatus(self?.readiness() ?? "")
        })
        statusMenu = menu
        menu.setStatus(readiness())
    }

    /// One line the owner can read at a glance when dictation does not work. Both causes are
    /// things only they can fix, and both are invisible otherwise.
    private func readiness() -> String {
        if !AXIsProcessTrusted() {
            return "Нет разрешения на управление компьютером"
        }
        let key = try? Keychain.password(
            service: Keychain.deepSeekService, account: Keychain.deepSeekAccount
        )
        if key == nil {
            return "Нет ключа DeepSeek в связке ключей"
        }
        return "Готов"
    }
}
