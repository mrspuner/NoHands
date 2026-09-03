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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 56),
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
        panel.contentView = NSHostingView(rootView: PanelView(model: model))

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
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
