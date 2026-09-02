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
