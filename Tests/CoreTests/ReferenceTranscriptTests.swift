import Testing
@testable import Core

private let sample = """
    Запись встречи 23.03.2026 в 17:12 (MSK). Автоматическая расшифровка.

    Иван Петров (голос 1):
    [00:00:05] Начнём с того, что у нас по деплою.
    [00:00:10] Вчера выкатили новую версию.

    Мария Сидорова (голос 2):
    [00:01:22] Я посмотрю логи.
    """

@Test func keepsOnlyTimestampedLines() {
    let text = ReferenceTranscript.parse(sample).text
    #expect(text == "Начнём с того, что у нас по деплою. Вчера выкатили новую версию. Я посмотрю логи.")
}

@Test func dropsHeaderAndSpeakerLabels() {
    let text = ReferenceTranscript.parse(sample).text
    #expect(!text.contains("Иван Петров"))
    #expect(!text.contains("голос"))
    #expect(!text.contains("23.03.2026"))
}

@Test func dropsTimestampsThemselves() {
    let text = ReferenceTranscript.parse(sample).text
    #expect(!text.contains("00:00:05"))
    #expect(!text.contains("["))
}

@Test func returnsEmptyWhenNothingIsTimestamped() {
    #expect(ReferenceTranscript.parse("Просто текст\nбез таймкодов").text == "")
}

// The counts are what makes a partial parse visible: without them a format the regex does not
// recognise would just shrink the reference and move the error rate for no stated reason.
@Test func reportsHowManyLinesSpeechCameFrom() {
    let parsed = ReferenceTranscript.parse(sample)
    #expect(parsed.spokenLines == 3)
    #expect(parsed.nonEmptyLines == 6)
}

@Test func blankLinesAreNotCounted() {
    let parsed = ReferenceTranscript.parse("\n\n[00:00:01] Раз\n   \n[00:00:02] Два\n")
    #expect(parsed.spokenLines == 2)
    #expect(parsed.nonEmptyLines == 2)
}

@Test func droppedLinesShowUpAsAGapInTheCounts() {
    // A wrapped line without its own timestamp: exactly the case that would vanish silently.
    let parsed = ReferenceTranscript.parse("[00:00:01] Первая половина\nвторая половина")
    #expect(parsed.spokenLines == 1)
    #expect(parsed.nonEmptyLines == 2)
    #expect(!parsed.text.contains("вторая"))
}
