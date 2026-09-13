import Foundation
import Testing
@testable import Core

private func said(_ speaker: Utterance.Speaker, _ start: Double) -> Utterance {
    Utterance(speaker: speaker, start: start, end: start + 1, text: "…")
}

@Test func aLoneVoiceIsJustTheInterlocutor() {
    let labels = SpeakerLabels.make(transcript: [said(.voice("v1"), 0), said(.me, 2)], names: [:])
    #expect(labels.label(for: .voice("v1")) == "Собеседник")
    #expect(labels.label(for: .me) == "Я")
    #expect(labels.participants == ["Я", "Собеседник"])
}

@Test func severalVoicesAreNumberedByFirstAppearance() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v2"), 0), said(.me, 1), said(.voice("v1"), 2)], names: [:]
    )
    #expect(labels.label(for: .voice("v2")) == "Собеседник 1")
    #expect(labels.label(for: .voice("v1")) == "Собеседник 2")
    #expect(labels.participants == ["Я", "Собеседник 1", "Собеседник 2"])
}

@Test func aKnownNameReplacesTheNumber() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v1"), 0), said(.voice("v2"), 1)],
        names: ["v1": "Настя"]
    )
    #expect(labels.label(for: .voice("v1")) == "Настя")
    #expect(labels.label(for: .voice("v2")) == "Собеседник 2")
    #expect(labels.participants == ["Настя", "Собеседник 2"])
}

// Numbering counts every voice, named or not: two people in the file called «Собеседник 1» and
// «Собеседник 1» again would be indistinguishable, and the header would name one of them twice.
@Test func numberingCountsNamedVoicesToo() {
    let labels = SpeakerLabels.make(
        transcript: [said(.voice("v1"), 0), said(.voice("v2"), 1), said(.voice("v3"), 2)],
        names: ["v2": "Настя"]
    )
    #expect(labels.label(for: .voice("v1")) == "Собеседник 1")
    #expect(labels.label(for: .voice("v3")) == "Собеседник 3")
}

// A meeting the owner sat through in silence has no «Я» line, and claiming one in the header
// would be the same kind of invention the phase has been avoiding since 2б.
@Test func theOwnerIsListedOnlyIfHeSpoke() {
    let labels = SpeakerLabels.make(transcript: [said(.voice("v1"), 0)], names: [:])
    #expect(labels.participants == ["Собеседник"])
}
