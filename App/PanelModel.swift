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

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 32)
    }
}
