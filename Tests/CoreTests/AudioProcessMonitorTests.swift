import CoreAudio
import Testing
@testable import Core

// Detecting a meeting stands entirely on four CoreAudio selectors, and a wrong one compiles.
// From then on it fails the way CoreAudio always fails — silently, with a zero — so nothing
// looks broken until a meeting goes unrecorded. Nothing here is mocked: like
// `AudioInputDeviceTests`, these call the real system and check the shape of what comes back.
// What they cannot check is a device actually being held, which is the owner's live meeting.

@Test func theProcessListAnswersAndEveryEntryIsARealProcess() throws {
    // `nil` is a failed call. On the machine this application runs on there is no such thing as
    // "CoreAudio is not available", so shrugging at nil here would be a test that checks nothing.
    let states = try #require(AudioProcessMonitor.current())
    // An empty list is what a wrong PID selector produces and nothing else does: every pid comes
    // back as -1 and the whole list is filtered away. macOS keeps a process object for everything
    // that has touched audio since boot — a desktop with a browser open has dozens.
    #expect(!states.isEmpty)
    for state in states {
        #expect(state.pid > 0)
        // Both are absent for daemons with no `NSRunningApplication`, which is fine and expected.
        // Present and empty is not: that would be a name nobody can match a trigger against.
        #expect(state.bundleID?.isEmpty != true)
        #expect(state.name?.isEmpty != true)
    }
}

// The two flags are the whole reason this file exists rather than a list of running applications:
// muting inside a meeting releases the input and keeps the output, and a detector that could not
// tell those apart would read every mute as the end of the meeting. A wrong constant for either
// answers `false` forever, which reads as "nobody is holding anything".
@Test func everyPropertyTheDetectorReadsExistsOnARealProcessObject() throws {
    let objects = try #require(AudioProcessMonitor.processObjects())
    let object = try #require(objects.first)

    for selector in [
        kAudioProcessPropertyPID,
        kAudioProcessPropertyIsRunningInput,
        kAudioProcessPropertyIsRunningOutput,
    ] {
        #expect(has(selector, on: object))
    }
    // The control: without it the three checks above would pass just as happily against a
    // function that always said yes.
    #expect(!has(AudioObjectPropertySelector(1_234_567_890), on: object))
}

private func has(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectHasProperty(object, &address)
}
