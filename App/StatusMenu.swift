import AppKit
import Dictation
import Meetings

/// The menu bar item and its menu.
///
/// The icon never changes, meetings included: the panel is what reports what is going on, and
/// an icon that blinks in a place the owner is not looking would be noise. The menu exists for
/// the things that have no other home — the config file, the permissions, and starting or
/// stopping a recording by hand.
@MainActor
final class StatusMenu {
    private let item: NSStatusItem
    private let statusLine: NSMenuItem
    /// Starts a meeting or stops the one being recorded — one item, because the two are never
    /// both on offer, and an item that is sometimes greyed says more about why than a second
    /// item that is sometimes missing.
    private let meetingItem: NSMenuItem
    private let screenRecordingItem: NSMenuItem
    private let meetingActivity: () -> MeetingCoordinator.Activity?
    // `NSMenu.delegate` is weak; without a strong reference here the delegate would be
    // deallocated right after `init` and the submenu would silently stop populating.
    private let recentDelegate: RecentMenuDelegate
    private var openDelegate: MenuOpenDelegate?

    /// - Parameter meetingActivity: what the meeting coordinator is doing, or nil while there
    ///   is no coordinator — a config that could not be read leaves the feature without one,
    ///   and the item has to say so rather than offer a recording nobody would make.
    init(
        recent: RecentDictations,
        meetingActivity: @escaping () -> MeetingCoordinator.Activity?,
        onStartMeeting: @escaping () -> Void,
        onStopMeeting: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onReloadConfig: @escaping () -> Void
    ) {
        self.meetingActivity = meetingActivity
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NoHands")
        icon?.isTemplate = true
        item.button?.image = icon

        statusLine = NSMenuItem(title: "Проверяю…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false

        meetingItem = NSMenuItem(
            title: "Записать созвон", action: #selector(Actions.startMeeting), keyEquivalent: ""
        )
        meetingItem.target = Actions.shared
        screenRecordingItem = NSMenuItem(
            title: "Разрешить запись экрана…",
            action: #selector(Actions.openScreenRecordingSettings),
            keyEquivalent: ""
        )
        screenRecordingItem.target = Actions.shared

        recentDelegate = RecentMenuDelegate(recent: recent)
        let recentMenu = NSMenu()
        // Rebuilt every time it opens, so it never shows a stale list.
        recentMenu.delegate = recentDelegate
        let recentItem = NSMenuItem(title: "Последние диктовки", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(meetingItem)
        menu.addItem(screenRecordingItem)
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
        Actions.shared.onStartMeeting = onStartMeeting
        Actions.shared.onStopMeeting = onStopMeeting

        item.menu = menu
        // Assigned after every stored property, which is the earliest `self` may be captured.
        openDelegate = MenuOpenDelegate { [weak self] in self?.refreshMeetingItems() }
        menu.delegate = openDelegate
        refreshMeetingItems()
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    /// Brings the two items that go stale between openings up to date: what there is to do
    /// about meetings, and whether the screen recording permission is still missing.
    ///
    /// Recomputed when the menu opens, because that is when it is read. The elapsed time in
    /// "остановить запись" therefore stands still in a menu left hanging open — the alternative
    /// is a timer rewriting a title once a second all day for the seconds anyone is looking.
    private func refreshMeetingItems() {
        switch meetingActivity() {
        case .recording(let since):
            meetingItem.title =
                "Остановить запись (\(ElapsedTime.clock(Date().timeIntervalSince(since))))"
            meetingItem.action = #selector(Actions.stopMeeting)
            meetingItem.isEnabled = true
        case .ready:
            meetingItem.title = "Записать созвон"
            meetingItem.action = #selector(Actions.startMeeting)
            meetingItem.isEnabled = true
        // A prompt on the panel owns the decision, or there is no coordinator at all. Either
        // way pressing this would do nothing, and an item that silently does nothing is worse
        // than a greyed one.
        case .awaitingAnswer, nil:
            meetingItem.title = "Записать созвон"
            meetingItem.action = nil
            meetingItem.isEnabled = false
        }
        // Hidden rather than greyed once the permission is there: an item offering to grant
        // what is already granted is a standing reminder of a solved problem.
        screenRecordingItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    /// Menu targets have to be Objective-C objects; keeping them on one small class keeps that
    /// requirement from leaking into everything else.
    @MainActor
    final class Actions: NSObject {
        static let shared = Actions()
        var onQuit: (() -> Void)?
        var onReloadConfig: (() -> Void)?
        var onStartMeeting: (() -> Void)?
        var onStopMeeting: (() -> Void)?

        @objc func openConfig() {
            NSWorkspace.shared.open(DictationConfig.fileURL)
        }

        @objc func reloadConfig() {
            onReloadConfig?()
        }

        @objc func startMeeting() {
            onStartMeeting?()
        }

        @objc func stopMeeting() {
            onStopMeeting?()
        }

        /// Straight to the list, without asking for the permission first. The system prompt
        /// appears by itself the first time a recording actually starts, and it is what puts
        /// this application into that list; by the time anyone reaches for this item, the
        /// answer they need to change is already in there.
        @objc func openScreenRecordingSettings() {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) else { return }
            NSWorkspace.shared.open(url)
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

    /// Runs one closure whenever the menu is about to be shown. A separate object for the same
    /// reason as the one below: `NSMenuDelegate` needs an Objective-C class.
    @MainActor
    final class MenuOpenDelegate: NSObject, NSMenuDelegate {
        private let onOpen: () -> Void

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            onOpen()
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
