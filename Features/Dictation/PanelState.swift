import Foundation

/// What the panel is showing. Structure only — no wording: the interface speaks Russian and
/// that belongs to the `App` target, while everything here has to stay testable on its own.
///
/// Carries no target application. The text goes wherever focus is when it is pasted, so the
/// panel shows the live frontmost application, which the `App` target tracks itself — see the
/// decisions log for 2026-09-03.
public enum PanelState: Equatable, Sendable {
    case recording(latched: Bool)
    case transcribing
    case cleaning
    /// `cleanupSkipped` carries the reason cleanup did not happen, or nil when it did.
    case inserting(cleanupSkipped: String?)
    case failure(String)
    /// fn was pressed while a meeting is being recorded: dictation refused to start.
    case blocked
}
