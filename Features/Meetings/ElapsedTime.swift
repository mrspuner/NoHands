import Foundation

/// How long a recording has been running, in the two forms the interface needs.
///
/// Pure, and therefore not in the `App` target, for the reason `MenuTitle` is not either: it
/// depends on nothing but its input, it is wrong exactly at the boundaries nobody looks at —
/// the hour mark, a clock that jumped backwards — and where it would otherwise live there is
/// no way to test it. It carries digits, not words: the sentences around these numbers belong
/// to `App`.
public enum ElapsedTime {
    /// `12:34` under an hour, `1:02:03` from an hour on.
    ///
    /// Seconds and not just minutes: this is read while the recording runs, and a clock that
    /// only moves once a minute leaves the owner watching it to find out whether it is moving.
    public static func clock(_ seconds: TimeInterval) -> String {
        // A difference between two `Date`s can come out negative when the system clock is
        // corrected. "-0:03" would read as a defect; nothing has been recorded yet is the truth.
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Whole minutes, rounded to the nearest, for the prompts asking what to do with a
    /// recording that has already stopped. Seconds are noise at that point, and rounding down
    /// would call a minute and a half one minute.
    public static func minutes(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) / 60).rounded())
    }
}
