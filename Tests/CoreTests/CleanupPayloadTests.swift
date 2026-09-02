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
    #expect(messages[0]["content"] as? String == "эээ привет")
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
