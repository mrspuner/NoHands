import Foundation

/// The application a dictation is aimed at, captured when recording starts rather than when
/// the text is pasted.
///
/// Deliberately holds no `NSRunningApplication` and no icon: this type crosses into the state
/// machine, which must stay testable without AppKit. The panel looks the live application up
/// by `bundleIdentifier` when it needs the icon.
public struct TargetApp: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String

    public init(bundleIdentifier: String?, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}
