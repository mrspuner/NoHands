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
//
// The geometry is chosen so an averaging regression actually fails rather than merely returning
// the wrong-looking-but-still-passing score. Prints are [1, 0] and [-0.6, 0.8]; the query equals
// the second print, so the true best print scores cosine 1.0 against it — comfortably over the
// 0.7 threshold. Their unweighted average is [0.2, 0.4], which normalizes to
// [0.4472, 0.8944]; its cosine against the query is
// 0.4472*-0.6 + 0.8944*0.8 ≈ 0.447 — well under 0.7. A regression to "average the voice's
// prints, then compare" would find no match at all here, not merely attribute it to the wrong id.
@Test func theBestPrintWinsRatherThanTheirAverage() {
    var book = VoiceBook.empty
    let id = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 120, as: nil, maxPrints: 10, now: moment
    )
    _ = book.remember(
        VoicePrint(vector: [-0.6, 0.8]), meeting: "m2", seconds: 120, as: id, maxPrints: 10, now: moment
    )
    #expect(book.match(VoicePrint(vector: [-0.6, 0.8]), threshold: 0.7)?.id == id)
}

// Two distinct, unmerged voices both clear the threshold; the closer one must win. Scores are
// cosine 0.866 for the farther voice and 0.985 for the closer one, registered in that order —
// so a regression to "return the first voice over the threshold" would wrongly return the
// farther voice instead of the maximum.
@Test func theClosestVoiceWinsAcrossVoices() {
    var book = VoiceBook.empty
    let farther = book.remember(
        VoicePrint(vector: [0.8660, 0.5]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let closer = book.remember(
        VoicePrint(vector: [0.9848, 0.1736]), meeting: "m2", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let found = book.match(VoicePrint(vector: [1, 0]), threshold: 0.75)
    #expect(found?.id == closer)
    #expect(found?.id != farther)
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

// A row left pointing at a removed identity would strand a whole meeting's labels permanently.
// Here the absorbed voice was registered after the twin it merges into, so the twin keeps its
// array index untouched by the removal — the non-shifting branch of the merge.
@Test func mergingRewritesMeetingLabelsWhenTheAbsorbedVoiceComesAfterTheSurvivor() {
    var book = VoiceBook.empty
    let survivor = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let absorbed = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(survivor, to: "Настя")
    book.record(
        MeetingLabels(
            file: "m.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: absorbed, renderedName: "Собеседник 1")]
        )
    )
    book.rename(absorbed, to: "Настя")
    #expect(book.voices.count == 1)
    #expect(book.voices[0].id == survivor)
    #expect(book.labels(for: "m.md")?.labels.first?.voiceId == survivor)
}

// Same repair, opposite storage order: the absorbed voice was registered before the twin it
// merges into, so removing it shifts the twin's array index down by one — the branch that an
// off-by-one in the index arithmetic would silently miscount.
@Test func mergingRewritesMeetingLabelsWhenTheAbsorbedVoiceComesBeforeTheSurvivor() {
    var book = VoiceBook.empty
    let absorbed = book.remember(
        VoicePrint(vector: [1, 0]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    let survivor = book.remember(
        VoicePrint(vector: [0, 1]), meeting: "m1", seconds: 60, as: nil, maxPrints: 10, now: moment
    )
    book.rename(survivor, to: "Настя")
    book.record(
        MeetingLabels(
            file: "m.md",
            labels: [MeetingLabels.Label(position: 1, voiceId: absorbed, renderedName: "Собеседник 1")]
        )
    )
    book.rename(absorbed, to: "Настя")
    #expect(book.voices.count == 1)
    #expect(book.voices[0].id == survivor)
    #expect(book.labels(for: "m.md")?.labels.first?.voiceId == survivor)
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

@Test func aNonBase64VectorIsRefused() {
    let json = #"{"meeting":"m","seconds":60,"vector":"not base64!!"}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(StoredPrint.self, from: Data(json.utf8))
    }
}

// Three raw bytes are valid base64 — they decode without error — but three is not a multiple
// of four, so they cannot be four-byte floats. `bindMemory` would silently round the count down
// and hand back a short, wrong vector instead of failing; this must be refused instead, since a
// `.voices.json` this corrupt can only come from a hand edit or a bad write, and the fingerprint
// it half-describes cannot be rebuilt once the audio behind it is gone.
@Test func aVectorWithAByteCountNotAMultipleOfFourIsRefused() {
    let encoded = Data([0x01, 0x02, 0x03]).base64EncodedString()
    let json = #"{"meeting":"m","seconds":60,"vector":"\#(encoded)"}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(StoredPrint.self, from: Data(json.utf8))
    }
}
