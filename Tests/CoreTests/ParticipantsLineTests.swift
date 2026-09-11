import Foundation
import Testing
@testable import Core

private let file = """
---
date: 2026-09-09
participants: [Я, Настя, Собеседник 2]
---

## Транскрипт
[00:00:03] Настя: привет
[00:00:11] Я: привет и тебе
[00:00:15] Собеседник 2: и вам

"""

@Test func theListIsRead() {
    #expect(ParticipantsLine.parse(file) == ["Я", "Настя", "Собеседник 2"])
}

@Test func aFileWithoutTheLineHasNoParticipants() {
    #expect(ParticipantsLine.parse("---\ndate: 2026-09-09\n---\n") == nil)
}

@Test func quotedNamesComeBackWhole() {
    let quoted = "---\nparticipants: [Я, \"Настя, она же Настасья\"]\n---\n"
    #expect(ParticipantsLine.parse(quoted) == ["Я", "Настя, она же Настасья"])
}

// `replace` touches only the header line — see its doc comment — so a name it drops from the
// list can still stand in a reply below, untouched, until `rename` (tested separately) carries
// it down. What `replace` owes is a header that reads back as the list it was given.
@Test func theListIsWrittenBack() {
    let updated = ParticipantsLine.replace(in: file, with: ["Я", "Настя", "Пётр"])
    #expect(updated.contains("participants: [Я, Настя, Пётр]\n"))
    #expect(ParticipantsLine.parse(updated) == ["Я", "Настя", "Пётр"])
}

// Only the label is touched. The text of a reply may have been edited by hand, and a line that
// merely mentions the old name in its text is not a label.
@Test func onlyTheLabelIsRenamed() {
    let renamed = ParticipantsLine.rename(in: file, from: "Собеседник 2", to: "Пётр")
    #expect(renamed.contains("[00:00:15] Пётр: и вам\n"))
    #expect(renamed.contains("[00:00:03] Настя: привет\n"))
}

@Test func renamingLeavesTheRestOfTheFileByteForByte() {
    let renamed = ParticipantsLine.rename(in: file, from: "Собеседник 2", to: "Пётр")
    let before = file.components(separatedBy: "\n")
    let after = renamed.components(separatedBy: "\n")
    #expect(before.count == after.count)
    for index in before.indices where !before[index].hasPrefix("[00:00:15]") {
        #expect(before[index] == after[index])
    }
}

// A reply whose text happens to start with a name-like prefix must not be re-labelled: the
// label is what stands between `] ` and the first colon, and nothing else is.
@Test func aColonInsideTheTextIsNotALabel() {
    let tricky = "## Транскрипт\n[00:00:01] Я: Собеседник 2: так он и сказал\n"
    let renamed = ParticipantsLine.rename(in: tricky, from: "Собеседник 2", to: "Пётр")
    #expect(renamed == tricky)
}
