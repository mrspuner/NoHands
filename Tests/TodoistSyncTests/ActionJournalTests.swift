import Foundation
import Testing
@testable import TodoistSync

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-\(UUID().uuidString)")
        .appendingPathComponent("todoist-actions.jsonl")
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_791_400_000) }

@Test func aRecordIsReadBack() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)

    let entries = try await journal.entries()
    #expect(entries == [ActionJournal.Entry(
        time: "2026-10-07T19:06:40Z", action: "task.created", todoistID: "t1", name: nil
    )])
}

// The second slice reads this file to recognise its own changes among those the poll returns;
// a record that replaced the previous one would make every earlier action look like the owner's.
@Test func recordsAreAppendedInOrder() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    try await journal.record(action: ActionJournal.Action.projectCreated, todoistID: "p1", name: "Хибины")
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)

    let entries = try await journal.entries()
    #expect(entries.map(\.todoistID) == ["p1", "t1"])
    #expect(entries[0].name == "Хибины")
}

@Test func theFileIsOneJSONObjectPerLine() async throws {
    let url = temporaryJournalURL()
    let journal = ActionJournal(url: url, now: fixedNow)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t2", name: nil)

    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains(#""todoist_id":"t1""#))
}

@Test func aJournalThatWasNeverWrittenIsEmpty() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    #expect(try await journal.entries().isEmpty)
}

@Test func anUnwritableLocationThrows() async {
    let journal = ActionJournal(url: URL(fileURLWithPath: "/dev/null/journal.jsonl"), now: fixedNow)
    await #expect(throws: (any Error).self) {
        try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)
    }
}

@Test func theDefaultLocationIsOutsideTheRepository() {
    #expect(ActionJournal.defaultURL.path.hasSuffix("Library/Application Support/NoHands/todoist-actions.jsonl"))
}

// One damaged line must not switch the echo filter off for good.
@Test func anUndecodableLineIsSkipped() async throws {
    let url = temporaryJournalURL()
    let journal = ActionJournal(url: url, now: fixedNow)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{garbage\n".utf8))
    try handle.close()
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t2", name: nil)
    #expect(try await journal.entries().map(\.todoistID) == ["t1", "t2"])
}
