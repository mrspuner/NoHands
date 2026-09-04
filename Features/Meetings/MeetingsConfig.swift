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
    /// Pause that starts a new utterance. Speech is split on silence, not on punctuation: the
    /// recogniser's full stops are a guess, while a second of nothing is a fact.
    public var phraseGapSeconds: Double
    /// Hard ceiling on one utterance. Without it a ten-minute monologue with no pause long
    /// enough becomes one unreadable line.
    public var maxPhraseSeconds: Double
    /// Below this, an utterance on the microphone track is treated as the room rather than as
    /// the owner. Provisional until measured — see the plan's last task.
    public var micThresholdDBFS: Double
    /// How long compressed audio survives after the meeting started.
    public var audioRetentionDays: Int
    /// AAC bitrate for the archived tracks.
    public var aacBitrate: Int

    /// Both identifiers are read off the applications installed on the owner's machine, not
    /// guessed from their names — `ru.yandex.telemost` was a guess, and the desktop client calls
    /// itself `ru.yandex.desktop.telemost`. The difference is invisible everywhere except a
    /// meeting that never gets recorded, which is why `MeetingsConfigTests` checks these against
    /// the machine rather than against this line.
    public static let `default` = MeetingsConfig(
        triggerApps: [
            TriggerApp(bundleID: "ru.yandex.desktop.telemost", slug: "telemost"),
            TriggerApp(bundleID: "us.zoom.xos", slug: "zoom"),
        ],
        excludedApps: [],
        // Zero, not a minute: the first live meeting showed the wait felt pointless. It is safe
        // precisely because the prompt does not end anything by itself — the recording keeps
        // running while it stands, devices coming back to life withdraws it without cutting the
        // meeting in two, and only `autoStopSeconds` of silence *after* the prompt actually
        // stops. The protection was always in those two rules, never in this delay.
        silenceSeconds: 0,
        autoStopSeconds: 120,
        startPromptSeconds: 30,
        maxMeetingSeconds: 14400,
        phraseGapSeconds: 1.0,
        maxPhraseSeconds: 40,
        // A provisional value, set just so the pipeline builds. Speech at the first live meeting
        // hit three quarters of the scale — around -2.5 dBFS — while the room across the table
        // was reliably quieter. The real value is set by measuring with `nohands meeting levels`.
        micThresholdDBFS: -30,
        audioRetentionDays: 7,
        aacBitrate: 32000
    )

    public init(
        triggerApps: [TriggerApp],
        excludedApps: [String],
        silenceSeconds: Double,
        autoStopSeconds: Double,
        startPromptSeconds: Double,
        maxMeetingSeconds: Double,
        phraseGapSeconds: Double,
        maxPhraseSeconds: Double,
        micThresholdDBFS: Double,
        audioRetentionDays: Int,
        aacBitrate: Int
    ) {
        self.triggerApps = triggerApps
        self.excludedApps = excludedApps
        self.silenceSeconds = silenceSeconds
        self.autoStopSeconds = autoStopSeconds
        self.startPromptSeconds = startPromptSeconds
        self.maxMeetingSeconds = maxMeetingSeconds
        self.phraseGapSeconds = phraseGapSeconds
        self.maxPhraseSeconds = maxPhraseSeconds
        self.micThresholdDBFS = micThresholdDBFS
        self.audioRetentionDays = audioRetentionDays
        self.aacBitrate = aacBitrate
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
        phraseGapSeconds = try container.decodeIfPresent(Double.self, forKey: .phraseGapSeconds)
            ?? fallback.phraseGapSeconds
        maxPhraseSeconds = try container.decodeIfPresent(Double.self, forKey: .maxPhraseSeconds)
            ?? fallback.maxPhraseSeconds
        micThresholdDBFS = try container.decodeIfPresent(Double.self, forKey: .micThresholdDBFS)
            ?? fallback.micThresholdDBFS
        audioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .audioRetentionDays)
            ?? fallback.audioRetentionDays
        aacBitrate = try container.decodeIfPresent(Int.self, forKey: .aacBitrate)
            ?? fallback.aacBitrate
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
    /// when the key is absent from an existing file. When the file itself does not exist,
    /// nothing is written — defaults are returned in memory and the file is left absent.
    ///
    /// Works on the parsed JSON dictionary rather than on a typed root: the dictation settings
    /// live in the same file under their own keys, and re-encoding a typed root would drop
    /// every key that root does not know about.
    public static func loadOrCreate(at url: URL = configFileURL) throws -> MeetingsConfig {
        // Unlike `DictationConfig.loadOrCreate`, a missing file is not created here. Dictation
        // owns creating `config.json` with its own template on first run; if `Meetings` created
        // it first, the file would carry only a `meetings` section, and `DictationConfig`'s next
        // call would see an existing file and skip writing its own defaults into it — the owner
        // would be left without a dictation template. `Meetings` only ever appends a section to
        // a file dictation already created.
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
