import AppKit
import CoreAudio
import Foundation

/// Which processes are holding the audio devices right now.
///
/// macOS 14.4 gave CoreAudio process objects: one object per process that touches audio, with
/// separate flags for input and output. The separation is the whole point here — muting inside
/// a meeting releases the input and keeps the output, so a rule built on the input alone would
/// read every mute as the end of the meeting.
public enum AudioProcessMonitor {
    public struct State: Equatable, Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let name: String?
        public let isRunningInput: Bool
        public let isRunningOutput: Bool

        public init(pid: Int32, bundleID: String?, name: String?, isRunningInput: Bool, isRunningOutput: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isRunningInput = isRunningInput
            self.isRunningOutput = isRunningOutput
        }
    }

    /// `nil` means the CoreAudio call itself failed — a revoked permission, a system glitch —
    /// and must not be read as "nobody is holding a device". Collapsing those two into one empty
    /// array would make a permanent failure look identical to ordinary silence, and the meeting
    /// detector would stop working forever without ever saying so.
    public static func current() -> [State]? {
        guard let objects = processObjects() else { return nil }
        return objects.compactMap { object in
            let pid = pid(of: object)
            guard pid > 0 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return State(
                pid: pid,
                bundleID: app?.bundleIdentifier,
                name: app?.localizedName,
                isRunningInput: flag(object, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: flag(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    /// `nil` only for a failed system call. A `size` of zero is a legitimate answer — no process
    /// is touching audio right now — and is reported as an empty array, not as failure.
    private static func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }
        return ids
    }

    private static func pid(of object: AudioObjectID) -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return -1
        }
        return value
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
