import AppKit
import Dictation
import Meetings
import SwiftUI

/// What the panel is drawing right now.
@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState?
    /// The meeting side of the panel, kept apart from `state` rather than merged into it:
    /// dictation lasts seconds and a meeting lasts an hour, so one of them is always the one on
    /// top and the other has to survive underneath. Dictation is the one on top — it is the
    /// thing the owner is doing this second — and a meeting prompt covered by it comes back by
    /// itself when dictation collapses, which is why waiting is the whole handling it needs.
    @Published var meeting: MeetingPanelState?
    /// Answers the prompt currently on the panel. Set once the meeting coordinator exists,
    /// which is after the panel does.
    var onMeetingAnswer: ((MeetingCoordinator.Answer) -> Void)?
    /// A short history rather than one number: a single bar jumping around reads as noise,
    /// while a row of recent levels reads as a voice.
    @Published var levels: [Float] = Array(repeating: 0, count: 32)
    /// The application that will receive the text, tracked live rather than captured: the
    /// paste goes wherever focus is when it lands, so anything captured earlier would be a
    /// guess the panel presented as fact.
    @Published var frontmostName: String?
    @Published var frontmostIcon: NSImage?
    /// Sample rate of the input when it is narrowband, nil otherwise.
    @Published var narrowbandHz: Double?
    /// The same fact about the meeting being recorded, kept apart from the dictation one for the
    /// same reason `meeting` is kept apart from `state`: the two live on different clocks, and a
    /// dictation collapsing would otherwise wipe the warning off an hour-long recording.
    @Published var meetingNarrowbandHz: Double?
    /// The transcription notice, kept apart from `state` and `meeting` rather than merged into
    /// either. A finished transcript lands seconds after a meeting ends — exactly when dictation
    /// has just been unblocked and may well be in use — so it must not take the row a dictation
    /// is drawing on.
    @Published var notice: MeetingNotice?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 32)
    }
}
