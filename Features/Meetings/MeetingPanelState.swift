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
    /// A recording ended and was kept, on any of the paths that end one — not only the length
    /// limit, which already names itself through `.limitReached` above.
    case saved(duration: TimeInterval)
    /// A recording ended and was thrown away — a "no" on the start prompt, or an explicit
    /// "Удалить" on either of the save/stop prompts.
    case deleted

    public var acceptsClicks: Bool {
        switch self {
        case .startPrompt, .stopPrompt, .savePrompt, .orphanFound: true
        case .recording, .limitReached, .failure, .saved, .deleted: false
        }
    }
}
