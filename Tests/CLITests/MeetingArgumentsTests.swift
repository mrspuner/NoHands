import Foundation
import Testing
@testable import CLI

@Test func processIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "process", "/tmp/2026-09-04-1053-telemost"])
    #expect(parsed.subcommand == .process)
    #expect(parsed.folder.lastPathComponent == "2026-09-04-1053-telemost")
}

@Test func levelsIsParsed() throws {
    let parsed = try MeetingArguments.parse(["meeting", "levels", "/tmp/x"])
    #expect(parsed.subcommand == .levels)
}

@Test func anUnknownSubcommandIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "summarize", "/tmp/x"])
    }
}

@Test func aMissingFolderIsNamed() {
    #expect(throws: MeetingArguments.ParseError.self) {
        try MeetingArguments.parse(["meeting", "process"])
    }
}
