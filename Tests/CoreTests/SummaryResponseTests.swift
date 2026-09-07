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
