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
    private let recentDelegate: RecentMenuDelegate

    init(
        recent: RecentDictations,
        onQuit: @escaping () -> Void,
        onReloadConfig: @escaping () -> Void
    ) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NoHands")
        icon?.isTemplate = true
        item.button?.image = icon

        statusLine = NSMenuItem(title: "Проверяю…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false

        recentDelegate = RecentMenuDelegate(recent: recent)
        let recentMenu = NSMenu()
        // Rebuilt every time it opens, so it never shows a stale list.
        recentMenu.delegate = recentDelegate
        let recentItem = NSMenuItem(title: "Последние диктовки", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(recentItem)
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

    /// Fills the recent-dictations submenu when it opens. A separate object because
    /// `NSMenuDelegate` needs an Objective-C class, and because this one owns the store while
    /// `Actions` owns the singleton callbacks.
    @MainActor
    final class RecentMenuDelegate: NSObject, NSMenuDelegate {
        private let recent: RecentDictations

        init(recent: RecentDictations) {
            self.recent = recent
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let entries = recent.entries()
            guard !entries.isEmpty else {
                let empty = NSMenuItem(title: "пока ничего", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            for entry in entries {
                // Without this the rough text of a failed cleanup looks like a recognition bug.
                let suffix = entry.wasCleaned ? "" : " · без чистки"
                let item = NSMenuItem(
                    title: MenuTitle.short(entry.inserted) + suffix,
                    action: #selector(copyEntry(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                // The menu shows a shortened line; the clipboard gets the whole thing.
                item.representedObject = entry.inserted
                menu.addItem(item)
            }
        }

        @objc private func copyEntry(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
