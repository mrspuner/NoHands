import CoreGraphics
import Foundation
import Testing
@testable import Dictation

// flagsChanged carries no up or down: fn is down when the event that reports key code 63 also
// carries the function flag, and up when it does not.
@Test func fnPressIsRecognized() {
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn) == .fnDown)
}

@Test func fnReleaseIsRecognized() {
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 63, flags: []) == .fnUp)
}

// The whole reason this function exists. macOS sets the function flag for arrow keys, the F
// row, Home, End, Page Up and Page Down — matching on the flag alone would start a recording
// every time the owner pressed an arrow key.
@Test func anArrowKeyIsNotFn() {
    // Left arrow is key code 123 and arrives with the very same flag set.
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 123, flags: .maskSecondaryFn) == nil)
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 123, flags: .maskSecondaryFn) == nil)
}

@Test func spaceIsRecognizedOnlyOnKeyDown() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 49, flags: []) == .spaceDown)
    #expect(KeyEventReader.kind(type: .keyUp, keyCode: 49, flags: []) == nil)
}

@Test func escapeIsRecognizedOnlyOnKeyDown() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 53, flags: []) == .escapeDown)
    #expect(KeyEventReader.kind(type: .keyUp, keyCode: 53, flags: []) == nil)
}

@Test func everyOtherKeyIsIgnored() {
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 0, flags: []) == nil)
    #expect(KeyEventReader.kind(type: .keyDown, keyCode: 36, flags: []) == nil)
    #expect(KeyEventReader.kind(type: .flagsChanged, keyCode: 56, flags: .maskShift) == nil)
}

// Space swallows on the fn flag alone, with no separately tracked "fn is down" state: an
// fn-up the tap never saw must not leave every future space swallowed forever.
@Test func spaceSwallowsOnTheFnFlagEvenWhenTheMachinesFlagIsFalse() {
    #expect(KeyEventReader.shouldSwallow(.spaceDown, flags: .maskSecondaryFn, space: false, escape: false))
}

@Test func spaceIsNotSwallowedWhenNeitherTheFlagNorTheMachineWantsIt() {
    #expect(!KeyEventReader.shouldSwallow(.spaceDown, flags: [], space: false, escape: false))
}

// The machine's own intent still swallows space with the fn flag absent — latching keeps
// eating space after fn has physically been released.
@Test func spaceSwallowsOnTheMachinesFlagWithTheFnFlagAbsent() {
    #expect(KeyEventReader.shouldSwallow(.spaceDown, flags: [], space: true, escape: false))
}

@Test func escapeSwallowsOnlyOnTheMachinesFlag() {
    #expect(KeyEventReader.shouldSwallow(.escapeDown, flags: [], space: false, escape: true))
    #expect(!KeyEventReader.shouldSwallow(.escapeDown, flags: .maskSecondaryFn, space: false, escape: false))
}

@Test func fnEventsAreNeverSwallowed() {
    #expect(!KeyEventReader.shouldSwallow(.fnDown, flags: .maskSecondaryFn, space: true, escape: true))
    #expect(!KeyEventReader.shouldSwallow(.fnUp, flags: [], space: true, escape: true))
}
