import Testing
@testable import CLI

// `record` used to print a generic "quality will be lower" line below 32 kHz and kept going —
// harmless for a wired mic that happens to negotiate a low rate, but silent about the far more
// common real cause: macOS drops to narrowband the moment a Bluetooth headset's mic is the
// active input (AirPods Pro included). DESIGN.md calls that the worst input the app can have and
// says diarization on it degrades, so the warning now names the frequency, says the recording
// can't be used to judge recognition quality, and names Bluetooth as the likely cause. Recording
// itself still isn't blocked.

@Test func warningIsAbsentAtThreshold() {
    #expect(narrowbandWarning(sampleRate: 32000) == nil)
}

@Test func warningIsAbsentAboveThreshold() {
    #expect(narrowbandWarning(sampleRate: 48000) == nil)
}

@Test func warningNamesTheActualFrequency() throws {
    let warning = try #require(narrowbandWarning(sampleRate: 16000))
    #expect(warning.contains("16000"))
}

@Test func warningSaysTheRecordingCannotJudgeQuality() throws {
    let warning = try #require(narrowbandWarning(sampleRate: 16000))
    #expect(warning.contains("не годится"))
}

@Test func warningNamesBluetoothAsTheLikelyCause() throws {
    let warning = try #require(narrowbandWarning(sampleRate: 16000))
    #expect(warning.contains("Bluetooth"))
}
