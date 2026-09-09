import Testing
@testable import Core

private let airpods = AudioInputDevice(
    name: "AirPods", uid: "airpods", sampleRate: 24000, channelCount: 1, transport: .bluetooth
)
private let iphone = AudioInputDevice(
    name: "Микрофон iPhone", uid: "iphone", sampleRate: 48000, channelCount: 1,
    transport: .continuity
)

@MainActor
private final class Harness {
    var devices: [AudioInputDevice] = [airpods, iphone]
    var current: AudioInputDevice? = airpods
    var refuse = false
    private(set) var writes: [String] = []
    var guardian: InputDeviceGuard!

    init() {
        guardian = InputDeviceGuard(
            list: { [unowned self] in self.devices },
            current: { [unowned self] in self.current },
            setDefault: { [unowned self] uid in
                self.writes.append(uid)
                guard !self.refuse else { return false }
                self.current = self.devices.first { $0.uid == uid }
                return true
            }
        )
    }
}

@MainActor
@Test func aBluetoothDefaultIsSwitchedToTheBestInput() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    #expect(harness.writes == ["iphone"])
}

@MainActor
@Test func aFullBandDefaultIsLeftAlone() {
    let harness = Harness()
    harness.current = iphone
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}

// Nothing better to switch to: the recording goes ahead on the Bluetooth microphone, and the
// narrowband warning the panel already shows is the whole reporting this case gets.
@MainActor
@Test func withoutACandidateNothingIsWritten() {
    let harness = Harness()
    harness.devices = [airpods]
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}

@MainActor
@Test func aRefusedWriteIsReportedRatherThanRetried() {
    let harness = Harness()
    harness.refuse = true
    #expect(harness.guardian.prepare() == .failed)
    #expect(harness.writes == ["iphone"])
}

// The owner put the Bluetooth input back by hand — nothing else could have — so it is theirs
// from now on, and no later recording argues with it.
@MainActor
@Test func aManualReturnToBluetoothIsRespected() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    harness.current = airpods
    #expect(harness.guardian.prepare() == .yielded)
    #expect(harness.guardian.prepare() == .yielded)
    #expect(harness.writes == ["iphone"])
}

// Unplugged and plugged in again starts the argument over: the memory is about the device that
// is here, not about what happened yesterday.
@MainActor
@Test func aVanishedDeviceIsForgotten() {
    let harness = Harness()
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    harness.current = airpods
    #expect(harness.guardian.prepare() == .yielded)

    harness.devices = [iphone]
    harness.current = iphone
    #expect(harness.guardian.prepare() == .unchanged)

    harness.devices = [airpods, iphone]
    harness.current = airpods
    #expect(harness.guardian.prepare() == .switched(name: "Микрофон iPhone"))
    #expect(harness.writes == ["iphone", "iphone"])
}

// No input at all — a Mac mini with nothing plugged in. There is nothing to prefer over nothing.
@MainActor
@Test func noInputDeviceIsNotAnOccasionToWriteAnything() {
    let harness = Harness()
    harness.current = nil
    #expect(harness.guardian.prepare() == .unchanged)
    #expect(harness.writes.isEmpty)
}
