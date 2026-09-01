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
