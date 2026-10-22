import Testing
@testable import Telegram

@Test func blocksUnderWaitingAreItems() {
    let md = """
    # Inbox

    ## Ждёт ответа

    ### Вопрос про сроки
    Когда сдаём отчёт?
    Контекст: встреча 12.10.

    ### Вопрос про бюджет
    Сколько выделено?

    ## Сбои
    """
    let items = InboxItems.parse(md)
    #expect(items.map(\.ref) == ["Вопрос про сроки", "Вопрос про бюджет"])
    #expect(items[0].text.hasPrefix("### Вопрос про сроки"))
    #expect(items[0].text.contains("Когда сдаём отчёт?"))
    #expect(!items[0].text.contains("Вопрос про бюджет"))
    #expect(items[1].text.contains("Сколько выделено?"))
}

@Test func failureLinesAreItems() {
    let md = "# Inbox\n\n## Ждёт ответа\n\n## Сбои\n\nне разобрал созвон 12.10\n\nнет доступа к файлу\n"
    #expect(InboxItems.parse(md) == [
        InboxItem(ref: "Сбой: не разобрал созвон 12.10", text: "не разобрал созвон 12.10"),
        InboxItem(ref: "Сбой: нет доступа к файлу", text: "нет доступа к файлу"),
    ])
}

@Test func emptySectionsGiveNothing() {
    #expect(InboxItems.parse("# Inbox\n\n## Ждёт ответа\n\n## Сбои") == [])
}

@Test func headingOutsideSectionsIsIgnored() {
    let md = "# Inbox\n\n### Мусор до секций\nтекст\n\n## Другое\n\n### Тоже мусор\n\n## Ждёт ответа\n\n### Настоящий\nтело\n"
    #expect(InboxItems.parse(md).map(\.ref) == ["Настоящий"])
}
