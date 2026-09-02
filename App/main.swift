import AppKit

// `.accessory` keeps the app out of the Dock and out of the app switcher: it lives in the
// menu bar. LSUIElement in Info.plist says the same thing to the launcher; this covers the
// case of running the binary directly during development.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
