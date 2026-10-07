import Foundation
import Testing
@testable import TodoistSync

private func store() -> SyncStateStore {
    SyncStateStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("state-\(UUID().uuidString)/todoist-sync-state.json"))
}

@Test func aMissingStateIsEmpty() async throws {
    #expect(try await store().load() == .empty)
}

@Test func savedSyncIsReadBack() async throws {
    let s = store()
    try await s.saveSync(token: "t1", projects: ["a": ProjectInfo(name: "Сколково", parentID: nil)])
    let state = try await s.load()
    #expect(state.syncToken == "t1")
    #expect(state.projects["a"]?.name == "Сколково")
}

@Test func ignoringIsRememberedOnce() async throws {
    let s = store()
    try await s.ignore(projectID: "p1")
    try await s.ignore(projectID: "p1")
    #expect(try await s.load().ignored == ["p1"])
}

// The poll saves after the owner may have declined a project mid-poll; the save must not
// drop that decision.
@Test func savingSyncKeepsIgnoredProjects() async throws {
    let s = store()
    try await s.ignore(projectID: "p1")
    try await s.saveSync(token: "t2", projects: [:])
    let state = try await s.load()
    #expect(state.ignored == ["p1"])
    #expect(state.syncToken == "t2")
}

@Test func theDefaultLocationIsInApplicationSupport() {
    #expect(SyncStateStore.defaultURL.path.hasSuffix("Library/Application Support/NoHands/todoist-sync-state.json"))
}
