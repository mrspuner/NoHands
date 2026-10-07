import Foundation
import Testing
@testable import TodoistSync

private let map: [String: ProjectInfo] = [
    "a": ProjectInfo(name: "Сколково", parentID: nil),
    "k": ProjectInfo(name: "Хибины", parentID: "a"),
    "deep": ProjectInfo(name: "Глубже", parentID: "k"),
    "home": ProjectInfo(name: "Дом", parentID: nil),
]

private func item(_ id: String, project: String = "k", checked: Bool = false, deleted: Bool = false,
                  updated: String? = "2026-10-07T15:00:00.123456Z", completed: String? = nil) -> SyncItem {
    SyncItem(id: id, content: "T \(id)", description: "D", dueDate: "2026-10-12", projectID: project,
             checked: checked, isDeleted: deleted, addedAt: "2026-10-07T14:00:00.000001Z", updatedAt: updated,
             completedAt: completed)
}

private func build(_ items: [SyncItem] = [], projects: [SyncProject] = [], ignored: Set<String> = [],
                   workItems: Set<String> = [], journal: [ActionJournal.Entry] = []) -> InboundBatch {
    InboundEvents.build(
        response: SyncResponse(syncToken: "t", fullSync: false, items: items, projects: projects),
        previous: map, areas: ["Сколково"], ignored: ignored, workItems: workItems, journal: journal
    )
}

@Test func flagsBecomeEvents() {
    let batch = build([item("1"), item("2", checked: true), item("3", deleted: true)])
    #expect(batch.tasks.count == 3)
    guard case .changed(let changed) = batch.tasks[0] else { Issue.record("not changed"); return }
    #expect(changed == TaskSnapshot(id: "1", title: "T 1", description: "D", due: "2026-10-12",
                                    area: "Сколково", project: "Хибины",
                                    addedAt: "2026-10-07T14:00:00.000001Z", updatedAt: "2026-10-07T15:00:00.123456Z"))
    if case .closed = batch.tasks[1] {} else { Issue.record("not closed") }
    if case .deleted = batch.tasks[2] {} else { Issue.record("not deleted") }
}

// Deleted wins over checked: a deleted task is gone, not done.
@Test func deletedWinsOverChecked() {
    if case .deleted = build([item("1", checked: true, deleted: true)]).tasks[0] {} else { Issue.record("not deleted") }
}

@Test func aTaskInTheAreaItselfHasNoProject() {
    guard case .changed(let s) = build([item("1", project: "a")]).tasks[0] else { Issue.record(); return }
    #expect(s.project == nil)
    #expect(s.area == "Сколково")
}

@Test func aTaskDeeperDownKeepsItsOwnProject() {
    guard case .changed(let s) = build([item("1", project: "deep")]).tasks[0] else { Issue.record(); return }
    #expect(s.project == "Глубже")
}

@Test func personalTasksNeverAppear() {
    #expect(build([item("1", project: "home"), item("2", project: "unknown")]).tasks.isEmpty)
}

@Test func anIgnoredProjectAndItsSubprojectsAreSilent() {
    #expect(build([item("1", project: "k"), item("2", project: "deep")], ignored: ["k"]).tasks.isEmpty)
}

@Test func areaNamesMatchIgnoringCaseAndSpaces() {
    let batch = InboundEvents.build(
        response: SyncResponse(syncToken: "t", fullSync: false, items: [item("1")], projects: []),
        previous: map, areas: [" сколково "], ignored: [], journal: []
    )
    #expect(batch.tasks.count == 1)
}

// Our own close comes back from the poll: the journal entry is written after Todoist's
// updated_at, so it is at or after it.
@Test func ownChangesAreFilteredByTheJournal() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:01Z", action: "task.closed", todoistID: "1", name: nil)]
    #expect(build([item("1", checked: true)], journal: journal).tasks.isEmpty)
}

@Test func theOwnersLaterChangeIsNotFiltered() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T14:58:00Z", action: "task.updated", todoistID: "1", name: nil)]
    #expect(build([item("1")], journal: journal).tasks.count == 1)
}

@Test func theEchoWindowIsFiveSeconds() {
    let inside = [ActionJournal.Entry(time: "2026-10-07T14:59:56Z", action: "task.updated", todoistID: "1", name: nil)]
    let outside = [ActionJournal.Entry(time: "2026-10-07T14:59:54Z", action: "task.updated", todoistID: "1", name: nil)]
    #expect(build([item("1")], journal: inside).tasks.isEmpty)
    #expect(build([item("1")], journal: outside).tasks.count == 1)
}

@Test func anEntryForAnotherTaskDoesNotFilter() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:01Z", action: "task.closed", todoistID: "2", name: nil)]
    #expect(build([item("1", checked: true)], journal: journal).tasks.count == 1)
}

@Test func aNewProjectUnderAnAreaIsAnnounced() {
    let batch = build(projects: [SyncProject(id: "n", name: "Новый", parentID: "a", isArchived: false, isDeleted: false)])
    #expect(batch.projects == [ProjectAdded(id: "n", area: "Сколково", name: "Новый")])
    #expect(batch.projectMap["n"] == ProjectInfo(name: "Новый", parentID: "a"))
}

@Test func projectsWeCreatedOrThatAreNotUnderAnAreaAreNotAnnounced() {
    let ours = [ActionJournal.Entry(time: "2026-10-07T10:00:00Z", action: "project.created", todoistID: "n", name: "Новый")]
    #expect(build(projects: [SyncProject(id: "n", name: "Новый", parentID: "a", isArchived: false, isDeleted: false)], journal: ours).projects.isEmpty)
    #expect(build(projects: [SyncProject(id: "h", name: "Ремонт", parentID: "home", isArchived: false, isDeleted: false)]).projects.isEmpty)
    #expect(build(projects: [SyncProject(id: "k", name: "Хибины", parentID: "a", isArchived: false, isDeleted: false)]).projects.isEmpty)
    #expect(build(projects: [SyncProject(id: "x", name: "Архив", parentID: "a", isArchived: true, isDeleted: false)]).projects.isEmpty)
}

@Test func aDeletedProjectLeavesTheMap() {
    let batch = build(projects: [SyncProject(id: "k", name: "Хибины", parentID: "a", isArchived: false, isDeleted: true)])
    #expect(batch.projectMap["k"] == nil)
}

// A task in a project created in the same sync is placed by the merged map.
@Test func aTaskInAProjectFromTheSameSyncIsPlaced() {
    let batch = build([item("1", project: "n")],
                      projects: [SyncProject(id: "n", name: "Новый", parentID: "a", isArchived: false, isDeleted: false)])
    guard case .changed(let s) = batch.tasks[0] else { Issue.record(); return }
    #expect(s.project == "Новый")
}

// A project deleted in the same sync still places its deleted tasks.
@Test func aTaskDeletedWithItsProjectStillGivesADeleteEvent() {
    let batch = build([item("1", project: "k", deleted: true)],
                      projects: [SyncProject(id: "k", name: "Хибины", parentID: "a", isArchived: false, isDeleted: true)])
    #expect(batch.tasks.count == 1)
    guard case .deleted(let s) = batch.tasks[0] else { Issue.record("not deleted"); return }
    #expect(s.project == "Хибины")
    #expect(batch.projectMap["k"] == nil)
}

@Test func theEchoWindowBoundaryIsInclusive() {
    let edge = [ActionJournal.Entry(time: "2026-10-07T14:59:55Z", action: "task.updated", todoistID: "1", name: nil)]
    #expect(build([item("1")], journal: edge).tasks.isEmpty)
}

// The owner closed the task later than its last update: our earlier create is not the cause.
@Test func completionTimeCountsForTheEchoFilter() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:02Z", action: "task.created", todoistID: "1", name: nil)]
    let closedLater = item("1", checked: true, updated: "2026-10-07T15:00:00.000000Z", completed: "2026-10-07T15:10:00.000000Z")
    #expect(build([closedLater], journal: journal).tasks.count == 1)
    let closedByUs = item("1", checked: true, updated: "2026-10-07T15:00:00.000000Z", completed: "2026-10-07T15:00:01.000000Z")
    #expect(build([closedByUs], journal: journal).tasks.isEmpty)
}

@Test func anItemWithNoTimesIsNeverAnEcho() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:02Z", action: "task.created", todoistID: "1", name: nil)]
    #expect(build([item("1", updated: nil, completed: nil)], journal: journal).tasks.count == 1)
}

// Live Todoist: a deleted task comes back as a tombstone with an empty content, no times and
// a project that no longer places it.
private func tombstone(_ id: String) -> SyncItem {
    SyncItem(id: id, content: "", description: nil, dueDate: nil, projectID: "gone", checked: false,
             isDeleted: true, addedAt: "1970-01-01T00:00:00.000000Z", updatedAt: nil)
}
private func bareDeleted(_ id: String) -> InboundEvent {
    .deleted(TaskSnapshot(id: id, title: "", description: nil, due: nil, area: "", project: nil, addedAt: nil, updatedAt: nil))
}

@Test func aTombstoneOfAKnownWorkItemIsDeleted() {
    let batch = build([tombstone("9")], workItems: ["9", "other"])
    #expect(batch.tasks == [bareDeleted("9")])
    #expect(batch.workItems == ["other"])
}

@Test func aTombstoneOfAnUnknownIdIsPersonalAndSilent() {
    #expect(build([tombstone("9")], workItems: ["other"]).tasks.isEmpty)
}

@Test func aTombstoneKnownOnlyFromTheJournalIsDeleted() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:01Z", action: "task.created", todoistID: "9", name: nil)]
    #expect(build([tombstone("9")], journal: journal).tasks == [bareDeleted("9")])
}

@Test func aTombstoneOfOurOwnDeleteIsAnEcho() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:01Z", action: "task.deleted", todoistID: "9", name: nil)]
    let batch = build([tombstone("9")], workItems: ["9"], journal: journal)
    #expect(batch.tasks.isEmpty)
    #expect(batch.workItems.isEmpty)
}

@Test func workItemsGainPlacedItemsAndLoseDeletedOnes() {
    let batch = build([item("1"), item("2", checked: true), item("3", project: "home"), item("4", deleted: true)],
                      workItems: ["4", "5"])
    #expect(batch.workItems == ["1", "2", "5"])
}

@Test func anEchoedItemStillJoinsWorkItems() {
    let journal = [ActionJournal.Entry(time: "2026-10-07T15:00:01Z", action: "task.created", todoistID: "1", name: nil)]
    let batch = build([item("1")], journal: journal)
    #expect(batch.tasks.isEmpty)
    #expect(batch.workItems == ["1"])
}
