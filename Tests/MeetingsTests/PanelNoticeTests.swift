import Core
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

private func ingestNotice(_ failure: AgentFailure?, file: String = "2026-10-19-1430-telemost.md") -> PanelNotice? {
    PanelNotice.forIngest(MeetingIngest.Outcome(file: file, failure: failure.map { .agent($0) }))
}

// Success is visible in BigHead itself; the panel stays quiet about it.
@Test func aHandedOverMeetingSaysNothing() {
    #expect(ingestNotice(nil) == nil)
}

@Test func anIngestExitCodeIsNamed() {
    #expect(ingestNotice(.exitCode(1, reason: nil)) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: код выхода 1", isFailure: true))
}

@Test func anIngestExitCodeCarriesTheTerminalReasonWhenThereIsOne() {
    #expect(ingestNotice(.exitCode(1, reason: "api_error")) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: код выхода 1 (api_error)", isFailure: true))
}

@Test func anIngestTimeoutIsInMinutes() {
    #expect(ingestNotice(.timedOut(900)) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: не уложился в 15 мин", isFailure: true))
}

@Test func anIngestAgentErrorCarriesTheTerminalReason() {
    #expect(ingestNotice(.agentError("api_error")) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: ошибка claude: api_error", isFailure: true))
}

@Test func anUnreadableIngestResultIsNamed() {
    #expect(ingestNotice(.unreadableResult) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: непонятный ответ claude", isFailure: true))
}

@Test func anIngestLaunchFailureIsNamed() {
    #expect(ingestNotice(.launchFailed("no such file")) == PanelNotice(
        text: "Созвон 2026-10-19-1430-telemost.md не обработан: не запустился: no such file", isFailure: true))
}

// A broken state file belongs to no meeting, so the line names the feature instead.
@Test func aBrokenIngestStateNamesTheFeature() {
    #expect(PanelNotice.forIngest(MeetingIngest.Outcome(file: "", failure: .stateUnreadable)) == PanelNotice(
        text: "Созвоны → Башка: файл состояния не читается, передача остановлена", isFailure: true))
}

// The agent ran and BigHead has the file; only the mark is missing. "Не обработан" would be false.
@Test func anUnsavedMarkSaysTheMeetingWasHandedOver() {
    #expect(PanelNotice.forIngest(MeetingIngest.Outcome(file: "2026-10-19-1430-telemost.md", failure: .notMarked))
        == PanelNotice(
            text: "Созвон 2026-10-19-1430-telemost.md передан, но не отмечен: состояние не сохранилось — "
                + "передастся снова при следующем запуске",
            isFailure: true))
}
