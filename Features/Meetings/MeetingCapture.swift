import Core
import Foundation

/// What the coordinator needs from a capture, and nothing else.
///
/// One protocol with one real implementation, which is normally a smell. It earns its place for
/// one reason: an `SCStream` cannot be built in a test process, and without this seam every test
/// of the folder lifecycle — draft created, metadata written, rename after the files close —
/// would need a screen recording permission and a live display. The rules those tests cover are
/// not about audio at all.
public protocol MeetingCapture: Sendable {
    func start() async throws
    func stop() async throws -> MeetingAudioRecorder.Outcome
}

extension MeetingAudioRecorder: MeetingCapture {}
