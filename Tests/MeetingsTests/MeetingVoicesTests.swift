import Core
import Foundation
import Testing
@testable import Meetings

private func meetingVoice(_ id: String, _ vector: [Float], seconds: Double) -> MeetingVoice {
    MeetingVoice(
        id: id,
        segments: [VoiceSegment(cluster: id, start: 0, end: seconds, embedding: vector)],
        print: VoicePrint(vector: vector),
        speechSeconds: seconds
    )
}

private let config = MeetingsConfig.default

@Test func anUnknownVoiceIsRemembered() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 120)],
        meeting: "2026-09-09-0941-telemost",
        book: &book,
        config: config
    )
    #expect(book.voices.count == 1)
    #expect(resolution.names.isEmpty)
    #expect(resolution.identities["v1"] == book.voices[0].id)
}

@Test func aKnownVoiceBringsItsName() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "прошлая", seconds: 120, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [0.99, 0.14], seconds: 120)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.names["v1"] == "Настя")
    #expect(resolution.identities["v1"] == id)
    // The new recording joined the same voice rather than starting a second one.
    #expect(book.voices.count == 1)
    #expect(book.voices[0].prints.count == 2)
}

@Test func aBriefVoiceLabelsTheMeetingButLeavesNoTrace() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 12)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(book.voices.isEmpty)
    #expect(resolution.identities.isEmpty)
    #expect(resolution.names.isEmpty)
}

// A brief voice that is nevertheless recognised keeps its name: the name is knowledge already
// paid for, and only the new fingerprint is refused.
@Test func aBriefButRecognisedVoiceKeepsItsName() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "прошлая", seconds: 300, as: nil, maxPrints: 10
    )
    book.rename(id, to: "Настя")
    let resolution = MeetingVoices.resolve(
        voices: [meetingVoice("v1", [1, 0], seconds: 12)],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.names["v1"] == "Настя")
    #expect(book.voices[0].prints.count == 1)
}

@Test func severalVoicesAreNumberedInOrder() {
    var book = VoiceBook.empty
    let resolution = MeetingVoices.resolve(
        voices: [
            meetingVoice("v1", [1, 0], seconds: 120),
            meetingVoice("v2", [0, 1], seconds: 90),
        ],
        meeting: "нынешняя", book: &book, config: config
    )
    #expect(resolution.identities.count == 2)
    #expect(resolution.identities["v1"] != resolution.identities["v2"])
    #expect(book.voices.count == 2)
}
