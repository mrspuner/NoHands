import Foundation
import Testing
@testable import Core

private let moment = Date(timeIntervalSince1970: 1_788_500_000)

@Test func anEmptyBookMatchesNothing() {
    #expect(VoiceBook.empty.match(VoicePrint(vector: [1, 0]), threshold: 0.7) == nil)
}

@Test func aRememberedVoiceIsFoundAgain() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "2026-09-09-0941-telemost",
        seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    let found = book.match(VoicePrint(vector: [0.99, 0.14]), threshold: 0.7)
    #expect(found?.id == id)
}

@Test func aDistantVoiceIsNotFound() {
    var book = VoiceBook.empty
    _ = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    #expect(book.match(VoicePrint(vector: [0, 1]), threshold: 0.7) == nil)
}

// The match is by the best of a voice's prints, not by their average. A person recorded on a
// close microphone once and through a bad connection another time is two directions, and the
// average of the two is a third direction that is neither.
@Test func theBestPrintWinsRatherThanTheirAverage() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    _ = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m2", seconds: 120, as: id, maxPrints: 10, now: moment
    )
    #expect(book.match(VoicePrint(vector: [0.02, 1]), threshold: 0.7)?.id == id)
}

@Test func aVoiceKeepsOnlyItsLatestPrints() {
    var book = VoiceBook.empty
    var id: String?
    for number in 1...12 {
        id = book.remember(
            VoicePrint(vector: [1, 0]), meeting: "m\(number)",
            seconds: 60, as: id, maxPrints: 10, now: moment
        )
    }
    let voice = book.voices.first { $0.id == id }
    #expect(voice?.prints.count == 10)
    #expect(voice?.prints.first?.meeting == "m3")
    #expect(voice?.prints.last?.meeting == "m12")
}

@Test func aNameIsRemembered() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(id, to: "Настя")
    #expect(book.name(of: id) == "Настя")
}

// The owner writing one name over two rows of the header is saying "these are one person" —
// the hand repair for a split the automatic merge missed.
@Test func oneNameOverTwoVoicesMergesThem() {
    var book = VoiceBook.empty
    let first = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let second = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(first, to: "Настя")
    book.rename(second, to: "Настя")
    #expect(book.voices.count == 1)
    let survivor = book.voices[0]
    #expect(survivor.name == "Настя")
    #expect(survivor.prints.count == 2)
    // Whichever row survived, both directions must still be findable under that name.
    #expect(book.match(VoicePrint(vector: [1, 0]), threshold: 0.7)?.name == "Настя")
    #expect(book.match(VoicePrint(vector: [0, 1]), threshold: 0.7)?.name == "Настя")
}

@Test func labelsOfAMeetingAreKeptByFileName() {
    var book = VoiceBook.empty
    book.record(
        MeetingLabels(
            file: "2026-09-09-0941-telemost.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: "abc", renderedName: "Собеседник 1")]
        )
    )
    #expect(book.labels(for: "2026-09-09-0941-telemost.md")?.labels.count == 1)
    #expect(book.labels(for: "другой.md") == nil)
}

// A meeting rewritten by `nohands meeting diarize` must not leave its old row behind: the two
// would then disagree about which voice a header position means.
@Test func recordingAMeetingTwiceKeepsOneRow() {
    var book = VoiceBook.empty
    book.record(MeetingLabels(file: "m.md", labels: []))
    book.record(
        MeetingLabels(
            file: "m.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: "abc", renderedName: "Настя")]
        )
    )
    #expect(book.meetings.count == 1)
    #expect(book.labels(for: "m.md")?.labels.first?.renderedName == "Настя")
}

@Test func theBookSurvivesAJsonRoundTrip() throws {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [0.6, 0.8]), meeting: "m", seconds: 61.5,
        as: nil, maxPrints: 10, now: moment
    )
    book.rename(id, to: "Настя")
    book.record(
        MeetingLabels(file: "m.md", labels: [MeetingLabels.Label(position: 1, voiceId: id, renderedName: "Настя")])
    )
    let data = try JSONEncoder().encode(book)
    let restored = try JSONDecoder().decode(VoiceBook.self, from: data)
    #expect(restored == book)
    #expect(restored.match(VoicePrint(vector: [0.6, 0.8]), threshold: 0.7)?.name == "Настя")
}

// Vectors are 256 floats each and there may be ten per voice; as a JSON array of numbers the
// file becomes unreadable to the eye it is meant to be readable to.
@Test func vectorsAreStoredAsBase64() throws {
    var book = VoiceBook.empty
    _ = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let json = String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
    #expect(!json.contains("[1,0]"))
    #expect(json.contains("\"vector\":\""))
}
