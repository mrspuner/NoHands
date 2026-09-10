import Foundation

/// `~/Meetings/.voices.json` — the only mutable state phase 2г keeps between meetings.
///
/// An actor because two things write here: the queue, when a meeting brings new fingerprints,
/// and the archive pass, when the owner renames somebody. Beside the archive rather than in
/// Application Support because the audio is gone in a week: a lost book cannot be rebuilt, and
/// everything worth keeping should sit in the one folder the owner already keeps.
public actor VoiceStore {
    private let url: URL

    public static var defaultURL: URL {
        // The path is spelled out here rather than taken from `MeetingFolder`, which lives in
        // `Meetings` — a module that depends on this one. `MeetingsConfig.configFileURL` repeats
        // the config path for the same reason.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
            .appendingPathComponent(".voices.json")
    }

    public init(url: URL = VoiceStore.defaultURL) {
        self.url = url
    }

    /// - Throws: when the file exists and does not parse. Deliberately not an empty book: the
    ///   next save would then write emptiness over fingerprints that nothing can recreate.
    public func book() throws -> VoiceBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceBook.self, from: try Data(contentsOf: url))
    }

    public func save(_ book: VoiceBook) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}
