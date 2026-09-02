import AppKit
import Dictation
import SwiftUI

/// The floating strip above the Dock.
///
/// `.nonactivatingPanel` and refusing key status are not decoration: a panel that can become
/// key steals the focus, and the dictated text lands in the panel instead of the field the
/// owner was aiming at.
@MainActor
final class DictationPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let model = PanelModel()
    private let panel: Panel
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PanelView(model: model))
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
    }

    func hide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.model.state = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setLevel(_ level: Float) {
        model.push(level: level)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 24
            )
        )
    }
}
