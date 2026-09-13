import Foundation
import Testing
@testable import Core

private func partial(_ title: String, _ summary: [String], decisions: [String] = [], tasks: [String] = [], issues: [String] = []) -> MeetingSummary {
    MeetingSummary(
        title: title,
        summary: summary,
        decisions: decisions.map { MeetingSummary.Decision(text: $0, quote: "цитата \($0)") },
        tasks: tasks.map { MeetingSummary.Task(text: $0, owner: "", due: "", quote: "цитата \($0)") },
        openIssues: issues
    )
}

// Points are the code's job now: concatenated in meeting order, with nothing rewritten.
@Test func pointsAreConcatenatedInChunkOrder() {
    let combined = SummaryAssembly.combine(
        partials: [
            partial("первый", ["о первом"], decisions: ["решение A"], tasks: ["задача A"], issues: ["вопрос A"]),
            partial("второй", ["о втором"], decisions: ["решение Б"], tasks: ["задача Б"], issues: ["вопрос Б"]),
        ],
        refusals: [],
        merged: partial("вся встреча", ["итог"])
    )
    #expect(combined.decisions.map(\.text) == ["решение A", "решение Б"])
    #expect(combined.tasks.map(\.text) == ["задача A", "задача Б"])
    #expect(combined.openIssues == ["вопрос A", "вопрос Б"])
    #expect(combined.decisions.map(\.quote) == ["цитата решение A", "цитата решение Б"])
}

// The merge decides only the title and the summary — that is the whole reason it never sees a
// decision or a quote and therefore cannot damage one.
@Test func theMergeDecidesOnlyTheTitleAndTheSummary() {
    let combined = SummaryAssembly.combine(
        partials: [partial("первый", ["о первом"], decisions: ["решение A"]), partial("второй", ["о втором"])],
        refusals: [],
        merged: partial("вся встреча", ["итог"], decisions: ["решение, которого не было"])
    )
    #expect(combined.title == "вся встреча")
    #expect(combined.summary == ["итог"])
    #expect(combined.decisions.map(\.text) == ["решение A"])
}

@Test func aSingleChunkNeedsNoMergeAndKeepsItsOwnTitle() {
    let combined = SummaryAssembly.combine(
        partials: [partial("одна часть", ["о ней"], decisions: ["решение A"])],
        refusals: [],
        merged: nil
    )
    #expect(combined.title == "одна часть")
    #expect(combined.summary == ["о ней"])
    #expect(combined.decisions.count == 1)
}

// A chunk whose answer did not parse is named in the file rather than passed over in silence:
// the reader must be able to tell "nothing was said here" from "we could not read it".
@Test func aRefusedChunkIsNamedInTheSummary() {
    let combined = SummaryAssembly.combine(
        partials: [partial("одна часть", ["о ней"])],
        refusals: ["Кусок 2: ответ модели не разобран"],
        merged: nil
    )
    #expect(combined.summary == ["о ней", "Кусок 2: ответ модели не разобран"])
}

// A failed merge costs the title and the summary, never the points: losing a whole meeting's
// decisions over a headline is the trade this project refuses, the same way a failed cleanup
// still inserts the dictated text.
@Test func aFailedMergeKeepsThePointsAndNamesTheReason() {
    let combined = SummaryAssembly.combine(
        partials: [partial("первый", ["о первом"], decisions: ["решение A"]), partial("второй", ["о втором"], tasks: ["задача Б"])],
        refusals: ["Сведение не удалось: ответ модели не разобран"],
        merged: nil
    )
    #expect(combined.title.isEmpty)
    #expect(combined.summary == ["Сведение не удалось: ответ модели не разобран"])
    #expect(combined.decisions.map(\.text) == ["решение A"])
    #expect(combined.tasks.map(\.text) == ["задача Б"])
}
