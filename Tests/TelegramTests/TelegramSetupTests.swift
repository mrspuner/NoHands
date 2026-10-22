import Core
import Foundation
import Testing
@testable import Telegram

private let complete = TelegramConfig(enabled: true, ownerUserId: 42, replyTimeoutSeconds: 900)

private struct Refused: LocalizedError {
    var errorDescription: String? { "keychain refused" }
}

@Test func aSwitchedOffBotIsNotSetUpAndTheKeychainIsNotAsked() {
    var asked = false
    let outcome = TelegramSetup.bot(
        config: TelegramConfig(enabled: false, ownerUserId: 42, replyTimeoutSeconds: 900),
        claudePath: "/c", bigheadPath: "/b", readToken: { asked = true; return "t" })
    #expect(outcome == .notRunning("телеграм: не настроен"))
    #expect(!asked)
}

@Test func aMissingOwnerIsNotSetUp() {
    let outcome = TelegramSetup.bot(
        config: TelegramConfig(enabled: true, ownerUserId: nil, replyTimeoutSeconds: 900),
        claudePath: "/c", bigheadPath: "/b", readToken: { "t" })
    #expect(outcome == .notRunning("телеграм: не настроен"))
}

@Test func aMissingBigheadPathIsNamed() {
    var asked = false
    let outcome = TelegramSetup.bot(config: complete, claudePath: "/c", bigheadPath: "", readToken: { asked = true; return "t" })
    #expect(outcome == .notRunning("телеграм: не настроен (bigheadPath в разделе todoist)"))
    #expect(!asked)
}

@Test func aMissingClaudePathIsNamed() {
    // Otherwise the bot would answer «Принял» to replies no agent can ever run.
    var asked = false
    let outcome = TelegramSetup.bot(config: complete, claudePath: "", bigheadPath: "/b",
                                    readToken: { asked = true; return "t" })
    #expect(outcome == .notRunning("телеграм: не настроен (claudePath в разделе todoist)"))
    #expect(!asked)
}

@Test func aMissingTokenIsNotSetUp() {
    #expect(TelegramSetup.bot(config: complete, claudePath: "/c", bigheadPath: "/b", readToken: { nil })
        == .notRunning("телеграм: не настроен (нет токена в связке ключей)"))
    #expect(TelegramSetup.bot(config: complete, claudePath: "/c", bigheadPath: "/b", readToken: { "" })
        == .notRunning("телеграм: не настроен (нет токена в связке ключей)"))
}

@Test func aKeychainFailureIsNamedRatherThanCalledMissing() {
    let outcome = TelegramSetup.bot(config: complete, claudePath: "/c", bigheadPath: "/b", readToken: { throw Refused() })
    #expect(outcome == .notRunning("телеграм: keychain refused"))
}

@Test func aCompleteSetupGivesTheBotItsInputs() {
    let outcome = TelegramSetup.bot(config: complete, claudePath: "/c", bigheadPath: "/Users/x/BigHead", readToken: { "t" })
    #expect(outcome == .ready(TelegramSetup.BotInputs(
        token: "t", ownerID: 42, inbox: URL(fileURLWithPath: "/Users/x/BigHead/wiki/inbox.md"))))
}

@Test func replySettingsNeedBothPaths() {
    #expect(TelegramSetup.replySettings(claudePath: "", bigheadPath: "/b", timeout: 900, hook: ["/h"]) == nil)
    #expect(TelegramSetup.replySettings(claudePath: "/c", bigheadPath: "", timeout: 900, hook: ["/h"]) == nil)
    #expect(TelegramSetup.replySettings(claudePath: "/c", bigheadPath: "/b", timeout: 60, hook: ["/h", "-x"])
        == ReplyAgent.Settings(claude: URL(fileURLWithPath: "/c"), bighead: URL(fileURLWithPath: "/b"), timeout: 60,
                               hook: ["/h", "-x"]))
}

@Test func noticesHaveTheirPanelLines() {
    #expect(Notice.deliveryStalled(since: Date()).panelText == "Телеграм: не отправляется больше часа")
    #expect(Notice.stateUnreadable.panelText == "Телеграм: файл состояния не читается, бот остановлен")
}

@Test func aFailedReplyHasItsPanelLine() {
    let failure = AgentFailure.timedOut(900)
    #expect(ReplyAgent.panelText(failure) == "Реплика из Телеграма не обработана: \(failure.ownerReason)")
}
