import Foundation
import Testing
@testable import Core

// Without this parameter the model spends its whole output budget reasoning and never reaches
// an answer — thirty five times the output tokens, forty cents a month becoming fourteen
// dollars. It is the single most expensive thing that can silently go missing from this file.
@Test func requestAlwaysDisablesThinking() throws {
    let body = try CleanupPayload.body(model: "m", maxTokens: 100, prompt: "p", text: "t")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let thinking = try #require(json["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "disabled")
}

@Test func requestCarriesModelPromptAndText() throws {
    let body = try CleanupPayload.body(model: "deepseek-chat", maxTokens: 512, prompt: "чисти", text: "эээ привет")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "deepseek-chat")
    #expect(json["system"] as? String == "чисти")
    #expect(json["max_tokens"] as? Int == 512)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == CleanupPayload.wrapped("эээ привет"))
}

// The transcript must land inside the markers, not replace them — a bug where the wrapping
// helper degenerated to returning the bare text back would slip past a test that only checked
// the markers were present somewhere in the string.
@Test func userTurnHoldsTheTranscriptInsideTheMarkers() throws {
    let body = try CleanupPayload.body(model: "deepseek-chat", maxTokens: 512, prompt: "чисти", text: "эээ привет")
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? String)
    #expect(content.hasPrefix(CleanupPayload.openingMarker))
    #expect(content.hasSuffix(CleanupPayload.closingMarker))
    #expect(content.contains("эээ привет"))
}

// The bug this guards against: a dictation that reads as a complete, actionable request —
// "объясни, как работает фотосинтез" — arrived as a bare user turn, which made it the more
// specific instruction than the system prompt, and the model answered it instead of
// transcribing it. Measured live: three of eight such dictations came back as answers before
// this wrapping, none after. This test only checks the request's shape — that the transcript is
// delivered as marked-off content rather than a bare instruction — not what the model does with
// it, which cannot be tested without the live service.
@Test func dictationThatReadsAsAQuestionIsStillDeliveredAsWrappedData() throws {
    let instructionLikeText = "объясни как работает фотосинтез"
    let body = try CleanupPayload.body(model: "deepseek-chat", maxTokens: 512, prompt: "чисти", text: instructionLikeText)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? String)
    #expect(content != instructionLikeText)
    #expect(content == CleanupPayload.wrapped(instructionLikeText))
}

@Test func responseYieldsTheTextBlock() throws {
    let data = Data(#"{"content":[{"type":"text","text":"Привет."}]}"#.utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

// Blocks other than text can appear alongside the answer; taking the first block blindly would
// return an empty string on those days.
@Test func responseSkipsNonTextBlocks() throws {
    let data = Data(#"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"Привет."}]}"#.utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

@Test func responseTrimsSurroundingWhitespace() throws {
    let data = Data("{\"content\":[{\"type\":\"text\",\"text\":\"  Привет.\\n\"}]}".utf8)
    #expect(try CleanupPayload.text(from: data) == "Привет.")
}

// An empty answer must not become an empty paste. Same rule as TranscriberChecks.nonEmpty.
@Test func emptyContentIsAnError() {
    #expect(throws: CleanupError.emptyResult) {
        try CleanupPayload.text(from: Data(#"{"content":[]}"#.utf8))
    }
}

@Test func blankTextIsAnError() {
    #expect(throws: CleanupError.emptyResult) {
        try CleanupPayload.text(from: Data(#"{"content":[{"type":"text","text":"   "}]}"#.utf8))
    }
}

// A tiny dictation must not be handed a budget too small to hold punctuation and
// capitalization fixes around it.
@Test func tokenBudgetFloorsAShortText() {
    #expect(CleanupPayload.tokenBudget(forCharacters: 10) == 256)
}

@Test func tokenBudgetScalesWithLength() {
    #expect(CleanupPayload.tokenBudget(forCharacters: 1000) == 3000)
}

// DeepSeek's documented output ceiling for the model `deepseek-chat` resolves to
// (deepseek-v4-flash) is 384,000 tokens. A five-minute dictation's proportional budget stays
// far below it, but nothing should ever ask the service for more than it can give.
@Test func tokenBudgetCapsAtTheDocumentedCeiling() {
    #expect(CleanupPayload.tokenBudget(forCharacters: 200_000) == 384_000)
}
