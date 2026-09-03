import Foundation

/// Whether showing a new panel state should reset the level-bar history.
///
/// Pure decision, deliberately pulled out of `PanelWindow` (an `NSPanel` wrapper in the
/// `App` target, which has no test target of its own) the same way the swallow rule was pulled
/// out of the event tap, the narrowband predicate out of the device query, and the level
/// arithmetic out of the recorder. Each of those turned out to be exactly where a defect lived.
public enum PanelTransition: Equatable, Sendable {
    case showResettingLevels
    case showKeepingLevels

    /// The level history reads as a voice only within one dictation; carrying it into the next
    /// would show bars for speech that already ended. Reset exactly when a fresh recording
    /// begins — `next` is `.recording` and `previous` was not, which includes there being no
    /// previous state at all. Every other transition keeps the history, in particular
    /// `.recording` into `.recording` (latching re-announces the same state) and any step of
    /// one dictation's own pipeline running into the next.
    public static func transition(from previous: PanelState?, to next: PanelState) -> PanelTransition {
        guard case .recording = next else { return .showKeepingLevels }
        if case .recording = previous { return .showKeepingLevels }
        return .showResettingLevels
    }
}
