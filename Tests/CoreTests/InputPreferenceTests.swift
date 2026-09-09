import Testing
@testable import Core

private func device(
    _ name: String,
    _ transport: InputTransport,
    rate: Double = 48000,
    uid: String? = nil
) -> AudioInputDevice {
    AudioInputDevice(
        name: name,
        uid: uid ?? "uid-\(name)",
        sampleRate: rate,
        channelCount: 1,
        transport: transport
    )
}

// A USB microphone was plugged in on purpose; an iPhone is merely on the desk. When both are
// there, the deliberate one wins.
@Test func usbIsPreferredToContinuity() {
    let picked = InputPreference.replacement(among: [
        device("iPhone", .continuity),
        device("Yeti", .usb),
    ])
    #expect(picked?.name == "Yeti")
}

@Test func continuityIsTakenWhenThereIsNoUSB() {
    let picked = InputPreference.replacement(among: [
        device("AirPods", .bluetooth, rate: 24000),
        device("iPhone", .continuity),
    ])
    #expect(picked?.name == "iPhone")
}

// `ZoomAudioDevice` accepts a recording and hands back silence, which reads downstream as a
// failed transcription rather than as a wrong device. Never chosen, whatever else is missing.
@Test func aVirtualDeviceIsNeverChosen() {
    #expect(InputPreference.replacement(among: [device("ZoomAudioDevice", .virtual)]) == nil)
}

// Switching one narrowband input for another buys nothing.
@Test func aNarrowbandCandidateIsNotWorthSwitchingTo() {
    #expect(InputPreference.replacement(among: [device("cheap", .usb, rate: 16000)]) == nil)
}

// The uid is what the switch is written with; a device CoreAudio would not name cannot be set.
@Test func aDeviceWithoutAUidIsSkipped() {
    let picked = InputPreference.replacement(among: [
        device("безымянный", .usb, uid: ""),
        device("iPhone", .continuity),
    ])
    #expect(picked?.name == "iPhone")
}

@Test func bluetoothIsNeverAReplacement() {
    #expect(InputPreference.replacement(among: [device("AirPods", .bluetooth, rate: 24000)]) == nil)
}

@Test func anEmptyListHasNoReplacement() {
    #expect(InputPreference.replacement(among: []) == nil)
}
