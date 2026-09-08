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
