import Foundation
import Testing
@testable import Dictation

@Test func shortTextIsLeftAlone() {
    #expect(MenuTitle.short("Привет.") == "Привет.")
}

// A newline inside an NSMenuItem title breaks the row's layout, and dictated text is full of
// them once cleanup has added punctuation.
@Test func newlinesAndRunsOfSpacesCollapse() {
    #expect(MenuTitle.short("первая строка\nвторая   строка") == "первая строка вторая строка")
}

@Test func longTextIsCutWithAnEllipsis() {
    let text = String(repeating: "а", count: 100)
    let title = MenuTitle.short(text, limit: 10)
    #expect(title == "аааааааааа…")
}

@Test func aTextExactlyAtTheLimitIsNotCut() {
    let text = String(repeating: "а", count: 10)
    #expect(MenuTitle.short(text, limit: 10) == text)
}

// Cutting mid-word can leave a trailing space before the ellipsis, which reads as a typo.
@Test func theCutDoesNotLeaveATrailingSpace() {
    #expect(MenuTitle.short("абвг де", limit: 5) == "абвг…")
}

@Test func emptyTextStaysEmpty() {
    #expect(MenuTitle.short("") == "")
}
