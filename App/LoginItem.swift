import Foundation
import OSLog
import ServiceManagement

/// Adds the app to Login Items the first time it runs from `/Applications`.
///
/// Only the installed copy registers: `SMAppService.mainApp` records the path of whichever
/// bundle calls it, and a copy launched from `build/` would put that path into Login Items.
/// Only `.notRegistered` registers: once the owner switches the item off in System Settings,
/// the status stops being that, and the app does not switch it back on every launch.
enum LoginItem {
    private static let log = Logger(subsystem: "com.nohands.app", category: "login-item")

    @MainActor
    static func registerIfInstalled() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        let service = SMAppService.mainApp
        guard service.status == .notRegistered else { return }
        do {
            try service.register()
        } catch {
            log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
