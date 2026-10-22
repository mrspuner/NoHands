import Foundation
import Testing
@testable import Telegram

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func pendingSkipsDotFilesAndSortsByName() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["b.md", "a.md", ".c.md.tmp", ".d.md", "e.txt"] {
        try "text".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    #expect(Outbox.pending(in: dir).map(\.url.lastPathComponent) == ["a.md", "b.md"])
}

@Test func refIsReadFromFrontmatter() {
    let url = URL(fileURLWithPath: "/x/a.md")
    let m = Outbox.parse(url: url, contents: "---\nref: Вопрос про сроки\n---\nКогда сдаём?\n")
    #expect(m == OutboxMessage(url: url, ref: "Вопрос про сроки", body: "Когда сдаём?"))
}

@Test func fileWithoutFrontmatterHasNilRef() {
    let url = URL(fileURLWithPath: "/x/a.md")
    let m = Outbox.parse(url: url, contents: "Просто текст\nв две строки\n")
    #expect(m.ref == nil)
    #expect(m.body == "Просто текст\nв две строки")
}

@Test func writeProducesAParsableFile() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try Outbox.write(ref: "Сбой: x", body: "Тело", to: dir, now: Date(timeIntervalSince1970: 0))
    #expect(url.lastPathComponent.range(of: #"^\d{8}-\d{6}-[0-9a-f]{6}\.md$"#, options: .regularExpression) != nil)
    let found = Outbox.pending(in: dir)
    #expect(found.count == 1)
    #expect(found[0].ref == "Сбой: x")
    #expect(found[0].body == "Тело")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".") })
}
