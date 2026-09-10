import Foundation

/// One fingerprint taken from one meeting.
public struct StoredPrint: Equatable, Sendable, Codable {
    public var meeting: String
    public var seconds: Double
    public var vector: [Float]

    public init(meeting: String, seconds: Double, vector: [Float]) {
        self.meeting = meeting
        self.seconds = seconds
        self.vector = vector
    }

    private enum CodingKeys: String, CodingKey {
        case meeting, seconds, vector
    }

    /// Base64 rather than an array of numbers: 256 floats times ten prints times a dozen voices
    /// is a file nobody can read, and this file lives beside the archive precisely so it can be
    /// opened and understood.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meeting = try container.decode(String.self, forKey: .meeting)
        seconds = try container.decode(Double.self, forKey: .seconds)
        let encoded = try container.decode(String.self, forKey: .vector)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .vector, in: container, debugDescription: "vector is not base64"
            )
        }
        vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting, forKey: .meeting)
        try container.encode(seconds, forKey: .seconds)
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try container.encode(data.base64EncodedString(), forKey: .vector)
    }
}

/// A person the archive has heard before.
public struct Voice: Equatable, Sendable, Codable {
    public var id: String
    public var name: String?
    public var prints: [StoredPrint]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String?, prints: [StoredPrint], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.prints = prints
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Which voice each header position of one meeting file stands for.
///
/// `renderedName` is what the application itself last wrote there. The header is compared
/// against it — that is the whole way an edit by the owner is told apart from what the
/// application put there on its own.
public struct MeetingLabels: Equatable, Sendable, Codable {
    public struct Label: Equatable, Sendable, Codable {
        public var position: Int
        /// `nil` for a voice too brief to store and unknown to the book: it is in the file and
        /// in the header, but there is no fingerprint for a name to attach to. The row exists
        /// anyway, because the header is matched to these rows position by position — a missing
        /// row would make an ordinary meeting look like an edited one.
        public var voiceId: String?
        public var renderedName: String

        public init(position: Int, voiceId: String?, renderedName: String) {
            self.position = position
            self.voiceId = voiceId
            self.renderedName = renderedName
        }
    }

    public var file: String
    public var labels: [Label]

    public init(file: String, labels: [Label]) {
        self.file = file
        self.labels = labels
    }
}

/// The whole of `~/Meetings/.voices.json`, as a value.
///
/// Pure on purpose: reading and writing the file is `VoiceStore`'s job, and everything that
/// decides who is who is testable without touching a disk.
public struct VoiceBook: Equatable, Sendable, Codable {
    public var version: Int
    public var voices: [Voice]
    public var meetings: [MeetingLabels]

    public static let empty = VoiceBook(version: 1, voices: [], meetings: [])

    public init(version: Int, voices: [Voice], meetings: [MeetingLabels]) {
        self.version = version
        self.voices = voices
        self.meetings = meetings
    }

    /// The nearest voice, if it is near enough — by the closest of its prints rather than by
    /// their average, so that one bad connection does not drag a whole identity sideways.
    public func match(_ print: VoicePrint, threshold: Float) -> Voice? {
        var best: (voice: Voice, score: Float)?
        for voice in voices {
            for stored in voice.prints {
                let score = VoicePrint.cosine(print, VoicePrint(vector: stored.vector))
                guard score >= threshold else { continue }
                if best == nil || score > best!.score { best = (voice, score) }
            }
        }
        return best?.voice
    }

    /// Adds a print to `voiceId`, or starts a new voice when it is `nil`.
    /// - Returns: the identity the print now belongs to.
    @discardableResult
    public mutating func remember(
        _ print: VoicePrint,
        meeting: String,
        seconds: Double,
        as voiceId: String?,
        maxPrints: Int,
        now: Date = Date()
    ) -> String {
        let stored = StoredPrint(meeting: meeting, seconds: seconds, vector: print.vector)
        if let voiceId, let index = voices.firstIndex(where: { $0.id == voiceId }) {
            voices[index].prints.append(stored)
            // Oldest first out: a voice should be described by how it sounds now.
            if voices[index].prints.count > maxPrints {
                voices[index].prints.removeFirst(voices[index].prints.count - maxPrints)
            }
            voices[index].updatedAt = now
            return voiceId
        }
        let fresh = Voice(
            id: UUID().uuidString, name: nil, prints: [stored], createdAt: now, updatedAt: now
        )
        voices.append(fresh)
        return fresh.id
    }

    /// Names a voice — and, when that name already belongs to another voice, merges the two.
    ///
    /// The merge is the point rather than a side effect: writing one name over two rows of the
    /// header is how the owner repairs a split the automatic clustering missed, and it is the
    /// only way the application ever learns that two fingerprints are one person.
    public mutating func rename(_ voiceId: String, to name: String) {
        guard let index = voices.firstIndex(where: { $0.id == voiceId }) else { return }
        if let twin = voices.firstIndex(where: { $0.name == name && $0.id != voiceId }) {
            let absorbed = voices.remove(at: index)
            let keep = twin > index ? twin - 1 : twin
            voices[keep].prints.append(contentsOf: absorbed.prints)
            voices[keep].updatedAt = max(voices[keep].updatedAt, absorbed.updatedAt)
            // Every row of every meeting that pointed at the absorbed voice has to follow it,
            // or the archive would hold labels pointing at an identity that no longer exists.
            for meeting in meetings.indices {
                for label in meetings[meeting].labels.indices
                where meetings[meeting].labels[label].voiceId == absorbed.id {
                    meetings[meeting].labels[label].voiceId = voices[keep].id
                }
            }
            return
        }
        voices[index].name = name
    }

    public func name(of voiceId: String) -> String? {
        voices.first { $0.id == voiceId }?.name
    }

    public mutating func record(_ labels: MeetingLabels) {
        meetings.removeAll { $0.file == labels.file }
        meetings.append(labels)
    }

    public func labels(for file: String) -> MeetingLabels? {
        meetings.first { $0.file == file }
    }
}
