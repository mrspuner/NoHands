import Testing
@testable import Core

@Test func reportStatesTheRateAndCounts() {
    let result = WordDiff.compare(
        reference: ["раз", "два", "три", "четыре"],
        candidate: ["раз", "два", "три", "пять"]
    )
    let report = ComparisonReport.render(result)
    #expect(report.contains("25.0%"))
    #expect(report.contains("замен: 1"))
    #expect(report.contains("пропусков: 0"))
    #expect(report.contains("лишних: 0"))
}

@Test func reportShowsEachDivergenceWithBothVariants() {
    let result = WordDiff.compare(
        reference: ["выкатили", "новую", "версию"],
        candidate: ["выкатили", "новую", "версии"]
    )
    let report = ComparisonReport.render(result)
    #expect(report.contains("версию"))
    #expect(report.contains("версии"))
}

@Test func identicalTextsReportNoDivergences() {
    let result = WordDiff.compare(reference: ["раз", "два"], candidate: ["раз", "два"])
    let report = ComparisonReport.render(result)
    #expect(report.contains("0.0%"))
    #expect(report.contains("расхождений нет"))
}
