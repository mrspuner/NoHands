import Foundation

/// What the panel shows about the inbox. Structure only — no wording: the interface speaks
/// Russian and that belongs to the `App` target, while everything here stays testable on its own.
/// Same split, and the same reason, as `PanelState` and `MeetingPanelState`.
public enum InboxPanelState: Equatable, Sendable {
    /// A capture landed, and for as long as this is on screen the strip is a target for files.
    /// `attachments` counts what has already been copied into the folder.
    case captured(app: String?, lines: Int, attachments: Int)
    case failure(String)

    /// The strip takes the mouse only while something can be dropped on it — the same rule, and
    /// the same reason, as `MeetingPanelState.acceptsClicks`: a click the panel accepts is a
    /// click the window underneath does not get.
    public var acceptsDrop: Bool {
        switch self {
        case .captured: true
        case .failure: false
        }
    }
}
