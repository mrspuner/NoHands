import Core
import Foundation

/// Decides from the config and the Keychain whether the bot runs, and with what. Kept out of the
/// app target, which has no tests, so the rules for the status line are checked here.
public enum TelegramSetup {
    /// Everything a running bot depends on; a change in any of them means a new bot.
    public struct BotInputs: Equatable, Sendable {
        public var token: String
        public var ownerID: Int64
        public var inbox: URL

        public init(token: String, ownerID: Int64, inbox: URL) {
            self.token = token
            self.ownerID = ownerID
            self.inbox = inbox
        }
    }

    public enum Outcome: Equatable, Sendable {
        case ready(BotInputs)
        /// Carries the status-line note saying why the bot does not run.
        case notRunning(String)
    }

    /// The token is read last, and only for a bot that is switched on and has an owner and an
    /// inbox: a Keychain dialog for a feature the owner has not turned on would be noise.
    public static func bot(config: TelegramConfig, bigheadPath: String,
                           readToken: () throws -> String?) -> Outcome {
        guard config.isComplete, let ownerID = config.ownerUserId else {
            return .notRunning("телеграм: не настроен")
        }
        guard !bigheadPath.isEmpty else {
            return .notRunning("телеграм: не настроен (bigheadPath в разделе todoist)")
        }
        let token: String?
        do {
            token = try readToken()
        } catch {
            // Not folded into "no token": a refused Keychain prompt would send the owner looking
            // for a token that is right there.
            return .notRunning("телеграм: \(error.localizedDescription)")
        }
        guard let token, !token.isEmpty else {
            return .notRunning("телеграм: не настроен (нет токена в связке ключей)")
        }
        let inbox = URL(fileURLWithPath: bigheadPath)
            .appendingPathComponent("wiki").appendingPathComponent("inbox.md")
        return .ready(BotInputs(token: token, ownerID: ownerID, inbox: inbox))
    }

    /// The agent's paths live in the `todoist` section, where the other two ingests read them.
    /// `nil` switches the reply agent off.
    public static func replySettings(claudePath: String, bigheadPath: String, timeout: TimeInterval,
                                     hook: [String]) -> ReplyAgent.Settings? {
        guard !claudePath.isEmpty, !bigheadPath.isEmpty else { return nil }
        return ReplyAgent.Settings(claude: URL(fileURLWithPath: claudePath),
                                   bighead: URL(fileURLWithPath: bigheadPath), timeout: timeout, hook: hook)
    }
}

extension Notice {
    /// The red panel line for this notice.
    public var panelText: String {
        switch self {
        case .deliveryStalled: "Телеграм: не отправляется больше часа"
        case .stateUnreadable: "Телеграм: файл состояния не читается, бот остановлен"
        }
    }
}

extension ReplyAgent {
    /// The red panel line for a failed run; the chat gets `failureText` instead.
    public static func panelText(_ failure: AgentFailure) -> String {
        "Реплика из Телеграма не обработана: \(failure.ownerReason)"
    }
}
