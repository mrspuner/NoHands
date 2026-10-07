import Foundation

/// The `todoist` section of NoHands's `config.json`: where BigHead lives, which Todoist root
/// projects are its areas, and how to reach `claude`. Edited by hand; every key is optional.
public struct TodoistInboundConfig: Equatable, Sendable, Codable {
    public var bigheadPath: String
    /// Names of the Todoist root projects that are BigHead areas. Everything outside them is
    /// personal and never reaches BigHead.
    public var areas: [String]
    public var claudePath: String
    public var pollSeconds: Double

    public static let `default` = TodoistInboundConfig(bigheadPath: "", areas: [], claudePath: "", pollSeconds: 60)

    /// A shorter interval buys nothing and spends Todoist's rate limit.
    static let minimumPollSeconds: Double = 10

    public init(bigheadPath: String, areas: [String], claudePath: String, pollSeconds: Double) {
        self.bigheadPath = bigheadPath
        self.areas = areas
        self.claudePath = claudePath
        self.pollSeconds = max(pollSeconds, Self.minimumPollSeconds)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bigheadPath: try c.decodeIfPresent(String.self, forKey: .bigheadPath) ?? "",
            areas: try c.decodeIfPresent([String].self, forKey: .areas) ?? [],
            claudePath: try c.decodeIfPresent(String.self, forKey: .claudePath) ?? "",
            pollSeconds: try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 60
        )
    }

    /// Polling needs all three: where to write, what counts as work, what to run.
    public var isComplete: Bool {
        !bigheadPath.isEmpty && !areas.isEmpty && !claudePath.isEmpty
    }

    public static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }

    /// Same contract as `MeetingsConfig.loadOrCreate`: a missing file is never created here
    /// (dictation owns creating it); a missing section is appended with defaults, keeping every
    /// other key in the file.
    public static func loadOrCreate(at url: URL = configFileURL) throws -> TodoistInboundConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TodoistInboundConfigError.notAnObject(url.path)
        }
        if let section = root["todoist"] {
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: section))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        root["todoist"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.default))
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return .default
    }
}

public enum TodoistInboundConfigError: Error, Equatable {
    case notAnObject(String)
}
