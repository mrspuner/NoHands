import ApplicationServices
import CoreGraphics
import Foundation
import os

public enum KeyMonitorError: Error, Equatable, LocalizedError {
    case accessibilityDenied
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is not granted; grant it in System Settings > " +
                "Privacy & Security > Accessibility"
        case .tapCreationFailed:
            return "Could not create the keyboard event tap"
        }
    }
}

/// Watches for fn, space and escape, and swallows the last two while dictation owns them.
///
/// An active tap on `keyDown` sees every keystroke on the machine. This one compares the key
/// code against three numbers and hands the event straight back: nothing is accumulated,
/// written or sent anywhere. That is the whole cost of latching on space and cancelling on
/// escape, and it is written down in the decisions log.
public final class FnKeyMonitor: @unchecked Sendable {
    private struct Swallow: Sendable {
        var space = false
        var escape = false
    }

    private let onEvent: @Sendable (KeyEventKind) -> Void
    private let swallow = OSAllocatedUnfairLock(initialState: Swallow())
    /// Touched only on the main run loop, which is where both `start`/`stop` and the callback
    /// run.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(onEvent: @escaping @Sendable (KeyEventKind) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    public func setSwallow(space: Bool, escape: Bool) {
        swallow.withLock {
            $0.space = space
            $0.escape = escape
        }
    }

    public func start() throws {
        guard AXIsProcessTrusted() else { throw KeyMonitorError.accessibilityDenied }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // An active tap, not a listener: a listener cannot swallow the space that latches
            // a recording, and that space would land in whatever the owner is typing into.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw KeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off — silently, and for good — when its callback takes too long,
        // or when the user does something the system treats as reason to. Turning it back on
        // here is the only thing standing between one slow moment and dictation never working
        // again for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let kind = KeyEventReader.kind(type: type, keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        // Read the decision before delivering the event, never after: delivering it changes the
        // state machine, and by the time it returns the flags describe the world the keystroke
        // has already created rather than the one it arrived in. Latching is exactly that case
        // — the space that latches a recording turns space-swallowing off.
        //
        // `flags` is read out here, ahead of the lock: `CGEvent` itself is not `Sendable`, and
        // `withLock`'s closure is, so only the `Sendable` flags bitmask may cross into it.
        let flags = event.flags
        let shouldSwallow = swallow.withLock { state in
            KeyEventReader.shouldSwallow(kind, flags: flags, space: state.space, escape: state.escape)
        }

        // FIFO by contract, unlike unstructured tasks: fn down must never be processed after
        // the fn up that follows it.
        let deliver = onEvent
        DispatchQueue.main.async { deliver(kind) }

        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }
}
