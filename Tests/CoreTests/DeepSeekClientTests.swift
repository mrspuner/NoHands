import Foundation
import os
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

// The key is read through the Keychain, and `NoHands.app` is not in that item's access list —
// so the first read raises a system authorization dialog. Reading it once per cleanup put that
// dialog in the middle of every dictation, after the owner had already spoken. It is resolved
// once and kept.

@Test func theKeyIsResolvedOnlyOnce() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let client = DeepSeekClient(model: "m", prompt: "p", timeout: 1) {
        reads.withLock { $0 += 1 }
        return "secret"
    }

    #expect(try await client.resolvedKey() == "secret")
    #expect(try await client.resolvedKey() == "secret")
    #expect(reads.withLock { $0 } == 1)
}

// A failure must not be cached: the owner may add the key while the app is running, and
// should not have to restart it to be believed.
@Test func aFailedLookupIsRetriedNextTime() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let client = DeepSeekClient(model: "m", prompt: "p", timeout: 1) {
        reads.withLock { $0 += 1 }
        return nil
    }

    await #expect(throws: CleanupError.apiKeyMissing) { try await client.resolvedKey() }
    await #expect(throws: CleanupError.apiKeyMissing) { try await client.resolvedKey() }
    #expect(reads.withLock { $0 } == 2)
}

// Warming up moves the dialog to launch, where waiting costs nothing, instead of leaving it in
// the dictation path where it costs a spoken sentence.
@Test func warmingUpResolvesTheKeyAheadOfTheFirstCleanup() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let client = DeepSeekClient(model: "m", prompt: "p", timeout: 1) {
        reads.withLock { $0 += 1 }
        return "secret"
    }

    await client.warmUp()
    #expect(reads.withLock { $0 } == 1)
    #expect(try await client.resolvedKey() == "secret")
    #expect(reads.withLock { $0 } == 1)
}

// Warming up must never throw: a missing key is a cleanup-time failure by design, not a
// launch-time one.
@Test func warmingUpSwallowsAMissingKey() async {
    let client = DeepSeekClient(model: "m", prompt: "p", timeout: 1) { nil }
    await client.warmUp()
}
