import Foundation

/// Settings the owner edits by hand in `~/Library/Application Support/NoHands/config.json`.
///
/// Every key is optional on read and falls back to the default: this file is edited with a
/// text editor, and a missing line must not stop the app. Broken JSON, on the other hand, is
/// reported — silently ignoring it would leave the owner editing a file nothing reads.
public struct DictationConfig: Equatable, Sendable, Codable {
    public struct Sounds: Equatable, Sendable, Codable {
        public var enabled: Bool
        /// Names of system sounds, as `NSSound(named:)` takes them.
        public var start: String
        public var done: String
        public var error: String

        public init(enabled: Bool, start: String, done: String, error: String) {
            self.enabled = enabled
            self.start = start
            self.done = done
            self.error = error
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = DictationConfig.default.sounds
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
            start = try container.decodeIfPresent(String.self, forKey: .start) ?? fallback.start
            done = try container.decodeIfPresent(String.self, forKey: .done) ?? fallback.done
            error = try container.decodeIfPresent(String.self, forKey: .error) ?? fallback.error
        }
    }

    /// ISO-639-1 hint for Parakeet. Not a language switch — the model is multilingual either
    /// way; it only steers decoding towards one script on close calls.
    public var language: String?
    /// Holding fn for less than this is an accidental brush against the key: the recording is
    /// dropped without a sound and without the panel ever appearing.
    public var minimumHoldSeconds: Double
    /// Hard stop, so a forgotten latched recording cannot run all day.
    public var maxRecordingSeconds: Double
    public var model: String
    public var timeoutSeconds: Double
    public var prompt: String
    public var sounds: Sounds

    public static let `default` = DictationConfig(
        language: "ru",
        minimumHoldSeconds: 0.3,
        maxRecordingSeconds: 300,
        model: "deepseek-chat",
        timeoutSeconds: 10,
        prompt: """
        Ты редактор устной речи. Тебе дают расшифровку диктовки как есть.
        Убери слова-заполнители, повторы и самоисправления. Расставь знаки препинания и \
        заглавные буквы. Сохрани язык, смысл, порядок мыслей и терминологию говорящего. \
        Ничего не добавляй, не пересказывай, не отвечай на сказанное и не комментируй. \
        Верни только исправленный текст, без пояснений и без кавычек.
        """,
        sounds: Sounds(enabled: true, start: "Tink", done: "Pop", error: "Basso")
    )

    public init(
        language: String?,
        minimumHoldSeconds: Double,
        maxRecordingSeconds: Double,
        model: String,
        timeoutSeconds: Double,
        prompt: String,
        sounds: Sounds
    ) {
        self.language = language
        self.minimumHoldSeconds = minimumHoldSeconds
        self.maxRecordingSeconds = maxRecordingSeconds
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.prompt = prompt
        self.sounds = sounds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DictationConfig.default
        // `decodeIfPresent` cannot tell "key absent" from "key present but null" — both decode
        // to nil — yet the two must behave differently: absent falls back to the default
        // language, present-and-null means "no language hint" and must stay nil.
        if container.contains(.language) {
            language = try container.decode(String?.self, forKey: .language)
        } else {
            language = fallback.language
        }
        minimumHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .minimumHoldSeconds)
            ?? fallback.minimumHoldSeconds
        maxRecordingSeconds = try container.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds)
            ?? fallback.maxRecordingSeconds
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            ?? fallback.timeoutSeconds
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? fallback.prompt
        sounds = try container.decodeIfPresent(Sounds.self, forKey: .sounds) ?? fallback.sounds
    }

    public static func decode(_ data: Data) throws -> DictationConfig {
        try JSONDecoder().decode(DictationConfig.self, from: data)
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }

    /// Reads the file, or writes the defaults and returns those. Writing on first run means the
    /// owner has a complete file to edit instead of having to remember the key names.
    public static func loadOrCreate(at url: URL = fileURL) throws -> DictationConfig {
        if let data = FileManager.default.contents(atPath: url.path) {
            return try decode(data)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(DictationConfig.default).write(to: url)
        return .default
    }
}
