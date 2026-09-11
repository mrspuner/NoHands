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
