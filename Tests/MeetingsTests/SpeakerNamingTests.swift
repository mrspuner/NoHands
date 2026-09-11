import Core
import Foundation
import Testing
@testable import Meetings

private struct Archive {
    let root: URL
    let file: URL
    let store: VoiceStore
    let voices: [String]
}

private func makeArchive(
    header: String,
    replies: [String],
    labelNames: [String]
) async throws -> Archive {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("2026-09-09-0941-telemost.md")
    let text = "---\ndate: 2026-09-09\n\(header)\n---\n\n## Транскрипт\n" + replies.joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: file)

    let store = VoiceStore(url: root.appendingPathComponent(".voices.json"))
    var book = VoiceBook.empty
    var ids: [String] = []
    for index in labelNames.indices {
        // Distinct directions, so a merge is visible as one voice rather than two.
        var vector = [Float](repeating: 0, count: labelNames.count)
        vector[index] = 1
        let id = book.remember(
            VoicePrint(vector: vector), meeting: "2026-09-09-0941-telemost",
            seconds: 120, as: nil, maxPrints: 10
        )
        ids.append(id)
    }
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: labelNames.enumerated().map { index, rendered in
                MeetingLabels.Label(position: index + 1, voiceId: ids[index], renderedName: rendered)
            }
        )
    )
    // The same encoder `VoiceStore.save` uses under the hood — going through the store itself
    // rather than hand-rolling `JSONEncoder` keeps the dates written exactly the way `book()`
    // expects to decode them.
    try await store.save(book)
    return Archive(root: root, file: file, store: store, voices: ids)
}

private func naming(_ archive: Archive, _ box: NamingBox) -> SpeakerNaming {
    SpeakerNaming(archive: archive.root, store: archive.store) { box.append($0) }
}

private final class NamingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [SpeakerNaming.Outcome] = []
    func append(_ outcome: SpeakerNaming.Outcome) { lock.lock(); outcomes.append(outcome); lock.unlock() }
    var all: [SpeakerNaming.Outcome] { lock.lock(); defer { lock.unlock() }; return outcomes }
}

@Test func aRenamedParticipantTeachesTheBook() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:11] Я: привет и тебе"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    let text = try String(contentsOf: archive.file, encoding: .utf8)
    #expect(text.contains("[00:00:03] Настя: привет"))
    #expect(text.contains("[00:00:11] Я: привет и тебе"))
    let book = try await archive.store.book()
    #expect(book.name(of: archive.voices[0]) == "Настя")
    // Written back, so a second pass has nothing to do.
    #expect(book.labels(for: archive.file.lastPathComponent)?.labels[0].renderedName == "Настя")
    #expect(box.all.first?.named == ["Настя"])
}

@Test func anUntouchedFileIsLeftAlone() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Собеседник 1]",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().name(of: archive.voices[0]) == nil)
    #expect(box.all.isEmpty)
}

// One name over two rows is how the owner repairs a split the automatic clustering missed.
@Test func twoRowsWithOneNameMergeTheVoices() async throws {
    let archive = try await makeArchive(
        header: "participants: [Настя, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:20] Собеседник 2: и вам"],
        labelNames: ["Собеседник 1", "Собеседник 2"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    let text = try String(contentsOf: archive.file, encoding: .utf8)
    #expect(text.contains("[00:00:03] Настя: привет"))
    #expect(text.contains("[00:00:20] Настя: и вам"))
    let book = try await archive.store.book()
    #expect(book.voices.count == 1)
    #expect(book.voices[0].prints.count == 2)
}

// The header is the one line the owner edits, and it can be edited into something that no longer
// lines up with what the file was written from. Guessing there would attach a name to a voice
// that never said it — permanently, in the book that outlives the audio.
@Test func aHeaderOfTheWrongLengthIsRefusedNotGuessed() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:20] Собеседник 2: и вам"],
        labelNames: ["Собеседник 1", "Собеседник 2"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().voices.allSatisfy { $0.name == nil })
    #expect(box.all.first?.failure != nil)
}

// `~/Meetings` is an Obsidian folder by design: somebody else's note is not a broken meeting.
@Test func aFileTheBookDoesNotKnowIsSkippedInSilence() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Собеседник 1]",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let note = archive.root.appendingPathComponent("заметка.md")
    try Data("Заметка про понедельник.\n\n- купить молока\n".utf8).write(to: note)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(box.all.allSatisfy { $0.file != "заметка.md" })
    #expect(try String(contentsOf: note, encoding: .utf8).hasPrefix("Заметка"))
}

// The exact repair DESIGN.md prescribes for "диаризация путает похожие голоса": the owner sees
// the two names attached to the wrong voices and swaps them in the header. Renaming one position
// at a time, naively, would merge the two voices — the first rename finds its target name already
// held by the second voice — and renaming the transcript one pair at a time over a running copy
// would alias it — the second substitution would rename the first position right back. Neither
// may happen: the voices must stay two, and each position must end with its own new name.
@Test func aSwapExchangesNamesWithoutMergingOrAliasing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("2026-09-09-0941-telemost.md")
    let text = """
        ---
        date: 2026-09-09
        participants: [Пётр, Настя]
        ---

        ## Транскрипт
        [00:00:03] Настя: привет
        [00:00:20] Пётр: и тебе

        """
    try Data(text.utf8).write(to: file)

    let store = VoiceStore(url: root.appendingPathComponent(".voices.json"))
    var book = VoiceBook.empty
    // Distinct directions, so a wrongful merge is visible as one voice rather than two.
    let v1 = book.remember(VoicePrint(vector: [1, 0]), meeting: "m", seconds: 120, as: nil, maxPrints: 10)
    let v2 = book.remember(VoicePrint(vector: [0, 1]), meeting: "m", seconds: 120, as: nil, maxPrints: 10)
    // Named ahead of time, as they would be after an earlier pass — the collision this test
    // guards against only exists once both names are already spoken for.
    book.rename(v1, to: "Настя")
    book.rename(v2, to: "Пётр")
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: [
                MeetingLabels.Label(position: 1, voiceId: v1, renderedName: "Настя"),
                MeetingLabels.Label(position: 2, voiceId: v2, renderedName: "Пётр"),
            ]
        )
    )
    try await store.save(book)
    let box = NamingBox()

    await SpeakerNaming(archive: root, store: store) { box.append($0) }.scanArchive()

    let updated = try String(contentsOf: file, encoding: .utf8)
    #expect(updated.contains("[00:00:03] Пётр: привет\n"))
    #expect(updated.contains("[00:00:20] Настя: и тебе\n"))
    let finalBook = try await store.book()
    #expect(finalBook.voices.count == 2)
    #expect(finalBook.name(of: v1) == "Пётр")
    #expect(finalBook.name(of: v2) == "Настя")
    #expect(finalBook.voices.first { $0.id == v1 }?.prints.count == 1)
    #expect(finalBook.voices.first { $0.id == v2 }?.prints.count == 1)
}

// Two positions already merged into one voice — sharing a rendered label, which only happens
// once they have already been merged — cannot be split back into two different names: there is
// no way to tell which fingerprint belonged to which any more.
@Test func twoPositionsSharingALabelGivenDifferentNamesAreRefused() async throws {
    let archive = try await makeArchive(
        header: "participants: [Настя, Пётр]",
        replies: ["[00:00:03] Настя: привет", "[00:00:20] Настя: и вам"],
        labelNames: ["Настя", "Настя"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(box.all.first?.failure != nil)
}

// `twoRowsWithOneNameMergeTheVoices` proves what `VoiceBook.rename` itself does on a merge; this
// proves the *pass* actually re-reads the survivor into its rows rather than keeping the id each
// row started with — a naive `voiceId: label.voiceId` would leave one row pointing at an id that
// no longer names anything, and this assertion would catch that even though the file and the
// voice count both still look right.
@Test func rowsPointAtTheSurvivorAfterAMerge() async throws {
    let archive = try await makeArchive(
        header: "participants: [Настя, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:20] Собеседник 2: и вам"],
        labelNames: ["Собеседник 1", "Собеседник 2"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    let book = try await archive.store.book()
    let rows = book.labels(for: archive.file.lastPathComponent)?.labels ?? []
    #expect(rows.count == 2)
    for row in rows {
        let voiceId = try #require(row.voiceId)
        #expect(book.voices.contains { $0.id == voiceId })
    }
}

// The brief calls this pass the owner's only channel for learning the book is broken — the
// meeting pipeline deliberately says nothing about it. Neither the transcript nor the book file
// may move a single byte: a book this pass cannot parse is never a book it may guess at and
// overwrite.
@Test func aCorruptBookIsRefusedRatherThanOverwritten() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Настя]",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let bookURL = archive.root.appendingPathComponent(".voices.json")
    try Data("не json".utf8).write(to: bookURL)
    let fileBefore = try Data(contentsOf: archive.file)
    let bookBefore = try Data(contentsOf: bookURL)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == fileBefore)
    #expect(try Data(contentsOf: bookURL) == bookBefore)
    #expect(box.all.first?.failure != nil)
}

// A voice too brief to fingerprint still gets a row — see `MeetingLabels.Label.voiceId` — and the
// pass must still rewrite its label in the file, so a second pass has nothing left to do. It has
// nothing to teach the book, because there is nothing behind the row to teach it about.
@Test func aRowWithoutAVoiceStillGetsItsLabelRewritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("2026-09-09-0941-telemost.md")
    let text = """
        ---
        date: 2026-09-09
        participants: [Я, Настя]
        ---

        ## Транскрипт
        [00:00:03] Собеседник 1: привет
        [00:00:11] Я: привет и тебе

        """
    try Data(text.utf8).write(to: file)

    let store = VoiceStore(url: root.appendingPathComponent(".voices.json"))
    var book = VoiceBook.empty
    book.record(
        MeetingLabels(
            file: file.lastPathComponent,
            labels: [MeetingLabels.Label(position: 1, voiceId: nil, renderedName: "Собеседник 1")]
        )
    )
    try await store.save(book)
    let box = NamingBox()

    await SpeakerNaming(archive: root, store: store) { box.append($0) }.scanArchive()

    let updated = try String(contentsOf: file, encoding: .utf8)
    #expect(updated.contains("[00:00:03] Настя: привет"))
    let finalBook = try await store.book()
    #expect(finalBook.voices.isEmpty)
    #expect(finalBook.labels(for: file.lastPathComponent)?.labels.first?.renderedName == "Настя")
}

// A file the book knows always had a header this application wrote. One that no longer parses —
// present, but not the `[...]` shape `parse` expects — means the owner broke it while editing,
// the same class of problem the length mismatch already names rather than ignores.
@Test func aMangledParticipantsLineOnAKnownFileIsRefusedNotIgnored() async throws {
    let archive = try await makeArchive(
        header: "participants: Настя",
        replies: ["[00:00:03] Собеседник 1: привет"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(box.all.first?.failure != nil)
}

// A label can never contain a colon and still parse back — see `ParticipantsLine.rename`'s own
// contract, "what stands between `] ` and the first colon" — so storing one would make that
// position permanently un-renameable and misattribute everything drawn from it afterwards.
@Test func aTypedNameContainingAColonIsRefused() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, 10:30 Настя]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:11] Я: привет и тебе"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().name(of: archive.voices[0]) == nil)
    #expect(box.all.first?.failure != nil)
}

// `Собеседник` and `Собеседник N` are what this application itself writes for a voice nobody has
// named — typing one in as if it were a real name would store it as one, and it would then
// compete with real names in later meetings.
@Test func typingAPlaceholderLabelAsANameIsRefused() async throws {
    let archive = try await makeArchive(
        header: "participants: [Я, Собеседник 3]",
        replies: ["[00:00:03] Собеседник 1: привет", "[00:00:11] Я: привет и тебе"],
        labelNames: ["Собеседник 1"]
    )
    defer { try? FileManager.default.removeItem(at: archive.root) }
    let before = try Data(contentsOf: archive.file)
    let box = NamingBox()

    await naming(archive, box).scanArchive()

    #expect(try Data(contentsOf: archive.file) == before)
    #expect(try await archive.store.book().name(of: archive.voices[0]) == nil)
    #expect(box.all.first?.failure != nil)
}
