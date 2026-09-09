import CoreAudio
import Foundation

/// How CoreAudio says a device is attached.
///
/// Only the values this application acts on are named. Everything else is `.other`, which is
/// never chosen as a replacement: an unknown transport is not a reason to move the owner's
/// microphone.
public enum InputTransport: Equatable, Sendable {
    case builtIn
    case usb
    /// A Continuity microphone — an iPhone on the desk, wired or not.
    case continuity
    /// Bluetooth in both its flavours. The input side of a Bluetooth headset runs at 24 kHz and
    /// nothing else, and choosing it drops the whole device — the output included — into that
    /// band. Measured on this machine 2026-09-09.
    case bluetooth
    /// Virtual and aggregate devices. `ZoomAudioDevice` is the one that matters here: it accepts
    /// a recording and hands back silence.
    case virtual
    case other

    static func from(_ raw: UInt32) -> InputTransport {
        switch raw {
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
        default: .other
        }
    }
}

/// The current default input device, as CoreAudio sees it.
///
/// Printed before every recording. A Mac mini has no built-in microphone, and if nothing is
/// plugged in the system may fall back to a leftover virtual device — recording into which
/// yields silence that looks like a recognition failure.
public struct AudioInputDevice: Sendable {
    public let name: String
    public let uid: String
    public let sampleRate: Double
    public let channelCount: UInt32
    public let transport: InputTransport

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
    public init(
        name: String,
        uid: String,
        sampleRate: Double,
        channelCount: UInt32,
        transport: InputTransport = .other
    ) {
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.transport = transport
    }

    public static func current() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID(),
              let name = deviceName(deviceID),
              let format = streamFormat(deviceID)
        else {
            return nil
        }
        // Empty rather than fatal, unlike the three above. The uid is wanted by one caller — the
        // meeting rebind — and `MicrophoneRecorder` turns a `nil` from here into
        // `RecordingError.noInputDevice` and refuses to record. A device CoreAudio declines to
        // name is still a microphone, and dictation must not stop because of a property it never
        // asked for. `MeetingCoordinator.checkMicrophone` skips the rebind on an empty one.
        return AudioInputDevice(
            name: name,
            uid: deviceUID(deviceID) ?? "",
            sampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame,
            transport: transportType(deviceID)
        )
    }

    /// Every device with at least one input channel, as CoreAudio lists them.
    ///
    /// Filtered by input channels rather than by name: an AirPods pair is two separate devices
    /// on macOS 15 — `…:input` and `…:output` — and only the first of them can be a default
    /// input at all.
    public static func inputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
                  let name = deviceName(id),
                  let format = streamFormat(id)
            else { return nil }
            return AudioInputDevice(
                name: name,
                uid: deviceUID(id) ?? "",
                sampleRate: format.mSampleRate,
                channelCount: format.mChannelsPerFrame,
                transport: transportType(id)
            )
        }
    }

    /// Writes the system-wide default input. Reports the refusal rather than throwing: the one
    /// caller treats a refusal as "record on whatever is there", which is the honest outcome —
    /// the recording still happens, in the band the system chose.
    @discardableResult
    public static func setDefaultInput(uid: String) -> Bool {
        guard !uid.isEmpty, let match = deviceIDs().first(where: { deviceUID($0) == uid }) else {
            return false
        }
        var value = match
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        return status == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> InputTransport {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // A failed read gets `.other` too, same as a transport this application does not name.
        // For `InputDeviceGuard` that means the device is simply never treated as Bluetooth: no
        // switch is attempted, no notice is shown, and if it really was a Bluetooth microphone
        // the owner sees the degradation only as the narrowband warning dictation and meetings
        // already print, not as a named cause.
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return .other
        }
        return InputTransport.from(value)
    }

    private static func channelCount(
        _ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
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

    private static func readCFStringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value as String
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        readCFStringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    /// What ScreenCaptureKit binds a microphone to — `kAudioDevicePropertyDeviceUID`, the same
    /// string `SCStreamConfiguration.microphoneCaptureDeviceID` takes.
    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        readCFStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
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
