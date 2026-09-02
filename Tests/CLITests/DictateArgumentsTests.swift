import Foundation
import Testing
@testable import CLI

@Test func dictateDefaultsToCleaningTheText() throws {
    #expect(try DictateArguments.parse(["dictate"]).raw == false)
}

@Test func rawFlagSkipsCleanup() throws {
    #expect(try DictateArguments.parse(["dictate", "--raw"]).raw == true)
}

@Test func unknownArgumentIsRejected() {
    #expect(throws: DictateArguments.ParseError.message("Неизвестный аргумент: --fast")) {
        try DictateArguments.parse(["dictate", "--fast"])
    }
}
