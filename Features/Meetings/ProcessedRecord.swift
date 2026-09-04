import Foundation

/// `processed.json` — the folder's own record that it has been through the pipeline.
///
/// Without it there is no way to tell a folder whose tracks were compressed from one abandoned
/// halfway. It also answers "where did the file go" a week later, when the audio is gone and
/// only the markdown is left.
public struct ProcessedRecord: Equatable, Sendable, Codable {
    public var processedAt: Date
    /// How long the pipeline took. Kept because it is the one number that says whether the
    /// two-hundred-times-real-time figure holds on real meetings.
    public var elapsedSeconds: Double
    public var meetingDurationSeconds: Double
    public var transcriptPath: String

    public init(
        processedAt: Date, elapsedSeconds: Double, meetingDurationSeconds: Double, transcriptPath: String
    ) {
        self.processedAt = processedAt
        self.elapsedSeconds = elapsedSeconds
        self.meetingDurationSeconds = meetingDurationSeconds
        self.transcriptPath = transcriptPath
    }

    public static let fileName = "processed.json"

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

    public static func read(from url: URL) throws -> ProcessedRecord {
        try decoder.decode(ProcessedRecord.self, from: Data(contentsOf: url))
    }
}
