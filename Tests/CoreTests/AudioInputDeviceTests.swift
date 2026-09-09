import CoreAudio
import Testing
@testable import Core

@Test func currentDeviceIsEitherAbsentOrFullyDescribed() {
    // On this machine there may be no input device at all — a Mac mini has no built-in
    // microphone. Both outcomes are valid; what must never happen is a half-filled answer.
    guard let device = AudioInputDevice.current() else {
        return
    }
    #expect(!device.name.isEmpty)
    #expect(device.sampleRate > 0)
    #expect(device.channelCount > 0)
}

// The threshold is the one the CLI has used since phase 0. Below it macOS has put the input
// into its narrowband mode — which is what a Bluetooth headset's microphone does to the whole
// device — and DESIGN.md calls that the worst input this application can have.
@Test func theNarrowbandThresholdIsThirtyTwoKilohertz() {
    #expect(AudioInputDevice.narrowbandThreshold == 32000)
}

@Test func aBluetoothRateIsNarrowband() {
    let device = AudioInputDevice(name: "AirPods", uid: "test-airpods", sampleRate: 24000, channelCount: 1)
    #expect(device.isNarrowband)
}

@Test func aFullRateDeviceIsNot() {
    let device = AudioInputDevice(name: "USB", uid: "test-usb", sampleRate: 48000, channelCount: 1)
    #expect(!device.isNarrowband)
}

// Exactly at the threshold counts as fine: the boundary belongs to the good side, the same way
// the CLI has always treated it.
@Test func exactlyAtTheThresholdIsNotNarrowband() {
    let device = AudioInputDevice(name: "порог", uid: "test-threshold", sampleRate: 32000, channelCount: 1)
    #expect(!device.isNarrowband)
}

// The uid, not the name, is what ScreenCaptureKit binds the microphone to — and two AirPods of
// the same model carry the same name.
@Test func aDeviceCarriesItsCoreAudioUID() {
    let device = AudioInputDevice(
        name: "AirPods", uid: "F0-D3-1F-6F-CA-96:input", sampleRate: 24000, channelCount: 1
    )
    #expect(device.uid == "F0-D3-1F-6F-CA-96:input")
}

// The four-character codes are CoreAudio's own; they are matched against the SDK constants
// rather than against literals, so a renamed constant fails to compile instead of silently
// falling through to `.other`.
@Test func transportsAreMappedFromCoreAudioCodes() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeUSB) == .usb)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
    #expect(InputTransport.from(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    #expect(InputTransport.from(kAudioDeviceTransportTypeVirtual) == .virtual)
    #expect(InputTransport.from(kAudioDeviceTransportTypeAggregate) == .virtual)
}

// Both flavours of a Continuity microphone are one thing to this application: an iPhone on the
// desk. Measured on this machine — the iPhone microphone reports `ccwd`.
@Test func bothContinuityFlavoursAreOneTransport() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeContinuityCaptureWired) == .continuity)
    #expect(InputTransport.from(kAudioDeviceTransportTypeContinuityCaptureWireless) == .continuity)
}

// Anything this application has no rule for stays `.other`, and `.other` is never chosen as a
// replacement — an unknown transport is not an argument for switching the owner's microphone.
@Test func anUnknownTransportIsOther() {
    #expect(InputTransport.from(kAudioDeviceTransportTypeHDMI) == .other)
    #expect(InputTransport.from(kAudioDeviceTransportTypeAirPlay) == .other)
}

// The same shape the single-device test has, for the same reason: this machine may have no input
// at all, and a half-filled entry is the only outcome that is always wrong.
@Test func everyListedInputIsFullyDescribed() {
    for device in AudioInputDevice.inputDevices() {
        #expect(!device.name.isEmpty)
        #expect(device.sampleRate > 0)
        #expect(device.channelCount > 0)
    }
}

// A uid nothing answers to must not be written anywhere: the call reports the miss instead of
// picking some other device, and the system default is left exactly as it was.
@Test func settingAnUnknownDeviceAsDefaultIsRefused() {
    let before = AudioInputDevice.current()?.uid
    #expect(AudioInputDevice.setDefaultInput(uid: "no-such-device") == false)
    #expect(AudioInputDevice.current()?.uid == before)
}
