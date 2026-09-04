import Foundation

/// What the panel shows while a meeting is being recorded. Structure only — no wording: the
/// interface speaks Russian and that belongs to the `App` target.
///
/// `acceptsClicks` is the whole reason this is an enum and not a pair of booleans: the panel
/// stays deaf to the mouse except while a prompt is up, and the rule for which states those
/// are must be testable without a window.
public enum MeetingPanelState: Equatable, Sendable {
    case startPrompt(appName: String)
    /// `confirmed` is false while the recording is still a draft nobody has answered for.
    case recording(since: Date, confirmed: Bool)
    case stopPrompt(duration: TimeInterval)
    case savePrompt(duration: TimeInterval)
    case orphanFound(duration: TimeInterval)
    case limitReached
    case failure(String)

    public var acceptsClicks: Bool {
        switch self {
        case .startPrompt, .stopPrompt, .savePrompt, .orphanFound: true
        case .recording, .limitReached, .failure: false
        }
    }
}
