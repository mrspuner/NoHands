import Foundation
import Testing
@testable import Core

@Test func aPlainValueIsQuoted() {
    #expect(Frontmatter.quoted("Telegram") == "\"Telegram\"")
}

// Настоящее имя приложения ничем не ограничено: `Яндекс Телемост` приехало в архив фазы 2б
// именно так, с пробелом.
@Test func aNameWithASpaceStaysOneValue() {
    #expect(Frontmatter.quoted("Яндекс Телемост") == "\"Яндекс Телемост\"")
}

@Test func quotesAndBackslashesAreEscaped() {
    #expect(Frontmatter.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

// Перевод строки внутри значения разорвал бы блок `---` для Obsidian и для всего, что этот
// файл потом перечитывает.
@Test func controlCharactersAreDropped() {
    #expect(Frontmatter.quoted("a\nb\tc") == "\"abc\"")
}
