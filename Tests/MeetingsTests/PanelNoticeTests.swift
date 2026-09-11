import Foundation
import Testing
@testable import Meetings

@Test func aFinishedMeetingSaysHowLongItWas() {
    let notice = PanelNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: 47, failure: nil)
    )
    #expect(notice.text == "Расшифровано, 47 мин")
    #expect(notice.isFailure == false)
}

// A meeting that was in fact processed must never read as zero minutes: `0` here means the
// duration rounded down from under thirty seconds, not that nothing happened.
@Test func aSubMinuteMeetingIsNotZeroMinutes() {
    let notice = PanelNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: 0, failure: nil)
    )
    #expect(notice.text == "Расшифровано, меньше минуты")
    #expect(notice.isFailure == false)
}

@Test func aFailureNamesItsReason() {
    let notice = PanelNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: nil, failure: "модель недоступна")
    )
    #expect(notice.text == "Не расшифровано: модель недоступна")
    #expect(notice.isFailure)
}

@Test func theDwellIsTheSameFiveSecondsAsEveryOtherNotice() {
    #expect(PanelNotice.dwell == MeetingMachine.noticeDwell)
}

// A failure outranks the duration: when both arrive, the failure is what gets said.
@Test func aFailureWinsOverMinutes() {
    let notice = PanelNotice.forOutcome(
        MeetingQueue.Outcome(folder: "x", minutes: 3, failure: "не удалось сжать")
    )
    #expect(notice.isFailure)
}

@Test func theSummaryNoticeSaysWhichWayItWent() {
    let good = PanelNotice.forSummary(MeetingSummarizer.Outcome(file: "a.md", failure: nil))
    #expect(good.text == "Конспект готов")
    #expect(!good.isFailure)

    let bad = PanelNotice.forSummary(
        MeetingSummarizer.Outcome(file: "a.md", failure: "uv not found at /x")
    )
    #expect(bad.text == "Конспект не сделан: uv not found at /x")
    #expect(bad.isFailure)
}

@Test func theNamingNoticeNamesWhoWasNamed() {
    let good = PanelNotice.forNaming(
        SpeakerNaming.Outcome(file: "a.md", named: ["Настя"], failure: nil)
    )
    #expect(good.text == "Названо: Настя")
    #expect(!good.isFailure)

    let bad = PanelNotice.forNaming(
        SpeakerNaming.Outcome(file: "", named: [], failure: "Книга голосов не читается")
    )
    #expect(bad.text == "Имя не сохранено: Книга голосов не читается")
    #expect(bad.isFailure)
}

// A merge renames two rows to the same name, and the notice should say it once.
@Test func theNamingNoticeDeduplicatesRepeatedNames() {
    let notice = PanelNotice.forNaming(
        SpeakerNaming.Outcome(file: "a.md", named: ["Настя", "Настя"], failure: nil)
    )
    #expect(notice.text == "Названо: Настя")
}
