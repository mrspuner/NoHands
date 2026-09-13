import Foundation

/// One person as this meeting knows them: the segments they spoke, their fingerprint, and a
/// local identity `v1`, `v2` given by order of first appearance.
///
/// The identity means nothing outside this file. Between meetings a person is recognised by
/// their print in `VoiceBook`, never by this number.
public struct MeetingVoice: Equatable, Sendable {
    public var id: String
    public var segments: [VoiceSegment]
    public var print: VoicePrint
    public var speechSeconds: TimeInterval

    public init(id: String, segments: [VoiceSegment], print: VoicePrint, speechSeconds: TimeInterval) {
        self.id = id
        self.segments = segments
        self.print = print
        self.speechSeconds = speechSeconds
    }
}
