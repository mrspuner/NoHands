import AppKit
import Foundation

/// Who was in front when the hotkey fired, and — when that was a browser — what page they were
/// looking at.
public struct InboxSource: Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var url: String?

    public init(appName: String?, bundleID: String?, url: String?) {
        self.appName = appName
        self.bundleID = bundleID
        self.url = url
    }

    public var slug: String {
        InboxFolder.slug(forBundleID: bundleID ?? "")
    }
}

/// Reads the frontmost application, and its address when it has one.
@MainActor
public enum FrontmostSource {
    /// Bundle identifiers worth asking for an address, and the script that asks each one.
    ///
    /// A closed list rather than an attempt on everything: every ask raises the automation
    /// consent dialog for that application the first time, and an application that has no
    /// notion of a front document would collect a dialog for nothing.
    static let browsers: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
        "com.google.Chrome":
            "tell application \"Google Chrome\" to return URL of active tab of front window",
    ]

    public static func read() -> InboxSource {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        return InboxSource(
            appName: app?.localizedName,
            bundleID: bundleID,
            url: bundleID.flatMap(address(ofBundleID:))
        )
    }

    /// nil rather than an error on every refusal, and that is the whole permission story of this
    /// feature: the first ask raises "NoHands wants to control Safari", and a denied one has to
    /// cost the capture nothing — the note simply has no `url` line. Unlike the microphone, the
    /// screen and accessibility, this permission is not required for the feature to work.
    static func address(ofBundleID bundleID: String) -> String? {
        guard let script = browsers[bundleID] else { return nil }
        var error: NSDictionary?
        let value = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard error == nil, let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
