import Foundation
import Testing

@testable import Core

private let index = TranscriptIndex.parse("""
    ## Транскрипт

    [00:00:07] Я: Помимо неверных, существуют и пустышки.
    [00:41:12] Собеседник: Они тратят время и ресурсы, не создавая ни прибыли.
    """)

@Test func aVerbatimQuoteMatchesWhole() {
    let result = QuoteMatch.find(quote: "они тратят время и ресурсы", in: index)
    #expect(result.ratio == 1.0)
    #expect(result.line == 1)
}

@Test func caseAndYoAndPunctuationDoNotMatter() {
    #expect(QuoteMatch.find(quote: "ПОМИМО НЕВЕРНЫХ — СУЩЕСТВУЮТ!", in: index).ratio == 1.0)
}

// Control from the probe: a fabricated decision from phase 0 scored 12%, a phrase from another
// meeting 14%, corporate filler 18%. All of that has to stay well below the 0.4 threshold.
@Test func aPhraseFromAnotherMeetingScoresFarBelowTheThreshold() {
    let result = QuoteMatch.find(quote: "переозвучить видеоролик и устранить водность", in: index)
    #expect(result.ratio < 0.4)
}

@Test func nothingAtAllIsZeroRatherThanACrash() {
    #expect(QuoteMatch.find(quote: "", in: index).ratio == 0)
    #expect(QuoteMatch.find(quote: "зззз", in: index).line == nil)
}

// Replies run as one stream of words, so a quote that starts in one and ends in the next is
// found whole. Its timecode is that of the reply where it started.
@Test func aRunSpanningTwoRepliesReportsTheFirst() {
    let result = QuoteMatch.find(quote: "и пустышки они тратят время", in: index)
    #expect(result.ratio == 1.0)
    #expect(result.line == 0)
}

@Test func aQuoteBelowTheThresholdLosesItsTimecodeButKeepsItsRatio() {
    let decisions = [
        MeetingSummary.Decision(text: "настоящее", quote: "они тратят время и ресурсы"),
        MeetingSummary.Decision(text: "выдуманное", quote: "переозвучить видеоролик и водность"),
    ]
    let checked = QuoteMatch.check(decisions, against: index, threshold: 0.4)
    #expect(checked[0].timecode == 2472)
    #expect(checked[1].timecode == nil)
    #expect(checked[1].ratio > 0)
    #expect(checked.map(\.text) == ["настоящее", "выдуманное"])
}
