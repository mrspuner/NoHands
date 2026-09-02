import CoreGraphics
import Foundation

public enum KeyEventKind: Equatable, Sendable {
    case fnDown
    case fnUp
    case spaceDown
    case escapeDown
}

/// Turns a raw keyboard event into one of the four things dictation cares about.
///
/// Separated from the tap so the one rule that is easy to get wrong is testable without a
/// keyboard, a run loop or the accessibility permission.
public enum KeyEventReader {
    /// `kVK_Function`. fn is not an ordinary modifier: `RegisterEventHotKey` cannot bind it,
    /// and the `.maskSecondaryFn` flag it sets is also set by arrow keys, the F row, Home, End
    /// and both Page keys. The key code in a `flagsChanged` event is the only thing that
    /// identifies the physical fn key.
    public static let fnKeyCode: Int64 = 63
    /// `kVK_Space`
    public static let spaceKeyCode: Int64 = 49
    /// `kVK_Escape`
    public static let escapeKeyCode: Int64 = 53

    public static func kind(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> KeyEventKind? {
        switch type {
        case .flagsChanged where keyCode == fnKeyCode:
            return flags.contains(.maskSecondaryFn) ? .fnDown : .fnUp
        case .keyDown where keyCode == spaceKeyCode:
            return .spaceDown
        case .keyDown where keyCode == escapeKeyCode:
            return .escapeDown
        default:
            return nil
        }
    }

    /// Whether the tap must eat this key rather than pass it through.
    ///
    /// `space` and `escape` are the machine's own intent, mirrored into the tap by the
    /// coordinator. Space also swallows on the event's own fn flag, with no memory of fn's
    /// up/down state needed: `maskSecondaryFn` on a `keyDown` for key code 49 has no other
    /// source — the aliasing this type exists to filter out (arrows, the F row, Home/End,
    /// Page Up/Down) sets the flag on those keys' own events, never on space's — so this
    /// reads directly from the event and cannot go stale the way a separately tracked flag can
    /// if an fn-up is ever missed.
    public static func shouldSwallow(_ kind: KeyEventKind, flags: CGEventFlags, space: Bool, escape: Bool) -> Bool {
        switch kind {
        case .fnDown, .fnUp:
            return false
        case .spaceDown:
            return flags.contains(.maskSecondaryFn) || space
        case .escapeDown:
            return escape
        }
    }
}
