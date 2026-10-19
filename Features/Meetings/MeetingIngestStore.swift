import Foundation

/// What the hand-over of finished meeting files to BigHead remembers between launches.
/// Lives outside the repository, next to the other app state.
public struct MeetingIngestState: Codable, Equatable, Sendable {
    /// The moment the feature first ran. Files older than this are not handed over: switching
    /// the feature on must not flood the agent with the whole archive.
    public var enabledAt: Date
    /// File names (not paths) already handed over, in the order they were marked.
    public var handedOver: [String]

    public init(enabledAt: Date, handedOver: [String] = []) {
        self.enabledAt = enabledAt
        self.handedOver = handedOver
    }
}

public actor MeetingIngestStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/meeting-ingest-state.json")
    }

    private let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// A missing file is the first run: the state starts now and is saved at once, so
    /// `enabledAt` is fixed on the first call and never moves afterwards. A file that exists
    /// but does not parse throws and is not touched — replacing it would silently reset
    /// `enabledAt` and hand the whole archive over.
    public func load() throws -> MeetingIngestState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = MeetingIngestState(enabledAt: now())
            try write(fresh)
            return fresh
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingIngestState.self, from: Data(contentsOf: url))
    }

    public func markHandedOver(_ name: String) throws {
        var state = try load()
        guard !state.handedOver.contains(name) else { return }
        state.handedOver.append(name)
        try write(state)
    }

    private func write(_ state: MeetingIngestState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
