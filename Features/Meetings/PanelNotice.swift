import Foundation

/// One line the panel says about something that has already happened.
///
/// Not only about meetings, despite living in this module: a switched input device reports
/// itself the same way. Kept here rather than moved to `Core` because `App` — the only place
/// that draws it — already depends on this module, and `Core` has no notion of a panel.
public struct PanelNotice: Equatable, Sendable {
    public var text: String
    /// Red text instead of secondary. The backing stays grey either way — only something
    /// waiting for an answer glows, and this asks nothing.
    public var isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }

    /// The same five seconds every other notice on this panel gets. Re-exported rather than
    /// duplicated: `MeetingMachine.noticeDwell` is internal to this module, and the `App` target
    /// needs a number to pass to `hideNotice(after:)`.
    public static let dwell: TimeInterval = MeetingMachine.noticeDwell

    public static func forOutcome(_ outcome: MeetingQueue.Outcome) -> PanelNotice {
        if let failure = outcome.failure {
            return PanelNotice(text: "Не расшифровано: \(failure)", isFailure: true)
        }
        // `minutes` is set on every path that has no failure — the two are written together in
        // `MeetingQueue.run`. The fallback exists because the type cannot say so, not because a
        // meeting of zero minutes is a thing this can report.
        return PanelNotice(text: "Расшифровано, \(Self.length(outcome.minutes ?? 0))", isFailure: false)
    }

    /// Same rule as `MeetingContent.length` in `PanelView`, restated here because `App` depends
    /// on `Meetings` and not the other way round: a meeting that was in fact processed must never
    /// read as zero minutes. The minutes passed in are already rounded to the nearest whole
    /// minute, so `0` here means under thirty seconds, not nothing.
    ///
    /// Not `private`: `MeetingCoordinator`'s silence sentence needs the exact same rule — a
    /// microphone dropout that really happened must not round to "0 мин" either — and it lives
    /// in this module, so it shares this implementation instead of carrying a third copy of the
    /// same ternary.
    static func length(_ minutes: Int) -> String {
        minutes < 1 ? "меньше минуты" : "\(minutes) мин"
    }

    /// The summary arrives a couple of minutes after the transcription notice, as a second
    /// notice rather than a rewrite of the first: the two are different events with different
    /// ways of failing, and one merged line would be wrong half the time.
    public static func forSummary(_ outcome: MeetingSummarizer.Outcome) -> PanelNotice {
        if let failure = outcome.failure {
            return PanelNotice(text: "Конспект не сделан: \(failure)", isFailure: true)
        }
        return PanelNotice(text: "Конспект готов", isFailure: false)
    }

    /// `SpeakerNaming`'s outcome. A failure here is the one place a broken voice book ever
    /// reaches the owner — the meeting pipeline deliberately stays silent about it rather than
    /// risk overwriting it, so this notice is what tells the owner the book needs attention.
    public static func forNaming(_ outcome: SpeakerNaming.Outcome) -> PanelNotice {
        if let failure = outcome.failure {
            return PanelNotice(text: "Имя не сохранено: \(failure)", isFailure: true)
        }
        // Deduplicated rather than joined as-is: renaming two rows to the same name, the way a
        // split voice is repaired, would otherwise say "Названо: Настя, Настя".
        var seen = Set<String>()
        let unique = outcome.named.filter { seen.insert($0).inserted }
        return PanelNotice(text: "Названо: \(unique.joined(separator: ", "))", isFailure: false)
    }
}
