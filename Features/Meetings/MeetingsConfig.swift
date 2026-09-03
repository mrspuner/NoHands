import Foundation

/// The `meetings` object inside the same `config.json` the dictation settings live in.
///
/// Every key is optional on read and falls back to the default: the file is edited by hand,
/// and a missing line must not stop the app. Two lists that are easy to confuse live here —
/// `triggerApps` decides when a recording starts, `excludedApps` decides whose audio is not
/// written at all.
public struct MeetingsConfig: Equatable, Sendable, Codable {
    public struct TriggerApp: Equatable, Sendable, Codable {
        public var bundleID: String
        /// Goes into the folder name. Optional because the last component of the bundle
        /// identifier is a usable slug for most applications.
        public var slug: String?

        public var resolvedSlug: String {
            if let slug, !slug.isEmpty { return slug }
            return bundleID.split(separator: ".").last.map { $0.lowercased() } ?? bundleID
        }

        public init(bundleID: String, slug: String? = nil) {
            self.bundleID = bundleID
            self.slug = slug
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case slug
        }
    }

    public var triggerApps: [TriggerApp]
    public var excludedApps: [String]
    public var silenceSeconds: Double
    public var autoStopSeconds: Double
    public var startPromptSeconds: Double
    public var maxMeetingSeconds: Double

    public static let `default` = MeetingsConfig(
        triggerApps: [
            TriggerApp(bundleID: "ru.yandex.telemost", slug: "telemost"),
            TriggerApp(bundleID: "us.zoom.xos", slug: "zoom"),
        ],
        excludedApps: [],
        silenceSeconds: 60,
        autoStopSeconds: 120,
        startPromptSeconds: 30,
        maxMeetingSeconds: 14400
    )

    public init(
        triggerApps: [TriggerApp],
        excludedApps: [String],
        silenceSeconds: Double,
        autoStopSeconds: Double,
        startPromptSeconds: Double,
        maxMeetingSeconds: Double
    ) {
        self.triggerApps = triggerApps
        self.excludedApps = excludedApps
        self.silenceSeconds = silenceSeconds
        self.autoStopSeconds = autoStopSeconds
        self.startPromptSeconds = startPromptSeconds
        self.maxMeetingSeconds = maxMeetingSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MeetingsConfig.default
        triggerApps = try container.decodeIfPresent([TriggerApp].self, forKey: .triggerApps)
            ?? fallback.triggerApps
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps)
            ?? fallback.excludedApps
        silenceSeconds = try container.decodeIfPresent(Double.self, forKey: .silenceSeconds)
            ?? fallback.silenceSeconds
        autoStopSeconds = try container.decodeIfPresent(Double.self, forKey: .autoStopSeconds)
            ?? fallback.autoStopSeconds
        startPromptSeconds = try container.decodeIfPresent(Double.self, forKey: .startPromptSeconds)
            ?? fallback.startPromptSeconds
        maxMeetingSeconds = try container.decodeIfPresent(Double.self, forKey: .maxMeetingSeconds)
            ?? fallback.maxMeetingSeconds
    }

    public static func decode(_ data: Data) throws -> MeetingsConfig {
        try JSONDecoder().decode(MeetingsConfig.self, from: data)
    }

    /// The same file the dictation settings live in. Duplicated here rather than imported: the
    /// two features share a file, not a module, and a dependency from `Meetings` to `Dictation`
    /// would exist for one URL.
    public static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }
}

extension MeetingsConfig {
    /// Reads the `meetings` object out of the shared config file, writing the defaults into it
    /// when the key is absent.
    ///
    /// Works on the parsed JSON dictionary rather than on a typed root: the dictation settings
    /// live in the same file under their own keys, and re-encoding a typed root would drop
    /// every key that root does not know about.
    public static func loadOrCreate(at url: URL = configFileURL) throws -> MeetingsConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingsConfigError.notAnObject(url.path)
        }
        if let section = root["meetings"] {
            let sectionData = try JSONSerialization.data(withJSONObject: section)
            return try decode(sectionData)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let defaults = try JSONSerialization.jsonObject(with: encoder.encode(MeetingsConfig.default))
        root["meetings"] = defaults
        let merged = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try merged.write(to: url)
        return .default
    }
}

public enum MeetingsConfigError: Error, Equatable {
    case notAnObject(String)
}
