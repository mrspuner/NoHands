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
        // Either can be absent — a bare daemon has no bundle, and the name comes from
        // `NSRunningApplication`, which daemons and helpers do not have. That is expected.
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
        kAudioProcessPropertyBundleID,
    ] {
        #expect(has(selector, on: object))
    }
    // The control: without it the three checks above would pass just as happily against a
    // function that always said yes.
    #expect(!has(AudioObjectPropertySelector(1_234_567_890), on: object))
}

// The bundle ID is what a trigger is matched against, and it used to come from LaunchServices
// through `NSRunningApplication`. That lookup is a second source with its own timing: on the
// owner's machine it answered `nil` for a running Telemost for a quarter of a second, the
// watcher dropped the process from its matches, and the coordinator read the gap as the
// application quitting — a live meeting was cut in two. The process object CoreAudio hands
// back carries its own bundle ID, read in the same pass as the pid and the flags, so the
// answer is taken from there. Helper processes are the visible proof: they have a process
// object with a bundle ID and no `NSRunningApplication` at all.
@Test func theBundleIDComesFromTheProcessObjectItself() throws {
    let objects = try #require(AudioProcessMonitor.processObjects())
    let states = try #require(AudioProcessMonitor.current())
    var compared = 0
    for object in objects {
        guard let expected = coreAudioBundleID(of: object), !expected.isEmpty,
              let pid = coreAudioPID(of: object), pid > 0,
              let state = states.first(where: { $0.pid == pid })
        else { continue }
        #expect(state.bundleID == expected, "pid \(pid)")
        compared += 1
    }
    // A machine with a desktop session always has processes that touched audio; zero compared
    // would be a test that checked nothing.
    #expect(compared > 0)
}

private func coreAudioPID(of object: AudioObjectID) -> Int32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Int32 = -1
    var size = UInt32(MemoryLayout<Int32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

private func coreAudioBundleID(of object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

private func has(_ selector: AudioObjectPropertySelector, on object: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectHasProperty(object, &address)
}
