import AppKit
import Dictation

/// The menu bar item and its menu.
///
/// The icon never changes: the panel is what reports what dictation is doing, and an icon that
/// blinks in a place the owner is not looking would be noise. The menu exists for the things
/// that have no other home — the config file and the permissions.
@MainActor
final class StatusMenu {
    private let item: NSStatusItem
    private let statusLine: NSMenuItem

    init(onQuit: @escaping () -> Void, onReloadConfig: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NoHands")
        icon?.isTemplate = true
        item.button?.image = icon

        statusLine = NSMenuItem(title: "Проверяю…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Открыть конфиг", action: #selector(Actions.openConfig), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(
            withTitle: "Перечитать конфиг", action: #selector(Actions.reloadConfig), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(
            withTitle: "Проверить разрешения", action: #selector(Actions.checkPermissions), keyEquivalent: ""
        ).target = Actions.shared
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Выход", action: #selector(Actions.quit), keyEquivalent: "q")
        quit.target = Actions.shared
        Actions.shared.onQuit = onQuit
        Actions.shared.onReloadConfig = onReloadConfig

        item.menu = menu
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    /// Menu targets have to be Objective-C objects; keeping them on one small class keeps that
    /// requirement from leaking into everything else.
    @MainActor
    final class Actions: NSObject {
        static let shared = Actions()
        var onQuit: (() -> Void)?
        var onReloadConfig: (() -> Void)?

        @objc func openConfig() {
            NSWorkspace.shared.open(DictationConfig.fileURL)
        }

        @objc func reloadConfig() {
            onReloadConfig?()
        }

        /// Passing the prompt option opens the system dialog when the permission has not been
        /// granted — the only way to get there without walking the owner through Settings.
        ///
        /// The key is spelled out instead of read from `kAXTrustedCheckOptionPrompt`: that
        /// global is imported as `Unmanaged<CFString>` and Swift 6 flags any reference to it as
        /// concurrency-unsafe shared mutable state, on any actor. The string is documented and
        /// stable — it is the whole content of that constant.
        @objc func checkPermissions() {
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }

        @objc func quit() {
            onQuit?()
            NSApplication.shared.terminate(nil)
        }
    }
}
