import AppKit
import Dictation
import Meetings
import SwiftUI

/// The floating strip above the Dock. Serves both features — dictation and meetings — which is
/// why it is not named after either.
///
/// `.nonactivatingPanel` and refusing key status are not decoration: a panel that can become
/// key steals the focus, and the dictated text lands in the panel instead of the field the
/// owner was aiming at.
@MainActor
final class PanelWindow {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A click into a window belonging to an application that is not frontmost is a "first
    /// mouse" click, and AppKit hands those to the view only if it asks for them. This window
    /// never becomes key by design, so every click on a prompt's buttons is one of those:
    /// without this, the first click would be spent on nothing and the owner would have to
    /// press twice.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let model = PanelModel()
    private let panel: Panel
    private var pendingHide: DispatchWorkItem?
    /// Separate from `pendingHide`: the two features collapse on their own schedules, and one
    /// timer would let a dictation ending cancel a meeting prompt's dwell, or the other way
    /// round.
    private var pendingMeetingHide: DispatchWorkItem?
    /// Its own dwell timer, a third one: a transcription notice lives by its own clock, and a
    /// shared timer would let the end of a dictation cut it off halfway.
    private var pendingNoticeHide: DispatchWorkItem?

    init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: Self.restingHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: with the lit border the panel draws its own edge, and AppKit's shadow
        // around a small capsule reads as a hard black outline rather than as depth.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstMouseHostingView(rootView: PanelView(model: model))

        // Shown from launch and never ordered out again: the collapsed strip above the Dock is
        // how the owner knows the application is running at all. Nothing there means nothing is
        // listening.
        position()
        panel.orderFrontRegardless()
    }

    func show(_ state: PanelState) {
        pendingHide?.cancel()
        pendingHide = nil
        if PanelTransition.transition(from: model.state, to: state) == .showResettingLevels {
            model.resetLevels()
        }
        model.state = state
        position()
        panel.orderFrontRegardless()
        updateAcceptsClicks()
        // AppKit caches a borderless transparent window's shadow from the backing store's alpha.
        // The content just changed shape (capsule to wide panel), so the cached shadow would keep
        // the old outline until something else forces a recompute.
    }

    /// Collapses the panel back to its resting strip. The window itself stays on screen — see
    /// `init`.
    func hide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.state = nil
            self?.model.narrowbandHz = nil
            self?.panel.invalidateShadow()
            self?.updateAcceptsClicks()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func show(meeting state: MeetingPanelState) {
        pendingMeetingHide?.cancel()
        pendingMeetingHide = nil
        model.meeting = state
        position()
        panel.orderFrontRegardless()
        updateAcceptsClicks()
    }

    func hideMeeting(after delay: TimeInterval) {
        pendingMeetingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.meeting = nil
            // Goes with the recording it described, exactly as the dictation warning goes with
            // its dictation: the next meeting reads the input device again and says its own.
            self?.model.meetingNarrowbandHz = nil
            self?.panel.invalidateShadow()
            self?.updateAcceptsClicks()
        }
        pendingMeetingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setMeetingAnswer(_ handler: @escaping (MeetingCoordinator.Answer) -> Void) {
        model.onMeetingAnswer = handler
    }

    func show(notice: MeetingNotice) {
        pendingNoticeHide?.cancel()
        pendingNoticeHide = nil
        model.notice = notice
        resize(forNotice: true)
        panel.orderFrontRegardless()
    }

    func hideNotice(after delay: TimeInterval) {
        pendingNoticeHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.notice = nil
            self?.resize(forNotice: false)
            self?.panel.invalidateShadow()
        }
        pendingNoticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The panel is deaf to the mouse by default, and that is not a detail: a click it accepts
    /// is a click the field the owner is dictating into does not get. A prompt is the one thing
    /// here that needs the mouse, and it gets it for exactly as long as it is up — the rule for
    /// which states those are lives in `MeetingPanelState.acceptsClicks`, where it is testable.
    ///
    /// Never while dictation is on top of it: the prompt is then not what is on screen, and a
    /// window swallowing clicks over something the owner cannot even see is the worst of both.
    private func updateAcceptsClicks() {
        let accepts = model.state == nil && (model.meeting?.acceptsClicks ?? false)
        panel.ignoresMouseEvents = !accepts
    }

    func setLevel(_ level: Float) {
        model.push(level: level)
    }

    func setFrontmost(name: String?, icon: NSImage?) {
        model.frontmostName = name
        model.frontmostIcon = icon
    }

    func setInputWarning(hz: Double?) {
        model.narrowbandHz = hz
    }

    func setMeetingInputWarning(hz: Double?) {
        model.meetingNarrowbandHz = hz
    }

    /// The window is only as tall as it needs to be, and that matters more than it looks.
    /// `updateAcceptsClicks` toggles `ignoresMouseEvents` for the whole window rectangle, not for
    /// the part SwiftUI draws into, so while a meeting prompt is up every click inside the frame
    /// goes to the panel. An unconditionally taller window would therefore swallow clicks in the
    /// empty space above the prompt — and this panel floats over full-screen call applications,
    /// whose mute and leave buttons sit exactly there. Growing only while the notice is actually
    /// on screen keeps that footprint what it was.
    private static let restingHeight: CGFloat = 56
    private static let noticeHeight: CGFloat = 96

    private func resize(forNotice showing: Bool) {
        let height = showing ? Self.noticeHeight : Self.restingHeight
        guard panel.frame.height != height else { return }
        panel.setContentSize(NSSize(width: panel.frame.width, height: height))
        position()
    }

    /// Distance from the top of the Dock to the bottom of the strip. The content is
    /// bottom-aligned inside the window, so this is the gap the owner actually sees.
    private static let gapAboveDock: CGFloat = 16

    private func position() {
        // `NSScreen.main` reflects the key window, which does not exist yet when this runs from
        // `init` — before `NSApp.run()`. Falling back to the first screen keeps the strip off the
        // bottom-left corner on a cold launch instead of waiting for the first dictation to move it.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.gapAboveDock
            )
        )
    }
}
