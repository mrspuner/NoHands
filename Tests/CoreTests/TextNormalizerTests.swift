import Testing
@testable import Core

@Test func stripsPunctuationAndLowercases() {
    #expect(TextNormalizer.words(from: "Привет, мир!") == ["привет", "мир"])
}

@Test func foldsYoToYe() {
    #expect(TextNormalizer.words(from: "Ёлка ещё зелёная") == ["елка", "еще", "зеленая"])
}

@Test func collapsesWhitespace() {
    #expect(TextNormalizer.words(from: "  два\n\nслова  ") == ["два", "слова"])
}

@Test func keepsLatinTermsIntact() {
    #expect(TextNormalizer.words(from: "деплой через Kubernetes") == ["деплой", "через", "kubernetes"])
}

@Test func splitsHyphenatedWords() {
    // A hyphen becomes a separator so that "какой-то" and "какой то" compare equal:
    // engines disagree on hyphenation far more often than on the words themselves.
    #expect(TextNormalizer.words(from: "какой-то") == ["какой", "то"])
}

@Test func emptyInputGivesNoWords() {
    #expect(TextNormalizer.words(from: "   ") == [])
}
