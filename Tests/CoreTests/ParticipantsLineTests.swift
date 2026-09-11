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

// Binds `parse` to the actual escaping `Frontmatter.listValue` produces, rather than a
// hand-written encoded form: if the encoder's quoting rules ever drift, this notices that the
// decoder drifted along with them (or didn't).
@Test func namesEncodedByFrontmatterListValueRoundTripThroughParse() {
    let tricky = [
        "Настя, она же Настасья",
        "Имя \"в кавычках\"",
        "Обратный\\слэш",
        "Хэштег#1",
        "Время: 10:30",
    ]
    let encoded = tricky.map(Frontmatter.listValue).joined(separator: ", ")
    let markdown = "---\nparticipants: [\(encoded)]\n---\n"
    #expect(ParticipantsLine.parse(markdown) == tricky)
}

// Only the label is touched. The text of a reply may have been edited by hand, and a line that
// merely mentions the old name in its text is not a label.
@Test func onlyTheLabelIsRenamed() {
    let renamed = ParticipantsLine.rename(in: file, mapping: ["Собеседник 2": "Пётр"])
    #expect(renamed.contains("[00:00:15] Пётр: и вам\n"))
    #expect(renamed.contains("[00:00:03] Настя: привет\n"))
}

@Test func renamingLeavesTheRestOfTheFileByteForByte() {
    let renamed = ParticipantsLine.rename(in: file, mapping: ["Собеседник 2": "Пётр"])
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
    let renamed = ParticipantsLine.rename(in: tricky, mapping: ["Собеседник 2": "Пётр"])
    #expect(renamed == tricky)
}

// The whole point of taking a mapping rather than one pair at a time: every line is relabelled
// once, by looking up its own current label in the mapping — never by scanning text that an
// earlier substitution in the same pass has already rewritten. Applying two single-pair renames
// one after another would alias here: renaming "Настя" to "Пётр" first would then be caught and
// renamed right back to "Настя" by the second substitution.
@Test func aSwapExchangesBothLabelsWithoutAliasing() {
    let both = "[00:00:03] Настя: привет\n[00:00:20] Пётр: и тебе\n"
    let swapped = ParticipantsLine.rename(in: both, mapping: ["Настя": "Пётр", "Пётр": "Настя"])
    #expect(swapped == "[00:00:03] Пётр: привет\n[00:00:20] Настя: и тебе\n")
}

@Test func anEmptyMappingChangesNothing() {
    #expect(ParticipantsLine.rename(in: file, mapping: [:]) == file)
}
