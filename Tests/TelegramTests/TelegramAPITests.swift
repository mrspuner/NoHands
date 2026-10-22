import Foundation
import Testing
@testable import Telegram

private let fixture = #"""
{"ok":true,"result":[
 {"update_id":10,"message":{"message_id":5,"from":{"id":111},"chat":{"id":222},"text":"hello"}},
 {"update_id":11,"message":{"message_id":6,"from":{"id":111},"chat":{"id":222},"text":"answer",
   "reply_to_message":{"message_id":4,"from":{"id":1},"chat":{"id":222},"text":"question"}}},
 {"update_id":12,"callback_query":{"id":"cb1","from":{"id":111},"data":"b:1","message":{"message_id":9,"chat":{"id":222}}}},
 {"update_id":13,"edited_message":{"message_id":7}}
]}
"""#

@Test func decodesMessageReplyAndCallback() throws {
    let updates = try TelegramClient.decodeUpdates(Data(fixture.utf8))
    #expect(updates.count == 4)
    #expect(updates[0].updateID == 10)
    #expect(updates[0].message == .init(messageID: 5, fromID: 111, chatID: 222, text: "hello", replyTo: nil))
    #expect(updates[1].message?.replyTo == .init(messageID: 4, text: "question"))
    #expect(updates[2].message == nil)
    #expect(updates[2].callback == .init(id: "cb1", fromID: 111, data: "b:1", messageID: 9))
    #expect(updates[3].message == nil && updates[3].callback == nil)
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func sendBodyCarriesButtonsAsCallbackIndexes() throws {
    let body = try json(TelegramClient.sendBody(chatID: 7, html: "<b>x</b>", replyTo: 3, buttons: ["a", "b"]))
    #expect(body["chat_id"] as? Int == 7)
    #expect(body["text"] as? String == "<b>x</b>")
    #expect(body["parse_mode"] as? String == "HTML")
    let reply = try #require(body["reply_parameters"] as? [String: Any])
    #expect(reply["message_id"] as? Int == 3)
    #expect(reply["allow_sending_without_reply"] as? Bool == true)
    let markup = try #require(body["reply_markup"] as? [String: Any])
    let rows = try #require(markup["inline_keyboard"] as? [[[String: String]]])
    #expect(rows == [[["text": "a", "callback_data": "b:0"]], [["text": "b", "callback_data": "b:1"]]])
}

@Test func sendBodyOmitsMarkupAndReplyWhenAbsent() throws {
    let body = try json(TelegramClient.sendBody(chatID: 7, html: "x", replyTo: nil, buttons: []))
    #expect(body["reply_markup"] == nil)
    #expect(body["reply_parameters"] == nil)
}

@Test func requestTargetsMethodWithJSONAndTimeout() throws {
    let r = TelegramClient.request(token: "T0K", method: "getUpdates", body: Data("{}".utf8), timeout: 60)
    #expect(r.url?.absoluteString == "https://api.telegram.org/botT0K/getUpdates")
    #expect(r.httpMethod == "POST")
    #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(r.timeoutInterval == 60)
}

@Test func apiErrorDoesNotLeakToken() throws {
    let token = "123456:SECRET-token"
    let data = Data(#"{"ok":false,"error_code":400,"description":"bad url /bot123456:SECRET-token/x"}"#.utf8)
    do {
        _ = try TelegramClient.decodeUpdates(data, token: token)
        Issue.record("expected throw")
    } catch let error as TelegramError {
        #expect(error == .api(code: 400, description: "bad url /bot<token>/x"))
        #expect(!(error.errorDescription ?? "").contains(token))
    }
    struct Boom: LocalizedError { var errorDescription: String? { "GET https://api.telegram.org/bot123456:SECRET-token/getUpdates failed" } }
    let transport = TelegramError.wrapping(Boom(), token: token)
    #expect(!(transport.errorDescription ?? "").contains(token))
}

@Test func nonSuccessStatusBecomesApiError() throws {
    let error = TelegramClient.apiError(status: 502, data: Data("<html>".utf8), token: "t")
    #expect(error == .api(code: 502, description: "HTTP 502"))
    let err2 = TelegramClient.apiError(status: 429, data: Data(#"{"ok":false,"error_code":429,"description":"slow down"}"#.utf8), token: "t")
    #expect(err2 == .api(code: 429, description: "slow down"))
}
