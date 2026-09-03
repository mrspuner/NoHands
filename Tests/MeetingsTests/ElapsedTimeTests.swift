import Foundation
import Testing
@testable import Meetings

@Test func aRecordingUnderAnHourReadsAsMinutesAndSeconds() {
    #expect(ElapsedTime.clock(0) == "0:00")
    #expect(ElapsedTime.clock(9) == "0:09")
    #expect(ElapsedTime.clock(74) == "1:14")
    #expect(ElapsedTime.clock(3599) == "59:59")
}

// A meeting that runs past an hour is the normal case, not the exception — 65 minutes would
// otherwise read as "65:00", which nobody parses at a glance.
@Test func anHourAddsAField() {
    #expect(ElapsedTime.clock(3600) == "1:00:00")
    #expect(ElapsedTime.clock(3723) == "1:02:03")
}

// The clock is a difference between two `Date`s, and a system clock that jumped backwards
// makes that difference negative. A recording showing "-0:03" would look broken; zero is what
// a recording that has not run yet actually lasted.
@Test func aClockThatJumpedBackwardsShowsZeroRatherThanAMinus() {
    #expect(ElapsedTime.clock(-5) == "0:00")
}

// The prompts ask what to do with a finished recording, where seconds are noise. Rounding
// rather than truncating: 89 seconds is nearer to a minute and a half than to one minute.
@Test func promptsCountWholeMinutes() {
    #expect(ElapsedTime.minutes(0) == 0)
    #expect(ElapsedTime.minutes(29) == 0)
    #expect(ElapsedTime.minutes(31) == 1)
    #expect(ElapsedTime.minutes(89) == 1)
    #expect(ElapsedTime.minutes(91) == 2)
    #expect(ElapsedTime.minutes(2820) == 47)
    #expect(ElapsedTime.minutes(-30) == 0)
}
