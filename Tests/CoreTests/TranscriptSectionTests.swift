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
