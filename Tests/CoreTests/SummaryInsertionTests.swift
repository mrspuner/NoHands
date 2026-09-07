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
        summary: summary, decisions: decisions, to: file, named: "тест.md", mode: .insert
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
        summary: summary, decisions: decisions, to: file, named: "тест.md", mode: .insert
    )
    let tail = "## Транскрипт\n\n[00:00:07] Я: Помимо неверных, существуют и пустышки."
    #expect(result.contains(tail))
    #expect(result.contains("app: \"Яндекс Телемост\""))
}

@Test func noDecisionsMeansNoDecisionsSection() throws {
    let result = try SummaryInsertion.apply(
        summary: summary, decisions: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(!result.contains("## Решения"))
    #expect(result.contains("## Саммари"))
}

@Test func replacingDoesNotStackASecondSummary() throws {
    let once = try SummaryInsertion.apply(
        summary: summary, decisions: decisions, to: file, named: "тест.md", mode: .insert
    )
    let twice = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Другое имя", summary: ["иначе"], decisions: []),
        decisions: [], to: once, named: "тест.md", mode: .replace
    )
    #expect(twice.components(separatedBy: "## Саммари").count == 2)
    #expect(twice.components(separatedBy: "title:").count == 2)
    #expect(twice.contains("title: \"Другое имя\""))
    #expect(twice.contains("- иначе"))
    #expect(!twice.contains("- обсудили статус"))
    #expect(twice.contains("[00:41:12] Собеседник: Они тратят время и ресурсы."))
}

@Test func aTitleWithAQuoteOrANewlineIsEscaped() throws {
    let result = try SummaryInsertion.apply(
        summary: MeetingSummary(title: "Про \"это\"", summary: ["раз"], decisions: []),
        decisions: [], to: file, named: "тест.md", mode: .insert
    )
    #expect(result.contains("title: \"Про \\\"это\\\"\""))
}

// Файл без транскрипта — либо не наш, либо правленный так, что вставлять некуда. Цена
// ложного срабатывания выше цены отказа, ровно как при починке заголовка WAV в 2а.
@Test func aFileWithoutATranscriptIsNotTouched() {
    #expect(throws: SummaryInsertion.Failure.noTranscriptSection("чужое.md")) {
        try SummaryInsertion.apply(
            summary: summary, decisions: [], to: "просто заметка", named: "чужое.md", mode: .insert
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
