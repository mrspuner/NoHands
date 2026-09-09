import Foundation

/// Keeps a Bluetooth microphone from holding the system input when a recording is about to start.
///
/// Measured on this machine 2026-09-09: choosing the AirPods input drops the AirPods *output*
/// from 48000 Hz stereo to 24000 Hz mono in the same instant, before anything opens a stream, and
/// choosing another input puts it back. That is why this writes the system default rather than
/// picking a device for itself — the narrow band is caused by the default, and the track that
/// suffers from it is the one ScreenCaptureKit records out of the system mix.
///
/// Called before a recording starts, not continuously. The cost of that is named in the decisions
/// journal: a meeting whose application grabbed the Bluetooth microphone before the detector saw
/// it may keep it for the rest of the call.
@MainActor
public final class InputDeviceGuard {
    public enum Outcome: Equatable, Sendable {
        /// The default was fine, or there was nothing better to move to.
        case unchanged
        /// The default was moved to this device.
        case switched(name: String)
        /// The Bluetooth input is the owner's own choice and is left alone.
        case yielded
        /// A switch was attempted and CoreAudio refused it.
        case failed
    }

    private let list: () -> [AudioInputDevice]
    private let current: () -> AudioInputDevice?
    private let setDefault: (String) -> Bool

    /// The Bluetooth input this guard moved away from, for as long as that device is still
    /// around. Seeing it as the default again means the owner put it back by hand.
    private var switchedAwayFrom: String?
    /// The device the owner insisted on. Cleared when it disappears, so plugging the headphones
    /// in tomorrow starts the argument over rather than remembering yesterday's.
    private var yieldedTo: String?

    public init(
        list: @escaping () -> [AudioInputDevice] = AudioInputDevice.inputDevices,
        current: @escaping () -> AudioInputDevice? = AudioInputDevice.current,
        setDefault: @escaping (String) -> Bool = { AudioInputDevice.setDefaultInput(uid: $0) }
    ) {
        self.list = list
        self.current = current
        self.setDefault = setDefault
    }

    @discardableResult
    public func prepare() -> Outcome {
        let devices = list()
        forget(missingFrom: devices)
        guard let current = current(), current.transport == .bluetooth else { return .unchanged }
        if yieldedTo == current.uid { return .yielded }
        // Back on Bluetooth after this guard moved it off: only the owner could have done that,
        // since nothing here writes the default twice for the same device. Their choice stands
        // until the device goes away.
        if switchedAwayFrom == current.uid {
            yieldedTo = current.uid
            switchedAwayFrom = nil
            return .yielded
        }
        guard let replacement = InputPreference.replacement(among: devices) else {
            return .unchanged
        }
        guard setDefault(replacement.uid) else { return .failed }
        switchedAwayFrom = current.uid
        return .switched(name: replacement.name)
    }

    private func forget(missingFrom devices: [AudioInputDevice]) {
        let present = Set(devices.map(\.uid))
        if let uid = switchedAwayFrom, !present.contains(uid) { switchedAwayFrom = nil }
        if let uid = yieldedTo, !present.contains(uid) { yieldedTo = nil }
    }
}
