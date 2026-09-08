import Core
import Foundation

/// What the coordinator needs from a capture, and nothing else.
///
/// One protocol with one real implementation, which is normally a smell. It earns its place for
/// one reason: an `SCStream` cannot be built in a test process, and without this seam every test
/// of the folder lifecycle — draft created, metadata written, rename after the files close —
/// would need a screen recording permission and a live display. The rules those tests cover are
/// not about audio at all.
///
/// The two methods are not the whole surface: a capture also reports a stream that died while
/// the meeting was still running, through the handler it was built with. That channel is not a
/// requirement of this protocol because it is set at construction and never called on — but a
/// stand-in that cannot raise it leaves the path it feeds untested, which is the whole reason
/// the handler exists.
public protocol MeetingCapture: Sendable {
    func start() async throws
    func stop() async throws -> MeetingAudioRecorder.Outcome

    /// How long the microphone track has been delivering nothing but digital zeroes.
    ///
    /// Asked once a second while a meeting records. Zero means audio is arriving — including
    /// audio nobody would call loud, which is the point: a real microphone in an empty room is
    /// never exactly zero, and only a track bound to nothing ever is.
    func microphoneSilentSeconds() async -> TimeInterval

    /// Points the microphone output at a device by its CoreAudio UID, on the running stream.
    ///
    /// ScreenCaptureKit binds the microphone once, when the stream starts, and does not follow a
    /// device that appears later — measured, see the decision of 2026-09-08. Without this the
    /// warning on the panel would be sympathy rather than a repair.
    func rebindMicrophone(to deviceUID: String) async throws
}

extension MeetingAudioRecorder: MeetingCapture {}
