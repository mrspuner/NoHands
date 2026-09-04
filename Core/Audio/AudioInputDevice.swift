import CoreAudio
import Foundation

/// The current default input device, as CoreAudio sees it.
///
/// Printed before every recording. A Mac mini has no built-in microphone, and if nothing is
/// plugged in the system may fall back to a leftover virtual device — recording into which
/// yields silence that looks like a recognition failure.
public struct AudioInputDevice: Sendable {
    public let name: String
    public let sampleRate: Double
    public let channelCount: UInt32

    /// Below this rate macOS has switched the input into its narrowband mode. A Bluetooth
    /// headset does that to the whole audio device the moment its microphone is used, and
    /// `DESIGN.md` names that the worst input this application can have: the top of the
    /// spectrum is gone, and the top is where similar consonants differ.
    public static let narrowbandThreshold: Double = 32000

    public var isNarrowband: Bool {
        sampleRate < Self.narrowbandThreshold
    }

    /// Public so a test outside this module can stand in a device of its own. Nothing in the
    /// application builds one: `current()` is the only honest source, and a device described by
    /// hand would be a description of a microphone nobody is recording through.
    public init(name: String, sampleRate: Double, channelCount: UInt32) {
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public static func current() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID(),
              let name = deviceName(deviceID),
              let format = streamFormat(deviceID)
        else {
            return nil
        }
        return AudioInputDevice(
            name: name,
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame
        )
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    private static func streamFormat(_ deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &format)
        guard status == noErr else { return nil }
        return format
    }
}
