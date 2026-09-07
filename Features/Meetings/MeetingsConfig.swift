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
    /// Below this, an utterance on the microphone track is treated as something other than the
    /// owner speaking. On the first meeting measured, that turned out to be the interlocutor's
    /// own voice leaking onto the microphone track — the design had assumed headphones would keep
    /// it out and they did not — running 23 dB below the owner's speech, which is the gap that
    /// makes a level gate work here at all.
    public var micThresholdDBFS: Double
    /// How long compressed audio survives after the meeting started.
    ///
    /// The disk is 256 GB and fifteen hours of meetings a week is 3.4 GB of raw WAV; a week's
    /// sliding window of compressed tracks is around 400 MB instead. Deleting immediately was
    /// rejected in phase 2а for a different reason than space: it would make the first
    /// transcription attempt the only one, leaving nothing to re-run against when the audio
    /// turns out to be bad.
    public var audioRetentionDays: Int
    /// AAC bitrate for the archived tracks.
    ///
    /// 32 kbit/s is roughly 14 MB per hour per track — speech at 16 kHz survives it, and this
    /// is the number that turns the arithmetic above from gigabytes into megabytes.
    public var aacBitrate: Int
    /// Whether the summary step runs at all. A switch rather than a decision: if the model turns
    /// out to get in the way of real work, the archive should keep filling with transcripts.
    public var summaryEnabled: Bool
    public var summaryModel: String
    /// Configured rather than looked up: an application launched from Finder has a PATH that does
    /// not include `~/.local/bin`.
    public var uvPath: String
    /// Measured: 2 minutes on a 71-minute meeting, so a four-hour one lands around 7. The rest is
    /// headroom for a cold model load and for `uv` fetching packages after a cache wipe.
    public var summaryTimeoutSeconds: Double
    /// 32k window minus the answer and the system part.
    public var summaryContextTokens: Int
    /// Share of a quote's longest run that has to be found in the transcript. Measured: real
    /// quotes 65–100%, invented or foreign ones 12–18%, so the threshold sits in the gap.
    public var quoteMatchRatio: Double
    /// Length of one chunk in seconds. Fifteen minutes is the length of the meeting that ran on
    /// this machine on 2026-09-07 and produced the best summary of that day, while the
    /// sixty-eight-minute one took ten gigabytes and was killed by the system.
    public var summaryChunkSeconds: Double

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
        // Measured on the live meeting of 2026-09-04, like the threshold below. At one second the
        // owner's speech and the interlocutor's voice leaking onto the same track merged into
        // single utterances loud enough to pass the gate whole, and the transcript then put the
        // other person's words under the owner's name three separate times. Half a second
        // separated all three. The cost is an occasional cut mid-sentence, which is cosmetic
        // against saying someone said something they did not.
        phraseGapSeconds: 0.5,
        maxPhraseSeconds: 40,
        // Measured on the live meeting of 2026-09-04, not guessed. Own speech on the microphone
        // track ran from -15.1 to -26.3 dBFS; the interlocutor's voice leaking onto that same
        // track ran from -49.3 to -53.1. This sits in the middle of that 23 dB gap — 14 dB of
        // room below the quietest speech measured, 9 dB above the loudest leak.
        micThresholdDBFS: -40,
        audioRetentionDays: 7,
        aacBitrate: 32000,
        summaryEnabled: true,
        summaryModel: "mlx-community/Qwen3-8B-4bit",
        uvPath: "~/.local/bin/uv",
        summaryTimeoutSeconds: 900,
        summaryContextTokens: 28_000,
        quoteMatchRatio: 0.4,
        summaryChunkSeconds: 900
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
        aacBitrate: Int,
        summaryEnabled: Bool = true,
        summaryModel: String = "mlx-community/Qwen3-8B-4bit",
        uvPath: String = "~/.local/bin/uv",
        summaryTimeoutSeconds: Double = 900,
        summaryContextTokens: Int = 28_000,
        quoteMatchRatio: Double = 0.4,
        summaryChunkSeconds: Double = 900
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
        self.summaryEnabled = summaryEnabled
        self.summaryModel = summaryModel
        self.uvPath = uvPath
        self.summaryTimeoutSeconds = summaryTimeoutSeconds
        self.summaryContextTokens = summaryContextTokens
        self.quoteMatchRatio = quoteMatchRatio
        self.summaryChunkSeconds = summaryChunkSeconds
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
        summaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .summaryEnabled)
            ?? fallback.summaryEnabled
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
            ?? fallback.summaryModel
        uvPath = try container.decodeIfPresent(String.self, forKey: .uvPath) ?? fallback.uvPath
        summaryTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .summaryTimeoutSeconds)
            ?? fallback.summaryTimeoutSeconds
        summaryContextTokens = try container.decodeIfPresent(Int.self, forKey: .summaryContextTokens)
            ?? fallback.summaryContextTokens
        quoteMatchRatio = try container.decodeIfPresent(Double.self, forKey: .quoteMatchRatio)
            ?? fallback.quoteMatchRatio
        summaryChunkSeconds = try container.decodeIfPresent(Double.self, forKey: .summaryChunkSeconds)
            ?? fallback.summaryChunkSeconds
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
