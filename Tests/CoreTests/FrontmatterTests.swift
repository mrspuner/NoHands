import Foundation
import Testing
@testable import Core

@Test func aPlainValueIsQuoted() {
    #expect(Frontmatter.quoted("Telegram") == "\"Telegram\"")
}

// An application's real display name is unconstrained: `Яндекс Телемост` reached the phase 2б
// archive exactly like that, with a space.
@Test func aNameWithASpaceStaysOneValue() {
    #expect(Frontmatter.quoted("Яндекс Телемост") == "\"Яндекс Телемост\"")
}

@Test func quotesAndBackslashesAreEscaped() {
    #expect(Frontmatter.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

// A newline inside the value would break the `---` block, for Obsidian and for everything
// else that reads this file back later.
@Test func controlCharactersAreDropped() {
    #expect(Frontmatter.quoted("a\nb\tc") == "\"abc\"")
}

@Test func aPlainNameStaysUnquotedInAList() {
    #expect(Frontmatter.listValue("Настя") == "Настя")
}

// A comma would be read as a second list item, and a bracket or quote would break the `[...]`
// syntax itself — this is the value a name the owner typed becomes inside `participants:`.
@Test func aNameWithListSyntaxIsQuoted() {
    #expect(Frontmatter.listValue("Настя, она же Настасья") == Frontmatter.quoted("Настя, она же Настасья"))
    #expect(Frontmatter.listValue("Собеседник [2]") == Frontmatter.quoted("Собеседник [2]"))
    #expect(Frontmatter.listValue("Со\"бес\"едник") == Frontmatter.quoted("Со\"бес\"едник"))
}

// A leading or trailing space would be invisible in the rendered list but change the value on
// re-parse, and an empty string is not a name at all.
@Test func edgeValuesAreQuotedRatherThanLeftBare() {
    #expect(Frontmatter.listValue(" Настя") == Frontmatter.quoted(" Настя"))
    #expect(Frontmatter.listValue("Настя ") == Frontmatter.quoted("Настя "))
    #expect(Frontmatter.listValue("") == Frontmatter.quoted(""))
}
