import Foundation
import Testing
@testable import Core

@Test func theMergeMessageCarriesOnlySummaries() {
    let message = SummaryPrompt.mergeUser(summaries: [["о первом", "и ещё"], ["о втором"]])
    #expect(message.hasPrefix(SummaryPrompt.mergePrefix))
    #expect(message.contains("Часть 1:"))
    #expect(message.contains("Часть 2:"))
    #expect(message.contains("о первом"))
    #expect(message.contains("о втором"))
    #expect(message.contains(TranscriptEnvelope.openingMarker))
}

// The merge prompt asks for two fields now. Asking for the others would invite the model to
// rewrite points the code already assembled — and its answer for them would be discarded, which
// is worse than not asking: a silently ignored instruction teaches the next reader nothing.
@Test func theMergePromptAsksOnlyForTheTitleAndTheSummary() {
    #expect(SummaryPrompt.merge.contains("title"))
    #expect(SummaryPrompt.merge.contains("summary"))
    #expect(!SummaryPrompt.merge.contains("decisions"))
    #expect(!SummaryPrompt.merge.contains("tasks"))
    #expect(!SummaryPrompt.merge.contains("openIssues"))
    // The one thing standing between a merge and an invented line, now that it no longer has
    // quotes to be checked against.
    #expect(SummaryPrompt.merge.contains("добавляйте ничего"))
}
