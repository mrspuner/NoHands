import Foundation
import Testing
@testable import TodoistSync

private func journal() -> ActionJournal {
    ActionJournal(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("tc-\(UUID().uuidString)/todoist-actions.jsonl"))
}

private let skolkovo = TodoistProject(id: "a", name: "Сколково", parentID: nil)
private let khibiny = TodoistProject(id: "b", name: "Хибины", parentID: "a")

private func request(area: String = "Сколково", project: String? = "Хибины") -> CreateTaskRequest {
    CreateTaskRequest(title: "T", description: "D", due: "2026-10-10", area: area, project: project)
}

@Test func aTaskLandsInAnExistingProject() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    let result = try await TodoistOperations(api: account, journal: journal()).create(request())

    #expect(result.projectID == "b")
    #expect(result.createdProjects.isEmpty)
    #expect(result.warning == nil)
    let tasks = await account.tasks
    #expect(tasks == [NewTodoistTask(content: "T", description: "D", dueDate: "2026-10-10", projectID: "b")])
    #expect(result.id == "task1")
}

// A task from «Общее» goes into the area project itself.
@Test func aTaskWithoutAProjectLandsInTheArea() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    let result = try await TodoistOperations(api: account, journal: journal()).create(request(project: nil))
    #expect(result.projectID == "a")
}

@Test func aMissingAreaAndProjectAreBothCreatedAndNested() async throws {
    let account = FakeAccount()
    let result = try await TodoistOperations(api: account, journal: journal()).create(request())

    #expect(result.createdProjects == ["Сколково", "Хибины"])
    let projects = await account.projectList
    #expect(projects[0] == TodoistProject(id: "new1", name: "Сколково", parentID: nil))
    #expect(projects[1] == TodoistProject(id: "new2", name: "Хибины", parentID: "new1"))
    #expect(result.projectID == "new2")
}

// Same name, different area: the pair "parent + name" is what is matched, never the name alone.
@Test func aSameNamedProjectInAnotherAreaIsNotReused() async throws {
    let roox = TodoistProject(id: "r", name: "RooX", parentID: nil)
    let rooxPortfolio = TodoistProject(id: "rp", name: "Портфолио", parentID: "r")
    let account = FakeAccount([skolkovo, roox, rooxPortfolio])
    let result = try await TodoistOperations(api: account, journal: journal())
        .create(request(area: "Сколково", project: "Портфолио"))

    #expect(result.createdProjects == ["Портфолио"])
    #expect(result.projectID != "rp")
}

// A subproject called like an area is not that area.
@Test func onlyRootProjectsCountAsAreas() async throws {
    let nested = TodoistProject(id: "x", name: "Сколково", parentID: "something")
    let account = FakeAccount([nested])
    let result = try await TodoistOperations(api: account, journal: journal()).create(request(project: nil))
    #expect(result.createdProjects == ["Сколково"])
}

@Test func namesMatchIgnoringCaseAndSurroundingSpaces() async throws {
    let account = FakeAccount([
        TodoistProject(id: "a", name: " сколково", parentID: nil),
        TodoistProject(id: "b", name: "ХИБИНЫ ", parentID: "a"),
    ])
    let result = try await TodoistOperations(api: account, journal: journal()).create(request())
    #expect(result.createdProjects.isEmpty)
    #expect(result.projectID == "b")
}

// Two candidates and no way to choose: a named refusal, not a guess.
@Test func twoMatchingAreasAreRefused() async {
    let account = FakeAccount([skolkovo, TodoistProject(id: "a2", name: "Сколково", parentID: nil)])
    await #expect(throws: ResolveError.ambiguousProject("Сколково")) {
        _ = try await TodoistOperations(api: account, journal: journal()).create(request())
    }
    #expect(await account.tasks.isEmpty)
}

@Test func everyOwnActionIsJournaled() async throws {
    let account = FakeAccount()
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log).create(request())

    let entries = try await log.entries()
    #expect(entries.map(\.action) == ["project.created", "project.created", "task.created"])
    #expect(entries.map(\.todoistID) == ["new1", "new2", result.id])
}

// The task already exists in Todoist when the journal fails. Answering with an error would make
// the agent retry and create it twice; the id goes back with a warning instead.
@Test func aJournalFailureDoesNotHideACreatedTask() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    let broken = ActionJournal(url: URL(fileURLWithPath: "/dev/null/j.jsonl"))
    let result = try await TodoistOperations(api: account, journal: broken).create(request())

    #expect(result.id == "task1")
    #expect(result.warning != nil)
}

// Todoist may have committed the task before the failure reached us; a retry could duplicate it.
private func creationOutcome(failingWith error: any Error) async -> (any Error)? {
    let account = FakeAccount([skolkovo, khibiny])
    await account.failTaskCreation(with: error)
    do {
        _ = try await TodoistOperations(api: account, journal: journal()).create(request())
        return nil
    } catch {
        return error
    }
}

@Test func aTodoist5xxOnTaskCreationIsOutcomeUnknown() async {
    let error = await creationOutcome(failingWith: TodoistError.requestFailed(status: 500, message: "down"))
    #expect(error as? TaskCreateError == .outcomeUnknown("Todoist answered 500: down"))
}

@Test func aTransportFailureOnTaskCreationIsOutcomeUnknown() async {
    let error = await creationOutcome(failingWith: URLError(.timedOut))
    guard case .outcomeUnknown? = error as? TaskCreateError else {
        Issue.record("expected outcomeUnknown, got \(String(describing: error))")
        return
    }
}

@Test func anUnreadableAnswerOnTaskCreationIsOutcomeUnknown() async {
    let error = await creationOutcome(failingWith: TodoistError.unexpectedResponse("no id"))
    guard case .outcomeUnknown? = error as? TaskCreateError else {
        Issue.record("expected outcomeUnknown, got \(String(describing: error))")
        return
    }
}

// A 4xx means Todoist refused: the task does not exist and the error is final.
@Test func aTodoist4xxOnTaskCreationPropagatesUnchanged() async {
    let error = await creationOutcome(failingWith: TodoistError.requestFailed(status: 403, message: "no"))
    #expect(error as? TodoistError == .requestFailed(status: 403, message: "no"))
}

@Test func aMissingTokenOnTaskCreationPropagatesUnchanged() async {
    let error = await creationOutcome(failingWith: TodoistError.tokenMissing)
    #expect(error as? TodoistError == .tokenMissing)
}

// Two agent requests for a brand-new area at the same moment must not create it twice.
@Test func overlappingRequestsCreateTheAreaOnce() async throws {
    let account = FakeAccount()
    let creator = TodoistOperations(api: account, journal: journal())

    async let first = creator.create(request(project: nil))
    async let second = creator.create(request(project: nil))
    let results = try await [first, second]

    let areas = await account.projectList.filter { $0.name == "Сколково" }
    #expect(areas.count == 1)
    #expect(results[0].projectID == results[1].projectID)
}

// MARK: - Slice 2 operations

private let brandsim = TodoistProject(id: "c", name: "Бренд симулятор", parentID: "a")

@Test func anUpdateSendsTheWholeTaskAndStaysPut() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    await account.addTask(id: "t1", projectID: "b")
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log).update(id: "t1", request())

    #expect(result == UpdateTaskResult(projectID: "b", moved: false, createdProjects: [], warning: nil))
    let updates = await account.updates
    #expect(updates.count == 1)
    #expect(updates[0].update == TaskUpdate(content: "T", description: "D", dueDate: "2026-10-10"))
    #expect(await account.moves.isEmpty)
    #expect(try await log.entries().map(\.action) == ["task.updated"])
}

@Test func anUpdateIntoAnotherProjectMovesTheTask() async throws {
    let account = FakeAccount([skolkovo, khibiny, brandsim])
    await account.addTask(id: "t1", projectID: "b")
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log)
        .update(id: "t1", request(project: "Бренд симулятор"))

    #expect(result.moved)
    #expect(result.projectID == "c")
    let moves = await account.moves
    #expect(moves.count == 1 && moves[0].projectID == "c")
    #expect(try await log.entries().map(\.action) == ["task.updated", "task.moved"])
}

@Test func anUpdateIntoANewProjectCreatesItFirst() async throws {
    let account = FakeAccount([skolkovo])
    await account.addTask(id: "t1", projectID: "a")
    let result = try await TodoistOperations(api: account, journal: journal()).update(id: "t1", request())
    #expect(result.createdProjects == ["Хибины"])
    #expect(result.moved)
}

// The task was deleted in Todoist: a named refusal, and nothing is created in its place.
@Test func updatingAMissingTaskIsTaskNotFound() async {
    let account = FakeAccount([skolkovo, khibiny])
    await #expect(throws: OperationError.taskNotFound("gone")) {
        _ = try await TodoistOperations(api: account, journal: journal()).update(id: "gone", request())
    }
    #expect(await account.updates.isEmpty)
    #expect(await account.tasks.isEmpty)
}

@Test func closingRecordsTheAction() async throws {
    let account = FakeAccount()
    await account.addTask(id: "t1", projectID: "a")
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log).close(id: "t1")
    #expect(result == OperationResult(already: false, warning: nil))
    #expect(await account.closed == ["t1"])
    #expect(try await log.entries().map(\.action) == ["task.closed"])
}

// Already gone in Todoist counts as done: closing and deleting are safe to repeat.
@Test func closingAMissingTaskIsAlreadyDone() async throws {
    let log = journal()
    let result = try await TodoistOperations(api: FakeAccount(), journal: log).close(id: "gone")
    #expect(result == OperationResult(already: true, warning: nil))
    #expect(try await log.entries().isEmpty)
}

@Test func deletingRecordsTheAction() async throws {
    let account = FakeAccount()
    await account.addTask(id: "t1", projectID: "a")
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log).delete(id: "t1")
    #expect(result.already == false)
    #expect(await account.deleted == ["t1"])
    #expect(try await log.entries().map(\.action) == ["task.deleted"])
}

@Test func deletingAMissingTaskIsAlreadyDone() async throws {
    let result = try await TodoistOperations(api: FakeAccount(), journal: journal()).delete(id: "gone")
    #expect(result.already)
}

@Test func ensureProjectCreatesAreaAndProject() async throws {
    let account = FakeAccount()
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log)
        .ensureProject(ProjectRequest(area: "RooX", project: "ИНДИД"))
    #expect(result.created)
    #expect(result.id == "new2")
    #expect(try await log.entries().map(\.action) == ["project.created", "project.created"])
}

@Test func ensureProjectFindsAnExistingOne() async throws {
    let result = try await TodoistOperations(api: FakeAccount([skolkovo, khibiny]), journal: journal())
        .ensureProject(ProjectRequest(area: "Сколково", project: "хибины"))
    #expect(result == EnsureProjectResult(id: "b", created: false, warning: nil))
}

@Test func archivingAnActiveProject() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log)
        .archiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    #expect(result.already == false)
    #expect(await account.archivedIDs == ["b"])
    #expect(try await log.entries().map(\.action) == ["project.archived"])
}

@Test func archivingAnArchivedProjectIsAlreadyDone() async throws {
    let account = FakeAccount([skolkovo])
    await account.setArchived([khibiny])
    let result = try await TodoistOperations(api: account, journal: journal())
        .archiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    #expect(result.already)
    #expect(await account.archivedIDs.isEmpty)
}

@Test func archivingAnUnknownProjectIsProjectNotFound() async {
    await #expect(throws: OperationError.projectNotFound("Хибины")) {
        _ = try await TodoistOperations(api: FakeAccount([skolkovo]), journal: journal())
            .archiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    }
}

@Test func archivingInAnUnknownAreaIsProjectNotFound() async {
    await #expect(throws: OperationError.projectNotFound("Сколково")) {
        _ = try await TodoistOperations(api: FakeAccount(), journal: journal())
            .archiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    }
}

@Test func unarchivingAnArchivedProject() async throws {
    let account = FakeAccount([skolkovo])
    await account.setArchived([khibiny])
    let log = journal()
    let result = try await TodoistOperations(api: account, journal: log)
        .unarchiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    #expect(result.already == false)
    #expect(await account.unarchivedIDs == ["b"])
    #expect(try await log.entries().map(\.action) == ["project.unarchived"])
}

@Test func unarchivingAnActiveProjectIsAlreadyDone() async throws {
    let result = try await TodoistOperations(api: FakeAccount([skolkovo, khibiny]), journal: journal())
        .unarchiveProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    #expect(result.already)
}

// Creation and an update into the same brand-new area share one queue: the area is created once.
@Test func overlappingCreateAndUpdateCreateTheAreaOnce() async throws {
    let account = FakeAccount()
    await account.addTask(id: "t1", projectID: "elsewhere")
    let operations = TodoistOperations(api: account, journal: journal())

    async let created = operations.create(request(project: nil))
    async let updated = operations.update(id: "t1", request(project: nil))
    _ = try await (created, updated)

    #expect(await account.projectList.filter { $0.name == "Сколково" }.count == 1)
}
