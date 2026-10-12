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
            // The bundle ID comes from the process object, read in the same pass as the pid and
            // the flags. LaunchServices is a second source with its own timing: it answered `nil`
            // for a running Telemost for a quarter of a second, the watcher lost the match, and the
            // coordinator read that as the application quitting — cutting a live meeting in two.
            // The name has no such source in CoreAudio and stays with LaunchServices; the watcher
            // already falls back to the trigger's slug when it is missing.
            let app = NSRunningApplication(processIdentifier: pid)
            return State(
                pid: pid,
                bundleID: bundleID(of: object) ?? app?.bundleIdentifier,
                name: app?.localizedName,
                isRunningInput: flag(object, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: flag(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    /// `nil` only for a failed system call. A `size` of zero is a legitimate answer — no process
    /// is touching audio right now — and is reported as an empty array, not as failure.
    ///
    /// Internal rather than private so the smoke test can ask a real process object whether it
    /// actually has the properties this file reads off it. Every one of them fails the way
    /// CoreAudio always fails — silently, with a zero — so a wrong constant is invisible from
    /// the outside, and the object is the only thing that can be asked.
    static func processObjects() -> [AudioObjectID]? {
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

    /// `nil` for a failed call or a process without a bundle — a bare daemon. An empty string is
    /// folded into `nil` too: a name nobody can match a trigger against is no name.
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?,
              !string.isEmpty
        else { return nil }
        return string
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
