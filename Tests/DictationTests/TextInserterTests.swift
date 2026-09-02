import Testing
@testable import Dictation

// Where a paste should go, decided from bundle identifiers alone. Pure: no `CGEvent`, no
// `AXIsProcessTrusted`, no running application lookups — so every branch is testable without a
// machine.

@Test func noBundleIdentifierPastesWhereverFocusIs() {
    #expect(
        TextInserter.ActivationPlan.plan(target: nil, frontmost: "com.other", isRunning: true)
            == .pasteWhereverFocusIs
    )
}

@Test func targetAlreadyFrontmostPastesHere() {
    #expect(
        TextInserter.ActivationPlan.plan(target: "com.target", frontmost: "com.target", isRunning: true)
            == .pasteHere
    )
}

@Test func targetRunningElsewhereNeedsActivation() {
    #expect(
        TextInserter.ActivationPlan.plan(target: "com.target", frontmost: "com.other", isRunning: true)
            == .activate
    )
}

@Test func targetNotRunningIsReported() {
    #expect(
        TextInserter.ActivationPlan.plan(target: "com.target", frontmost: "com.other", isRunning: false)
            == .notRunning
    )
}
