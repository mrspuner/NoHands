import Foundation
import Testing
@testable import TodoistSync

private let moment = Date(timeIntervalSince1970: 1_791_400_000)  // 2026-10-07T19:06:40Z
private let utc = TimeZone(identifier: "UTC")!

private let snapshot = TaskSnapshot(id: "6hh", title: "Внести правки", description: "строка 1\nстрока 2", due: "2026-10-12",
                                    area: "Сколково", project: "Хибины", addedAt: "2026-10-07T14:00:00Z", updatedAt: "2026-10-07T15:00:00Z")

@Test func fileNamesFollowTheBigHeadConvention() {
    #expect(InboundRawFile.fileName(kind: "todoist", at: moment, timeZone: utc) == "2026-10-07-todoist-190640.md")
    #expect(InboundRawFile.fileName(kind: "todoist-project", at: moment, timeZone: utc) == "2026-10-07-todoist-project-190640.md")
}

@Test func tasksRenderWithFrontmatterAndOneBlockPerEvent() {
    let text = InboundRawFile.renderTasks([.closed(snapshot), .changed(snapshot)], polledAt: moment)
    #expect(text.hasPrefix("---\nkind: todoist\npolled_at: 2026-10-07T19:06:40Z\n---\n\n"))
    #expect(text.contains("- event: closed\n  id: 6hh\n  title: Внести правки\n"))
    #expect(text.contains("- event: changed\n"))
    #expect(text.contains("  area: Сколково\n  project: Хибины\n"))
    #expect(text.contains("  due: 2026-10-12\n"))
}

// A multi-line description stays inside its block.
@Test func continuationLinesAreIndented() {
    let text = InboundRawFile.renderTasks([.changed(snapshot)], polledAt: moment)
    #expect(text.contains("  description: строка 1\n    строка 2\n"))
}

@Test func absentFieldsAreNotWritten() {
    let bare = TaskSnapshot(id: "1", title: "T", description: nil, due: nil, area: "RooX", project: nil, addedAt: nil, updatedAt: nil)
    let text = InboundRawFile.renderTasks([.deleted(bare)], polledAt: moment)
    #expect(!text.contains("description:"))
    #expect(!text.contains("due:"))
    #expect(!text.contains("project:"))
}

@Test func projectsRender() {
    let text = InboundRawFile.renderProjects([ProjectAdded(id: "p", area: "RooX", name: "Новый")], polledAt: moment)
    #expect(text.hasPrefix("---\nkind: todoist-project\npolled_at: 2026-10-07T19:06:40Z\n---\n\n"))
    #expect(text.contains("- event: project_added\n  id: p\n  area: RooX\n  name: Новый\n"))
}

@Test func writingNeverOverwrites() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let first = try InboundRawFile.write("a", kind: "todoist", at: moment, rawDirectory: dir)
    let second = try InboundRawFile.write("b", kind: "todoist", at: moment, rawDirectory: dir)
    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-2.md"))
    #expect(try String(contentsOf: first, encoding: .utf8) == "a")
}
