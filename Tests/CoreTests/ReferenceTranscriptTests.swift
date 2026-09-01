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
    let text = ReferenceTranscript.spokenText(from: sample)
    #expect(text == "Начнём с того, что у нас по деплою. Вчера выкатили новую версию. Я посмотрю логи.")
}

@Test func dropsHeaderAndSpeakerLabels() {
    let text = ReferenceTranscript.spokenText(from: sample)
    #expect(!text.contains("Иван Петров"))
    #expect(!text.contains("голос"))
    #expect(!text.contains("23.03.2026"))
}

@Test func dropsTimestampsThemselves() {
    let text = ReferenceTranscript.spokenText(from: sample)
    #expect(!text.contains("00:00:05"))
    #expect(!text.contains("["))
}

@Test func returnsEmptyWhenNothingIsTimestamped() {
    #expect(ReferenceTranscript.spokenText(from: "Просто текст\nбез таймкодов") == "")
}
