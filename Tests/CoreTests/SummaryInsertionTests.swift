import Foundation
import Testing
@testable import Core

private let file = """
    ---
    date: 2026-09-04
    started: 10:53
    duration: 4m
    app: "Яндекс Телемост"
    ---

    ## Транскрипт

    [00:00:07] Я: Помимо неверных, существуют и пустышки.
    [00:41:12] Собеседник: Они тратят время и ресурсы.

    """

private let summary = MeetingSummary(
    title: "Синк по задачам",
    summary: ["обсудили статус", "договорились о сроке"],
    decisions: []
)

private let decisions = [
    CheckedDecision(text: "переозвучить ролик", ratio: 0.9, timecode: 2472),
    CheckedDecision(text: "поменять цвет", ratio: 0.1, timecode: nil),
]

@Test func theSummaryLandsAboveTheTranscript() throws {
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, tasks: [], to: file, named: "тест.md", mode: .insert
    )
    let summaryAt = try #require(result.range(of: "## Саммари"))
    let transcriptAt = try #require(result.range(of: "## Транскрипт"))
    #expect(summaryAt.lowerBound < transcriptAt.lowerBound)
    #expect(result.contains("title: \"Синк по задачам\""))
    #expect(result.contains("- обсудили статус"))
    #expect(result.contains("- переозвучить ролик — [00:41:12]"))
    #expect(result.contains("- поменять цвет — основание не найдено"))
}

// Транскрипт — архив, который переживёт ещё две фазы, и метки в нём правит человек.
@Test func theTranscriptItselfIsUntouched() throws {
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, tasks: [], to: file, named: "тест.md", mode: .insert
    )
    let tail = "## Транскрипт\n\n[00:00:07] Я: Помимо неверных, существуют и пустышки."
    #expect(result.contains(tail))
    #expect(result.contains("app: \"Яндекс Телемост\""))
}

// Строка про микрофон — единственное, что через год объясняет файл без реплик «Я», и конспект
// приходит поверх неё вторым проходом, иногда дважды. Шапка ищется по закрывающему `---`, а
// значение экранировано и переносов не содержит, так что ключ проходит насквозь — но проверяется
// это здесь, а не рассуждением: `replace` уже однажды снесло `---` у файла без шапки.
@Test func theMicrophoneLineSurvivesInsertionAndReplacement() throws {
    let withMicrophone = file.replacingOccurrences(
        of: "app: \"Яндекс Телемост\"",
        with: "app: \"Яндекс Телемост\"\nmicrophone: \"молчал всю запись — дорожка пустая\""
    )
    let inserted = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, tasks: [], to: withMicrophone,
        named: "тест.md", mode: .insert
    )
    #expect(inserted.contains(#"microphone: "молчал всю запись — дорожка пустая""#))

    let replaced = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, tasks: [], to: inserted,
        named: "тест.md", mode: .replace
    )
    #expect(replaced.contains(#"microphone: "молчал всю запись — дорожка пустая""#))
    #expect(replaced.contains("## Транскрипт"))
}

@Test func noDecisionsMeansNoDecisionsSection() throws {
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], tasks: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(!result.contains("## Решения"))
    #expect(result.contains("## Саммари"))
}

@Test func replacingDoesNotStackASecondSummary() throws {
    let once = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, tasks: [], to: file, named: "тест.md", mode: .insert
    )
    let twice = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Другое имя", summary: ["иначе"], decisions: []),
        decisions: [], tasks: [], to: once, named: "тест.md", mode: .replace
    )
    #expect(twice.components(separatedBy: "## Саммари").count == 2)
    #expect(twice.components(separatedBy: "title:").count == 2)
    #expect(twice.contains("title: \"Другое имя\""))
    #expect(twice.contains("- иначе"))
    #expect(!twice.contains("- обсудили статус"))
    #expect(twice.contains("[00:41:12] Собеседник: Они тратят время и ресурсы."))
}

// Команда существует, чтобы гонять её по настоящему архиву при подборе порога, а там над
// транскриптом лежит то, что владелец написал руками. Замена ограничена разделами «Саммари» и
// «Решения» — спека, §5.
@Test func replacingKeepsAHandWrittenSectionAboveTheTranscript() throws {
    let withNote = file.replacingOccurrences(
        of: "## Транскрипт",
        with: "## Мои заметки\n\n- позвонить в понедельник\n\n## Саммари\n\n- старое\n\n## Транскрипт"
    )
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], tasks: [], to: withNote, named: "тест.md", mode: .replace
    )
    #expect(result.contains("## Мои заметки"))
    #expect(result.contains("- позвонить в понедельник"))
    #expect(!result.contains("- старое"))
    #expect(result.components(separatedBy: "## Саммари").count == 2)
}

// Файла без фронтматтера конвейер не пишет, но `meeting summarize` наводят на что угодно, и
// `middle = []` съедало вместе с разделами весь текст сверху.
@Test func replacingAFileWithNoFrontMatterKeepsTheTextAboveTheTranscript() throws {
    let bare = """
        Просто заметка без фронтматтера.

        ## Транскрипт

        [00:00:07] Я: Помимо неверных, существуют и пустышки.

        """
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], tasks: [], to: bare, named: "тест.md", mode: .replace
    )
    #expect(result.hasPrefix("Просто заметка без фронтматтера."))
    #expect(result.contains("## Саммари"))
    #expect(result.contains("[00:00:07] Я: Помимо неверных, существуют и пустышки."))
}

@Test func aTitleWithAQuoteOrANewlineIsEscaped() throws {
    let result = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Про \"это\"", summary: ["раз"], decisions: []),
        decisions: [], tasks: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(result.contains("title: \"Про \\\"это\\\"\""))
}

// Файл без транскрипта — либо не наш, либо правленный так, что вставлять некуда. Цена
// ложного срабатывания выше цены отказа, ровно как при починке заголовка WAV в 2а.
@Test func aFileWithoutATranscriptIsNotTouched() {
    #expect(throws: SummaryInsertion.Failure.noTranscriptSection("чужое.md")) {
        try SummaryInsertion.apply(
            summary: summary, decisions: [], tasks: [], to: "просто заметка", named: "чужое.md", mode: .insert
        )
    }
}

@Test func aRefusalIsWrittenAsASummarySectionSoTheFileCountsAsDone() throws {
    let result = try SummaryInsertion.refusal(
        "The meeting is longer than the model's window", to: file, named: "тест.md"
    )
    #expect(SummaryInsertion.hasSummary(result))
    #expect(result.contains("Конспект не сделан: The meeting is longer than the model's window"))
    #expect(!result.contains("title:"))
}

@Test func hasSummaryTellsAFinishedFileFromAFreshOne() {
    #expect(!SummaryInsertion.hasSummary(file))
}

@Test func tasksAndOpenIssuesGetTheirOwnSections() throws {
    let summary = MeetingSummary(
        title: "Синк", summary: ["обсудили"], decisions: [],
        tasks: [], openIssues: ["чем красить график"]
    )
    let tasks = [
        CheckedTask(text: "собрать визуализацию", owner: "Настя", due: "до 9-10 числа",
                    ratio: 0.9, timecode: 49),
        CheckedTask(text: "прогнать тест", owner: "", due: "", ratio: 0.1, timecode: nil),
    ]
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], tasks: tasks, to: file, named: "тест.md", mode: .insert
    )
    #expect(result.contains("## Задачи"))
    #expect(result.contains("- собрать визуализацию — Настя — до 9-10 числа — [00:00:49]"))
    #expect(result.contains("- прогнать тест — не назначено — срок не назван — основание не найдено"))
    #expect(result.contains("## Открытые вопросы"))
    #expect(result.contains("- чем красить график"))
}

@Test func theFourSectionsComeInOrderAboveTheTranscript() throws {
    let summary = MeetingSummary(
        title: "Синк", summary: ["обсудили"],
        decisions: [], tasks: [], openIssues: ["вопрос"]
    )
    let result = try SummaryInsertion.apply(
        summary: summary,
        decisions: [CheckedDecision(text: "решение", ratio: 0.9, timecode: 10)],
        tasks: [CheckedTask(text: "задача", owner: "", due: "", ratio: 0.9, timecode: 20)],
        to: file, named: "тест.md", mode: .insert
    )
    let order = ["## Саммари", "## Решения", "## Задачи", "## Открытые вопросы", "## Транскрипт"]
    var position = result.startIndex
    for heading in order {
        let found = try #require(result.range(of: heading, range: position..<result.endIndex))
        position = found.upperBound
    }
}

@Test func emptySectionsAreNotWritten() throws {
    let result = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т", summary: ["раз"], decisions: [], tasks: [], openIssues: []),
        decisions: [], tasks: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(!result.contains("## Задачи"))
    #expect(!result.contains("## Открытые вопросы"))
    #expect(!result.contains("## Решения"))
}

// Replacement stays scoped: all four of our headings go, anything the owner wrote stays.
@Test func replacingRemovesAllFourSectionsAndKeepsAHandWrittenOne() throws {
    let once = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т", summary: ["раз"], decisions: [], tasks: [],
                                openIssues: ["вопрос"]),
        decisions: [],
        tasks: [CheckedTask(text: "задача", owner: "", due: "", ratio: 0.9, timecode: 20)],
        to: file, named: "тест.md", mode: .insert
    )
    let withNote = once.replacingOccurrences(
        of: "## Транскрипт", with: "## Моя заметка\n\n- не трогать\n\n## Транскрипт"
    )
    let twice = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Т2", summary: ["два"], decisions: [], tasks: [], openIssues: []),
        decisions: [], tasks: [], to: withNote, named: "тест.md", mode: .replace
    )
    #expect(twice.contains("## Моя заметка"))
    #expect(twice.contains("- не трогать"))
    #expect(!twice.contains("## Задачи"))
    #expect(!twice.contains("## Открытые вопросы"))
    #expect(twice.components(separatedBy: "## Саммари").count == 2)
}
