import Foundation
import Testing
@testable import CLI

@Test func processIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "process", "/tmp/2026-09-04-1053-telemost"])
    #expect(parsed.subcommand == .process)
    #expect(parsed.path.lastPathComponent == "2026-09-04-1053-telemost")
}

@Test func levelsIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "levels", "/tmp/x"])
    #expect(parsed.subcommand == .levels)
}

@Test func summarizeTakesAFileRatherThanAFolder() throws {
    let parsed = try MeetingArguments.parse(["meeting", "summarize", "/tmp/a.md"])
    #expect(parsed.subcommand == .summarize)
    #expect(parsed.path.lastPathComponent == "a.md")
}

@Test func anUnknownSubcommandIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "reprocess", "/tmp/x"])
    }
}

@Test func anUnknownSubcommandNamesTheOnesThatExist() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "resummarize", "/tmp/a.md"])
    }
}

@Test func aMissingFolderIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "process"])
    }
}

@Test func diarizeIsParsed() throws {
    let arguments = try MeetingArguments.parse(["meeting", "diarize", "/tmp/встреча"])
    #expect(arguments.subcommand == .diarize)
    #expect(arguments.threshold == nil)
    #expect(arguments.write == false)
}

@Test func theThresholdAndTheWriteFlagAreParsed() throws {
    let arguments = try MeetingArguments.parse(
        ["meeting", "diarize", "/tmp/встреча", "--threshold", "0.75", "--write"]
    )
    #expect(arguments.threshold == 0.75)
    #expect(arguments.write)
}

// A threshold that is not a number would otherwise silently become the default, and the whole
// point of the command is to see what a particular number does.
@Test func aBadThresholdIsRefused() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "diarize", "/tmp/встреча", "--threshold", "почти"])
    }
}
