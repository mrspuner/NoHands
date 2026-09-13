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
            Utterance(speaker: .voice("v1"), start: 3, end: 6, text: "привет"),
            Utterance(speaker: .me, start: 11, end: 13, text: "привет и тебе"),
        ],
        startedAt: started,
        durationSeconds: 254,
        appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.hasPrefix("---\n"))
    #expect(rendered.contains("duration: 4m\n"))
    #expect(rendered.contains("app: \"Телемост\"\n"))
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
        startedAt: started, durationSeconds: 60, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(!rendered.contains("participants"))
}

// The other half of what this phase deliberately does not write. Nothing but a test can hold
// this line: a TODO comment was ruled out, so a later change reintroducing these headings here
// would otherwise go unnoticed until phase 2в wrote them a second time.
@Test func summaryAndDecisionsAreNotWritten() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(!rendered.contains("Саммари"))
    #expect(!rendered.contains("Решения"))
}

// `MeetingQueue.sweep` сносит папку очереди целиком — вместе с `meeting.json`, где немота
// дорожки записана числом, — как только встреча старше `audioRetentionDays`, то есть семи дней.
// Через полгода от встречи остаётся ровно markdown в `~/Meetings`, и объяснять файл без единой
// реплики «Я» приходится ему.
@Test func aSilentMicrophoneIsExplainedInTheFrontMatter() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 5580, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: 600,
        microphoneSawAudio: true,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains(#"microphone: "замолчал в конце — 10 мин тишины, дорожка неполная""#))
}

// Ровно тот случай, ради которого заведена эта ветка: встреча на 93 минуты, 438 чужих реплик и
// ни одной своей. Панель говорит «молчал всю запись», а файл говорил «замолчал в конце» — то
// есть утверждал, что микрофон работал, и обещал неполную дорожку там, где её нет вовсе. Из двух
// артефактов врал тот, который переживает всё остальное.
@Test func aTrackThatNeverCarriedAudioIsCalledEmptyRatherThanIncomplete() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 5580, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: 5580,
        microphoneSawAudio: false,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains(#"microphone: "молчал всю запись — дорожка пустая""#))
    #expect(!rendered.contains("неполная"))
}

// Папка, записанная до того, как признак начали мерить. Известно ровно одно число, и назвать
// дорожку пустой или неполной значило бы угадать — то есть повторить ту же ошибку в новом месте.
@Test func anUnknownFlagClaimsNeitherEmptyNorIncomplete() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 5580, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: 600,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains(#"microphone: "тишина — 10 мин, полнота дорожки неизвестна""#))
    #expect(!rendered.contains("пустая"))
    #expect(!rendered.contains("неполная"))
}

// Обычная встреча этой строки не несёт: ключ, стоящий всегда, был бы утверждением о каждой
// записи, а утверждать тут нечего.
@Test func anOrdinaryMeetingCarriesNoMicrophoneLine() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 5580, appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: true,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(!rendered.contains("microphone:"))
}

// Та же беда, что у `duration`, и то же лечение: округление до минут уводит всё, что меньше
// тридцати секунд, в ноль, а «0 мин тишины» отрицало бы тишину и объявляло дорожку неполной
// одной строкой — навсегда, в файле, который владелец хранит.
@Test func aSubMinuteSilenceIsNotZeroMinutes() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 5580, appName: nil,
        trailingMicrophoneSilenceSeconds: 15,
        microphoneSawAudio: true,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains(#"microphone: "замолчал в конце — меньше минуты тишины, дорожка неполная""#))
    #expect(!rendered.contains("0 мин"))
}

// The application name comes from `NSRunningApplication`, so it is outside this code's control.
@Test func anApplicationNameCannotBreakTheFrontMatter() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60,
        appName: "Zoom: \"Meetings\"\nfake: value",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    // The injected text survives as data inside the quoted value, and that is fine — what must
    // not happen is it becoming a key of its own, which is exactly what the unescaped newline
    // would have made it.
    let frontMatter = rendered.components(separatedBy: "---")[1]
    let lines = frontMatter.split(separator: "\n")
    #expect(!lines.contains { $0.hasPrefix("fake:") })
    #expect(lines.contains { $0 == #"app: "Zoom: \"Meetings\"fake: value""# })
}

@Test func anUnknownApplicationLeavesTheLineOut() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(!rendered.contains("app:"))
}

// A meeting that was in fact recorded must never round down to zero in the archive's own front
// matter — that would misreport a real recording as nothing, permanently.
@Test func aSubMinuteMeetingIsNotZeroMinutes() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 20, appName: nil,
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains("duration: 1m\n"))
}

@Test func durationOverAnHourIsStillMinutes() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .me, start: 0, end: 1, text: "раз")],
        startedAt: started, durationSeconds: 4320, appName: nil,
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: nil
    )
    #expect(rendered.contains("duration: 72m\n"))
}

@Test func participantsAreWrittenWhenVoicesAreKnown() {
    let transcript = [
        Utterance(speaker: .voice("v1"), start: 3, end: 6, text: "привет"),
        Utterance(speaker: .me, start: 11, end: 13, text: "привет и тебе"),
        Utterance(speaker: .voice("v2"), start: 15, end: 18, text: "и вам"),
    ]
    let rendered = MeetingMarkdown.render(
        transcript: transcript,
        startedAt: started,
        durationSeconds: 254,
        appName: "Телемост",
        trailingMicrophoneSilenceSeconds: nil,
        microphoneSawAudio: nil,
        labels: SpeakerLabels.make(transcript: transcript, names: ["v1": "Настя"]),
        diarizationFailure: nil
    )
    #expect(rendered.contains("participants: [Я, Настя, Собеседник 2]\n"))
    #expect(rendered.contains("[00:00:03] Настя: привет\n"))
    #expect(rendered.contains("[00:00:15] Собеседник 2: и вам\n"))
}

// A name with a comma or a bracket would break the list for anything that re-reads the file,
// and this value comes from whatever the owner typed.
@Test func awkwardNamesAreQuotedInTheList() {
    let transcript = [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")]
    let rendered = MeetingMarkdown.render(
        transcript: transcript,
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: SpeakerLabels.make(transcript: transcript, names: ["v1": "Настя, она же Настасья"]),
        diarizationFailure: nil
    )
    #expect(rendered.contains("participants: [\"Настя, она же Настасья\"]\n"))
}

// A refusal is named in the file that outlives everything, exactly as a refused cleanup is
// named on the panel: the silence about it would be the defect.
@Test func aRefusedDiarizationIsNamedAndClaimsNoParticipants() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")],
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: nil,
        diarizationFailure: "модель диаризации недоступна"
    )
    #expect(!rendered.contains("participants:"))
    #expect(rendered.contains("speakers: \"не размечено — модель диаризации недоступна\"\n"))
    #expect(rendered.contains("[00:00:00] Собеседник: …\n"))
}

@Test func withoutLabelsAndWithoutFailureTheFileIsAsPhase2bWroteIt() {
    let rendered = MeetingMarkdown.render(
        transcript: [Utterance(speaker: .voice("v1"), start: 0, end: 1, text: "…")],
        startedAt: started, durationSeconds: 60, appName: nil,
        trailingMicrophoneSilenceSeconds: nil, microphoneSawAudio: nil,
        labels: nil, diarizationFailure: nil
    )
    #expect(!rendered.contains("participants:"))
    #expect(!rendered.contains("speakers:"))
    #expect(rendered.contains("[00:00:00] Собеседник: …\n"))
}
