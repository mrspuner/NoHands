import Foundation
import Testing
@testable import CLI

@Test func sendTakesAFile() throws {
    let parsed = try TelegramArguments.parse(["telegram", "send", "/tmp/a.md"])
    #expect(parsed == .send(URL(fileURLWithPath: "/tmp/a.md")))
}

@Test func sendWithoutAFileIsRefused() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "send"])
    }
}

@Test func sendTakesNothingElse() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "send", "/tmp/a.md", "--bighead", "/x"])
    }
}

@Test func replyTakesTheText() throws {
    let parsed = try TelegramArguments.parse(["telegram", "reply", "привет"])
    #expect(parsed == .reply(text: "привет", bighead: nil))
}

@Test func replyTakesABigheadOverride() throws {
    let parsed = try TelegramArguments.parse(["telegram", "reply", "привет", "--bighead", "/tmp/scratch"])
    #expect(parsed == .reply(text: "привет", bighead: URL(fileURLWithPath: "/tmp/scratch")))
}

@Test func aBigheadOverrideWithoutAValueIsRefused() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "reply", "привет", "--bighead"])
    }
}

@Test func anEmptyReplyIsRefused() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "reply", "  "])
    }
}

@Test func anUnknownTelegramSubcommandIsRefused() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "poll"])
    }
}

@Test func bashHookIsParsed() throws {
    #expect(try TelegramArguments.parse(["telegram", "bash-hook"]) == .bashHook)
}

@Test func bashHookTakesNothingElse() {
    #expect(throws: TelegramArguments.ParseError.self) {
        try TelegramArguments.parse(["telegram", "bash-hook", "x"])
    }
}
