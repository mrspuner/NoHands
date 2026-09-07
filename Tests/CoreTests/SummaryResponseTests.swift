import Foundation
import Testing
@testable import Core

@Test func theAnswerTheModelActuallyReturnsIsRead() throws {
    let raw = """
        {"title": "Синк по задачам",
         "summary": ["обсудили статус"],
         "decisions": [{"text": "переозвучить ролик", "quote": "давайте переозвучим ролик"}]}
        """
    let summary = try SummaryResponse.parse(raw)
    #expect(summary.title == "Синк по задачам")
    #expect(summary.summary == ["обсудили статус"])
    #expect(
        summary.decisions == [
            MeetingSummary.Decision(text: "переозвучить ролик", quote: "давайте переозвучим ролик")
        ]
    )
}

// The prompt asks for bare JSON, and both measurement runs obeyed it. The fence is stripped
// anyway: it costs four lines against a meeting left without a summary because of a formatting
// habit.
@Test func aFencedAnswerIsStillRead() throws {
    let raw = "```json\n{\"title\": \"Т\", \"summary\": [\"раз\"], \"decisions\": []}\n```"
    #expect(try SummaryResponse.parse(raw).summary == ["раз"])
}

@Test func anEmptySummaryIsARefusalRatherThanAnEmptySection() {
    #expect(throws: SummaryResponse.Failure.emptySummary) {
        try SummaryResponse.parse("{\"title\": \"Т\", \"summary\": [], \"decisions\": []}")
    }
}

@Test func blankStringsDoNotCountAsASummary() {
    #expect(throws: SummaryResponse.Failure.emptySummary) {
        try SummaryResponse.parse("{\"title\": \"Т\", \"summary\": [\"  \", \"\"], \"decisions\": []}")
    }
}

// A decision without a quote has nothing to check it against, and an unverifiable decision in
// the archive is indistinguishable from a made-up one — see the measurement in the spec, §3.
@Test func aDecisionWithoutAQuoteIsDropped() throws {
    let raw = """
        {"title": "Т", "summary": ["раз"],
         "decisions": [{"text": "а", "quote": ""}, {"text": "б", "quote": "было сказано"}]}
        """
    #expect(try SummaryResponse.parse(raw).decisions.map(\.text) == ["б"])
}

@Test func proseInsteadOfJSONIsNamedAsSuch() {
    #expect(throws: SummaryResponse.Failure.notJSON) {
        try SummaryResponse.parse("Конечно! Вот конспект встречи:")
    }
}

// Generation runs at temperature 0: the same transcript produces the same unparseable answer
// every time, so retrying buys nothing. A temporary classification would stop the whole
// archive pass over one bad meeting — see docs, §11.
@Test func bothParseFailuresArePermanent() {
    #expect(SummaryResponse.Failure.notJSON.isPermanent)
    #expect(SummaryResponse.Failure.emptySummary.isPermanent)
}

@Test func tasksAndOpenIssuesAreRead() throws {
    let raw = """
        {"title": "Синк", "summary": ["обсудили"],
         "decisions": [],
         "tasks": [{"text": "собрать визуализацию", "owner": "Настя", "due": "до 9-10 числа",
                    "quote": "Настя, соберёшь визуализацию"}],
         "openIssues": ["чем красить график"]}
        """
    let summary = try SummaryResponse.parse(raw)
    #expect(summary.tasks == [
        MeetingSummary.Task(
            text: "собрать визуализацию", owner: "Настя", due: "до 9-10 числа",
            quote: "Настя, соберёшь визуализацию"
        )
    ])
    #expect(summary.openIssues == ["чем красить график"])
}

// The transcript knows only «Я» and «Собеседник» until phase 2г, so a task whose owner was never
// said out loud is the common case, not the exception.
@Test func aTaskWithoutAnOwnerOrDueStillParses() throws {
    let raw = """
        {"title": "Т", "summary": ["раз"], "decisions": [],
         "tasks": [{"text": "прогнать тест", "quote": "давай прогоним тест"}]}
        """
    let task = try #require(try SummaryResponse.parse(raw).tasks.first)
    #expect(task.owner.isEmpty)
    #expect(task.due.isEmpty)
}

// Same rule the decisions already follow: the check rests on the quote, and a task that arrived
// without one cannot be told from one that failed the check.
@Test func aTaskWithoutAQuoteIsDropped() throws {
    let raw = """
        {"title": "Т", "summary": ["раз"], "decisions": [],
         "tasks": [{"text": "без цитаты", "quote": ""}, {"text": "с цитатой", "quote": "было сказано"}]}
        """
    #expect(try SummaryResponse.parse(raw).tasks.map(\.text) == ["с цитатой"])
}

@Test func aResponseWithoutTasksIsStillValid() throws {
    let summary = try SummaryResponse.parse("{\"title\": \"Т\", \"summary\": [\"раз\"], \"decisions\": []}")
    #expect(summary.tasks.isEmpty)
    #expect(summary.openIssues.isEmpty)
}
