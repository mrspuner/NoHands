import Foundation
import Testing

@testable import Core

private let file = """
    ---
    date: 2026-09-04
    app: "Яндекс Телемост"
    ---

    ## Транскрипт

    [00:00:07] Я: Помимо неверных, существуют и пустышки.
    [00:41:12] Собеседник: Они тратят время и ресурсы, не создавая ни прибыли.
    """

@Test func repliesAreReadBackWithTheirTimecodes() {
    let index = TranscriptIndex.parse(file)
    #expect(index.lines.count == 2)
    #expect(index.lines[0].timecode == 7)
    #expect(index.lines[0].speaker == "Я")
    #expect(index.lines[0].text == "Помимо неверных, существуют и пустышки.")
    #expect(index.lines[1].timecode == 2472)
    #expect(index.lines[1].speaker == "Собеседник")
}

// Front matter carries a colon on every line; reading it as a reply would put `date` in the
// transcript and drag the whole search off by a screen.
@Test func everythingAboveTheHeadingIsIgnored() {
    let index = TranscriptIndex.parse(file)
    #expect(!index.body.contains("date:"))
    #expect(!index.words.contains { $0.word == "яндекс" })
}

@Test func aFileWithoutTheHeadingHasNoLines() {
    #expect(TranscriptIndex.parse("---\ndate: 2026-09-04\n---\n\nпросто текст").lines.isEmpty)
}

@Test func wordsCarryTheLineTheyCameFrom() {
    let index = TranscriptIndex.parse(file)
    #expect(index.words.first?.word == "помимо")
    #expect(index.words.first?.line == 0)
    #expect(index.words.last?.line == 1)
}

@Test func normalisationFoldsCaseAndYoAndDropsPunctuation() {
    #expect(SummaryText.words("Всё, ЧТО угодно!") == ["все", "что", "угодно"])
}

@Test func theBodyIsTheReplyLinesAndNothingElse() {
    let index = TranscriptIndex.parse(file)
    #expect(index.body.hasPrefix("[00:00:07] Я:"))
    #expect(index.body.components(separatedBy: "\n").count == 2)
}
