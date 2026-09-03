import Foundation

/// `meeting.json` — what phase 2б needs and what makes a bad recording explainable afterwards.
///
/// Not a placeholder for the future: 2б needs the start timestamp to place words on a
/// timeline, and "why does this sound wrong" cannot be answered without knowing which input
/// device was recording.
public struct MeetingMetadata: Equatable, Sendable, Codable {
    public struct App: Equatable, Sendable, Codable {
        public var bundleID: String
        public var name: String
        public var slug: String

        public init(bundleID: String, name: String, slug: String) {
            self.bundleID = bundleID
            self.name = name
            self.slug = slug
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case name, slug
        }
    }

    public struct InputDevice: Equatable, Sendable, Codable {
        public var name: String
        public var sampleRate: Double
        public var isNarrowband: Bool

        public init(name: String, sampleRate: Double, isNarrowband: Bool) {
            self.name = name
            self.sampleRate = sampleRate
            self.isNarrowband = isNarrowband
        }
    }

    public enum Track: String, Equatable, Sendable, Codable {
        case system
        case microphone
    }

    /// A stretch where one track received nothing — an unplugged microphone, a stream that
    /// died. Written down rather than silently closed over: phase 2б must not read silence as
    /// speech that was never there.
    public struct Gap: Equatable, Sendable, Codable {
        public var track: Track
        public var from: Date
        public var to: Date

        public init(track: Track, from: Date, to: Date) {
            self.track = track
            self.from = from
            self.to = to
        }
    }

    public enum StopReason: String, Equatable, Sendable, Codable {
        case manual
        case automatic
        case appExited
        case lengthLimit
        case failure
    }

    public var startedAt: Date
    public var stoppedAt: Date?
    public var app: App?
    public var sampleRate: Double
    public var channelCount: Int
    public var inputDevice: InputDevice?
    public var stopReason: StopReason?
    public var excludedApps: [String]
    public var gaps: [Gap]

    public init(
        startedAt: Date,
        stoppedAt: Date?,
        app: App?,
        sampleRate: Double,
        channelCount: Int,
        inputDevice: InputDevice?,
        stopReason: StopReason?,
        excludedApps: [String],
        gaps: [Gap]
    ) {
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.app = app
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.inputDevice = inputDevice
        self.stopReason = stopReason
        self.excludedApps = excludedApps
        self.gaps = gaps
    }

    public static let fileName = "meeting.json"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func write(to url: URL) throws {
        try Self.encoder.encode(self).write(to: url)
    }

    public static func read(from url: URL) throws -> MeetingMetadata {
        try decoder.decode(MeetingMetadata.self, from: Data(contentsOf: url))
    }
}
