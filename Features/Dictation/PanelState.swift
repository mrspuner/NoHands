import Foundation

/// What the panel is showing. Structure only — no wording: the interface speaks Russian and
/// that belongs to the `App` target, while everything here has to stay testable on its own.
public enum PanelState: Equatable, Sendable {
    case recording(target: TargetApp, latched: Bool)
    case transcribing(target: TargetApp)
    case cleaning(target: TargetApp)
    /// `cleanupSkipped` carries the reason cleanup did not happen, or nil when it did.
    case inserting(target: TargetApp, cleanupSkipped: String?)
    case failure(String)
}
