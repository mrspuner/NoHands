import Foundation
import Testing
@testable import Meetings

@Test func aFinishedMeetingSaysHowLongItWas() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: 47, failure: nil)
    )
    #expect(notice.text == "Расшифровано, 47 мин")
    #expect(notice.isFailure == false)
}

// A meeting that was in fact processed must never read as zero minutes: `0` here means the
// duration rounded down from under thirty seconds, not that nothing happened.
@Test func aSubMinuteMeetingIsNotZeroMinutes() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: 0, failure: nil)
    )
    #expect(notice.text == "Расшифровано, меньше минуты")
    #expect(notice.isFailure == false)
}

@Test func aFailureNamesItsReason() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "2026-09-04-1053-telemost", minutes: nil, failure: "модель недоступна")
    )
    #expect(notice.text == "Не расшифровано: модель недоступна")
    #expect(notice.isFailure)
}

@Test func theDwellIsTheSameFiveSecondsAsEveryOtherNotice() {
    #expect(MeetingNotice.dwell == MeetingMachine.noticeDwell)
}

// A failure outranks the duration: when both arrive, the failure is what gets said.
@Test func aFailureWinsOverMinutes() {
    let notice = MeetingNotice.forOutcome(
        MeetingQueue.Outcome(folder: "x", minutes: 3, failure: "не удалось сжать")
    )
    #expect(notice.isFailure)
}
