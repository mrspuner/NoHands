import Foundation
import Testing
@testable import Core

private let file = """
---
date: 2026-09-09
participants: [Я, Собеседник]
---

## Саммари

- о чём-то договорились

## Транскрипт
[00:00:03] Собеседник: привет

"""

@Test func onlyTheTranscriptAndTheHeaderChange() throws {
    let transcript = [
        Utterance(speaker: .voice("v1"), start: 3, end: 5, text: "привет"),
        Utterance(speaker: .voice("v2"), start: 7, end: 9, text: "и вам"),
    ]
    let updated = try TranscriptSection.replace(
        in: file,
        transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]),
        named: "тест.md"
    )
    #expect(updated.contains("## Саммари\n"))
    #expect(updated.contains("- о чём-то договорились\n"))
    #expect(updated.contains("participants: [Собеседник 1, Собеседник 2]\n"))
    #expect(updated.contains("[00:00:03] Собеседник 1: привет\n"))
    #expect(updated.contains("[00:00:07] Собеседник 2: и вам\n"))
    #expect(!updated.contains("[00:00:03] Собеседник: привет\n"))
}

@Test func aFileWithoutATranscriptSectionIsRefused() {
    #expect(throws: (any Error).self) {
        try TranscriptSection.replace(
            in: "---\n---\n", transcript: [], labels: SpeakerLabels(order: [], names: [:], ownerSpoke: false),
            named: "тест.md"
        )
    }
}

// A file that has never had a `participants:` line — every meeting written before phase 2г —
// gets one rather than losing the header it does have.
@Test func aHeaderWithoutParticipantsGainsTheLine() throws {
    let old = "---\ndate: 2026-09-01\n---\n\n## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "раз")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]), named: "тест.md"
    )
    #expect(updated.contains("date: 2026-09-01\n"))
    #expect(updated.contains("participants: [Собеседник]\n"))
}

// `labels: nil` is what the caller passes when the diarizer itself found no real voices — a
// `SpeakerLabels` built from `VoiceAssignment`'s placeholder fallback would have a non-empty
// `order` (`["v1"]`) even though nothing was actually diarized, and that is exactly the false
// claim this parameter exists to refuse. No `participants:` line here to begin with, and none
// should appear — but the transcript itself is still rewritten.
@Test func noParticipantsLineIsAddedWhenThereAreNoRealVoices() throws {
    let old = "---\ndate: 2026-09-01\n---\n\n## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "два")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript, labels: nil, named: "тест.md"
    )
    #expect(!updated.contains("participants:"))
    #expect(updated.contains("[00:00:01] Собеседник: два\n"))
    #expect(!updated.contains("[00:00:01] Собеседник: раз\n"))
}

// The overwrite branch had no emptiness guard at all: a file already carrying a correct
// `participants:` line from an earlier good run, re-diarized into finding no real voices, must
// not have that line downgraded. That would be a permanent loss of knowledge from the archive —
// strictly worse than the missing-line case above, which only ever under-claims.
@Test func anExistingParticipantsLineSurvivesWhenThereAreNoRealVoices() throws {
    let old = "---\ndate: 2026-09-09\nparticipants: [Я, Настя]\n---\n\n"
        + "## Транскрипт\n[00:00:03] Настя: привет\n"
    let transcript = [Utterance(speaker: .me, start: 1, end: 2, text: "привет заново")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript, labels: nil, named: "тест.md"
    )
    #expect(updated.contains("participants: [Я, Настя]\n"))
    #expect(updated.contains("[00:00:01] Я: привет заново\n"))
    #expect(!updated.contains("[00:00:03] Настя: привет\n"))
}

@Test func applyingReplaceTwiceIsIdempotent() throws {
    let transcript = [
        Utterance(speaker: .voice("v1"), start: 3, end: 5, text: "привет"),
        Utterance(speaker: .voice("v2"), start: 7, end: 9, text: "и вам"),
    ]
    let labels = SpeakerLabels.make(transcript: transcript, names: [:])
    let once = try TranscriptSection.replace(
        in: file, transcript: transcript, labels: labels, named: "тест.md"
    )
    let twice = try TranscriptSection.replace(
        in: once, transcript: transcript, labels: labels, named: "тест.md"
    )
    #expect(once == twice)
    // No duplicated heading and no accumulated blank lines — either would still leave `once ==
    // twice` false, but naming the failure mode here makes a broken run diagnosable at a glance.
    #expect(twice.components(separatedBy: TranscriptIndex.heading).count == 2)
    #expect(!twice.contains("\n\n\n"))
}

// `## Транскрипт` as the very first line: nothing above it to preserve, and nowhere sensible to
// insert a `participants:` line — the front-matter-insertion branch requires a `---` first line,
// which this file does not have.
@Test func aFileWithNoFrontMatterKeepsTheHeadingFirst() throws {
    let old = "## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "два")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]), named: "тест.md"
    )
    #expect(updated.hasPrefix("## Транскрипт"))
    #expect(!updated.contains("participants:"))
    #expect(updated.contains("[00:00:01] Собеседник: два\n"))
}

// A meeting whose diarization failed carries a stale `speakers:` line. `diarize --write`
// succeeding later must retract that claim rather than leave it standing beside the new
// `participants:` — a file asserting both is a signal that reached only half its consumers, the
// exact shape `docs/DECISIONS.md` warns about for 2026-09-08.
@Test func aStaleSpeakersLineIsRemovedWhenDiarizationSucceeds() throws {
    let old = "---\ndate: 2026-09-09\n"
        + "speakers: \"не размечено — модель диаризации недоступна\"\n---\n\n"
        + "## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "раз")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]), named: "тест.md"
    )
    #expect(updated.contains("participants: [Собеседник]\n"))
    #expect(!updated.contains("speakers:"))
}

// `MeetingMarkdown.render` always writes `participants:` before `microphone:`. Inserting it
// after here, on a re-diarize, would make the file visibly different from one written fresh in
// one pass — the two paths must agree on where the line goes, not only on its content.
@Test func participantsIsInsertedBeforeMicrophoneRatherThanAfter() throws {
    let old = "---\ndate: 2026-09-09\n"
        + "microphone: \"молчал всю запись — дорожка пустая\"\n---\n\n"
        + "## Транскрипт\n[00:00:01] Собеседник: раз\n"
    let transcript = [Utterance(speaker: .voice("v1"), start: 1, end: 2, text: "раз")]
    let updated = try TranscriptSection.replace(
        in: old, transcript: transcript,
        labels: SpeakerLabels.make(transcript: transcript, names: [:]), named: "тест.md"
    )
    let lines = updated.components(separatedBy: "\n")
    guard let participantsIndex = lines.firstIndex(where: { $0.hasPrefix("participants:") }),
        let microphoneIndex = lines.firstIndex(where: { $0.hasPrefix("microphone:") })
    else {
        Issue.record("both lines were expected in the output")
        return
    }
    #expect(participantsIndex < microphoneIndex)
}
