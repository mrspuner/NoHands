import Foundation
import Testing
@testable import TodoistSync

/// An in-memory Todoist account.
private actor FakeAccount: TodoistAPI {
    var projectList: [TodoistProject]
    var tasks: [NewTodoistTask] = []
    var projectCalls = 0
    var taskCreationError: (any Error)?
    private var counter = 0

    init(_ projects: [TodoistProject] = []) { projectList = projects }

    func failTaskCreation(with error: any Error) { taskCreationError = error }

    func projects() async throws -> [TodoistProject] {
        projectCalls += 1
        // A suspension point, so two overlapping requests really do interleave here.
        try await Task.sleep(for: .milliseconds(20))
        return projectList
    }

    func createProject(name: String, parentID: String?) async throws -> TodoistProject {
        counter += 1
        let project = TodoistProject(id: "new\(counter)", name: name, parentID: parentID)
        projectList.append(project)
        return project
    }

    func createTask(_ task: NewTodoistTask) async throws -> String {
        if let taskCreationError { throw taskCreationError }
        tasks.append(task)
        counter += 1
        return "task\(counter)"
    }
}

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
    let result = try await TaskCreator(api: account, journal: journal()).create(request())

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
    let result = try await TaskCreator(api: account, journal: journal()).create(request(project: nil))
    #expect(result.projectID == "a")
}

@Test func aMissingAreaAndProjectAreBothCreatedAndNested() async throws {
    let account = FakeAccount()
    let result = try await TaskCreator(api: account, journal: journal()).create(request())

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
    let result = try await TaskCreator(api: account, journal: journal())
        .create(request(area: "Сколково", project: "Портфолио"))

    #expect(result.createdProjects == ["Портфолио"])
    #expect(result.projectID != "rp")
}

// A subproject called like an area is not that area.
@Test func onlyRootProjectsCountAsAreas() async throws {
    let nested = TodoistProject(id: "x", name: "Сколково", parentID: "something")
    let account = FakeAccount([nested])
    let result = try await TaskCreator(api: account, journal: journal()).create(request(project: nil))
    #expect(result.createdProjects == ["Сколково"])
}

@Test func namesMatchIgnoringCaseAndSurroundingSpaces() async throws {
    let account = FakeAccount([
        TodoistProject(id: "a", name: " сколково", parentID: nil),
        TodoistProject(id: "b", name: "ХИБИНЫ ", parentID: "a"),
    ])
    let result = try await TaskCreator(api: account, journal: journal()).create(request())
    #expect(result.createdProjects.isEmpty)
    #expect(result.projectID == "b")
}

// Two candidates and no way to choose: a named refusal, not a guess.
@Test func twoMatchingAreasAreRefused() async {
    let account = FakeAccount([skolkovo, TodoistProject(id: "a2", name: "Сколково", parentID: nil)])
    await #expect(throws: ResolveError.ambiguousProject("Сколково")) {
        _ = try await TaskCreator(api: account, journal: journal()).create(request())
    }
    #expect(await account.tasks.isEmpty)
}

@Test func everyOwnActionIsJournaled() async throws {
    let account = FakeAccount()
    let log = journal()
    let result = try await TaskCreator(api: account, journal: log).create(request())

    let entries = try await log.entries()
    #expect(entries.map(\.action) == ["project.created", "project.created", "task.created"])
    #expect(entries.map(\.todoistID) == ["new1", "new2", result.id])
}

// The task already exists in Todoist when the journal fails. Answering with an error would make
// the agent retry and create it twice; the id goes back with a warning instead.
@Test func aJournalFailureDoesNotHideACreatedTask() async throws {
    let account = FakeAccount([skolkovo, khibiny])
    let broken = ActionJournal(url: URL(fileURLWithPath: "/dev/null/j.jsonl"))
    let result = try await TaskCreator(api: account, journal: broken).create(request())

    #expect(result.id == "task1")
    #expect(result.warning != nil)
}

// Todoist may have committed the task before the failure reached us; a retry could duplicate it.
private func creationOutcome(failingWith error: any Error) async -> (any Error)? {
    let account = FakeAccount([skolkovo, khibiny])
    await account.failTaskCreation(with: error)
    do {
        _ = try await TaskCreator(api: account, journal: journal()).create(request())
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
    let creator = TaskCreator(api: account, journal: journal())

    async let first = creator.create(request(project: nil))
    async let second = creator.create(request(project: nil))
    let results = try await [first, second]

    let areas = await account.projectList.filter { $0.name == "Сколково" }
    #expect(areas.count == 1)
    #expect(results[0].projectID == results[1].projectID)
}
