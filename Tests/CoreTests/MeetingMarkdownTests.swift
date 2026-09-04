import Foundation
import Testing
@testable import Core

private let started = Date(timeIntervalSince1970: 1_788_500_000)  // a fixed moment

@Test func timestampsAreHoursMinutesSeconds() {
    #expect(MeetingMarkdown.timestamp(0) == "00:00:00")
    #expect(MeetingMarkdown.timestamp(3) == "00:00:03")
    #expect(MeetingMarkdown.timestamp(192) == "00:03:12")
    #expect(MeetingMarkdown.timestamp(3725) == "01:02:05")
}

@Test func theFileCarriesFrontMatterAndATranscript() {
    let rendered = MeetingMarkdown.render(
        transcript: [
            Utterance(speaker: .others, start: 3, end: 6, text: "привет"),
            Utterance(speaker: .me, start: 11, end: 13, text: "привет и тебе"),
        ],
        startedAt: started,
        durationSeconds: 254,
        appName: "Телемост"
    )
    #expect(rendered.hasPrefix("---\n"))
    #expect(rendered.contains("duration: 4m\n"))
    #expect(rendered.contains("app: Телемост\n"))
    #expect(rendered.contains("## Транскрипт\n"))
    #expect(rendered.contains("[00:00:03] Собеседник: привет\n"))
    #expect(rendered.contains("[00:00:11] Я: привет и тебе\n"))
}

// Phase 2б does not know how many people are in the meeting or their names. The `participants`
// line will appear in 2г along with the names; writing it now would claim knowledge that does
// not exist yet.
@Test func participantsAreNotWritten() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: "Телемост"
    )
    #expect(!rendered.contains("participants"))
}

@Test func anUnknownApplicationLeavesTheLineOut() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: nil
    )
    #expect(!rendered.contains("app:"))
}

@Test func durationOverAnHourIsStillMinutes() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 4320, appName: nil
    )
    #expect(rendered.contains("duration: 72m\n"))
}
