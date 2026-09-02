import Foundation
import Testing
@testable import Core

@Test func firstWriteErrorIsKept() {
    let session = RecordingCounters()
    session.recordWriteFailure(NSError(domain: "first", code: 1))
    session.recordWriteFailure(NSError(domain: "second", code: 2))
    // Later writes fail the same way and would only bury the more informative first one.
    #expect((session.outcome().writeError as NSError?)?.domain == "first")
}

@Test func framesAccumulate() {
    let session = RecordingCounters()
    session.addFrames(100)
    session.addFrames(60)
    #expect(session.outcome().frames == 160)
}

@Test func noWritesMeansZeroFrames() {
    #expect(RecordingCounters().outcome().frames == 0)
}

// The panel redraws 20 times a second. The audio tap fires far more often than that, and
// every emitted level hops threads, so the tap thins them out itself.
@Test func firstLevelIsAlwaysEmitted() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 0, interval: 0.05))
}

@Test func levelsCloserThanTheIntervalAreDropped() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 10.0, interval: 0.05))
    #expect(!counters.shouldEmitLevel(at: 10.02, interval: 0.05))
}

@Test func levelIsEmittedAgainAfterTheInterval() {
    let counters = RecordingCounters()
    #expect(counters.shouldEmitLevel(at: 10.0, interval: 0.05))
    #expect(counters.shouldEmitLevel(at: 10.06, interval: 0.05))
}
