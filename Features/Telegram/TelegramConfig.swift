import Foundation

/// The `telegram` section of NoHands's `config.json`. Edited by hand; every key is optional.
public struct TelegramConfig: Equatable, Sendable, Codable {
    public var enabled: Bool
    /// Telegram user id of the only person the bot answers; messages from anyone else are dropped.
    public var ownerUserId: Int64?
    /// How long the agent may work on one batch of messages before it counts as failed.
    public var replyTimeoutSeconds: Double

    public static let `default` = TelegramConfig(enabled: false, ownerUserId: nil, replyTimeoutSeconds: 900)

    public init(enabled: Bool, ownerUserId: Int64?, replyTimeoutSeconds: Double) {
        self.enabled = enabled
        self.ownerUserId = ownerUserId
        self.replyTimeoutSeconds = replyTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            ownerUserId: try c.decodeIfPresent(Int64.self, forKey: .ownerUserId),
            replyTimeoutSeconds: try c.decodeIfPresent(Double.self, forKey: .replyTimeoutSeconds) ?? 900
        )
    }

    /// The bot runs only when switched on and told whose messages to accept.
    public var isComplete: Bool { enabled && ownerUserId != nil }

    /// Same file as `TodoistInboundConfig.configFileURL`; `TodoistSync` is not reachable from here.
    public static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }

    /// Same contract as `TodoistInboundConfig.loadOrCreate`: a missing file is never created here;
    /// a missing section is appended with defaults, keeping every other key in the file.
    public static func loadOrCreate(at url: URL = configFileURL) throws -> TelegramConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TelegramConfigError.notAnObject(url.path)
        }
        if let section = root["telegram"] {
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: section))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        root["telegram"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.default))
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return .default
    }
}

public enum TelegramConfigError: Error, Equatable {
    case notAnObject(String)
}
