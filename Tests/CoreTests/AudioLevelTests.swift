import Foundation
import Testing
@testable import Core

@Test func silenceIsZero() {
    #expect(AudioLevel.rms([0, 0, 0, 0]) == 0)
}

@Test func emptyBufferIsZero() {
    #expect(AudioLevel.rms([]) == 0)
}

@Test func constantAmplitudeIsThatAmplitude() {
    // Half of full scale, alternating sign: RMS equals the amplitude itself.
    let half = Int16(16384)
    #expect(abs(AudioLevel.rms([half, -half, half, -half]) - 0.5) < 0.001)
}

// The mapping is logarithmic on purpose: a linear RMS spends almost its whole range on the
// loudest sounds, so ordinary speech would show as a barely moving line.
@Test func fullScaleMapsToOne() {
    #expect(abs(AudioLevel.normalized(rms: 1.0) - 1.0) < 0.001)
}

@Test func silenceMapsToZero() {
    #expect(AudioLevel.normalized(rms: 0) == 0)
}

@Test func belowTheFloorMapsToZero() {
    // -60 dBFS is the floor; anything quieter is not drawn at all.
    #expect(AudioLevel.normalized(rms: 0.0005) == 0)
}

@Test func louderInputGivesLargerLevel() {
    #expect(AudioLevel.normalized(rms: 0.5) > AudioLevel.normalized(rms: 0.05))
}
