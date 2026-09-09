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
