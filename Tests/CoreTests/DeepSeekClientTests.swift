import Foundation
import Testing
@testable import Core

// `requestFailed`'s message is the entire raw HTTP body from DeepSeek, and the failure panel —
// a fixed-size window — is the only place it is ever shown. Without a limit, several KB of raw
// JSON would crowd out the one thing worth reading: that the request failed at all.

@Test func shortMessagesAreLeftAsIs() {
    #expect(DeepSeekClient.truncatedForDisplay("no body", limit: 200) == "no body")
}

@Test func messagesAtExactlyTheLimitAreLeftAsIs() {
    let text = String(repeating: "a", count: 200)
    #expect(DeepSeekClient.truncatedForDisplay(text, limit: 200) == text)
}

@Test func longMessagesAreCutToTheLimitWithAnEllipsis() {
    let text = String(repeating: "a", count: 500)
    let result = DeepSeekClient.truncatedForDisplay(text, limit: 200)
    #expect(result == String(repeating: "a", count: 200) + "…")
    #expect(result.count == 201)
}
