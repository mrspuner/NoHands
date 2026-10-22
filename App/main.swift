import AppKit
import Telegram

// The reply agent's Bash filter is this same binary, so the app's path in the hook is always the
// installed one. Checked before anything AppKit: a hook run is a short process with no UI.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--telegram-bash-hook" {
    BashGate.runHook()
}

// `.accessory` keeps the app out of the Dock and out of the app switcher: it lives in the
// menu bar. LSUIElement in Info.plist says the same thing to the launcher; this covers the
// case of running the binary directly during development.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
