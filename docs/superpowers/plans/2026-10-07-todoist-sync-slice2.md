# Синхронизация с Todoist — второй срез. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Агент Башки через `127.0.0.1:41730` изменяет, переносит, закрывает и удаляет задачи Todoist и создаёт, архивирует и разархивирует проекты; каждое действие NoHands записывается в журнал.

**Architecture:** Клиент `TodoistClient` получает восемь новых вызовов API v1 и отдельную ошибку `notFound` для HTTP 404. `TaskCreator` переименовывается в `TodoistOperations`: тот же актор с той же последовательной очередью теперь выполняет все операции, поэтому создание и изменение в одной новой области не создадут её дважды. Маршрутизатор `TodoistEndpoint` переходит с замыкания на протокол `TodoistOperating` и разбирает пути с `id`. `AppDelegate` меняет одну строку сборки.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 15, Foundation, Network.framework, swift-testing. Новых зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-10-07-todoist-sync-slice2-design.md` (дополняет `docs/superpowers/specs/2026-10-07-todoist-sync-design.md`)

## Global Constraints

- Новых зависимостей SPM нет. Идентификаторы, комментарии, сообщения об ошибках — по-английски.
- Токен Todoist только в Keychain (`nohands-todoist` / `api-token`), нигде не печатается и не попадает в ответы и ошибки.
- Ни один тест не ходит в настоящий Todoist, не читает настоящий Keychain и не пишет в настоящий `~/Library/Application Support/NoHands/`.
- Todoist API v1, база `https://api.todoist.com/api/v1/`. Проверено живьём 2026-10-07:
  - изменение задачи — `POST tasks/<id>`; поле `project_id` в нём **молча игнорируется**, перенос — только `POST tasks/<id>/move` с `{"project_id": …}`;
  - снять срок — `"due_string": "no date"`; `"due_date": null` **молча игнорируется**; установить срок — только `due_date`;
  - `POST tasks/<id>/close` отвечает `204`, повторное закрытие — тоже `204`;
  - `GET projects/archived` существует (пагинирован так же, как `projects`).
- Ответ Todoist на несуществующий, но правильно сформированный `id` живьём не проверен (CloudFront ограничил частоту проб). Код трактует HTTP `404` как `TodoistError.notFound`; живая проверка в Task 4.
- `id` в пути локального запроса — только ASCII-буквы и цифры, иначе `400`.
- Коммиты — после каждой задачи, в ветке `todoist-sync-slice2`. Никаких push.
- Базовая линия: **810 тестов, 0 падений** (`swift test`).

## Review Focus

1. **Изменение задачи, удалённой в Todoist.** Ожидается `404` с понятным текстом, в Todoist ничего не создано. Тест в Task 2.
2. **Изменение без срока у задачи со сроком.** Ожидается, что срок снят через `due_string: "no date"`, а не пропущен. Тест в Task 1.
3. **Перенос между проектами.** Ожидается отдельный вызов `move` и запись `task.moved`; при совпадении проектов `move` не вызывается. Тест в Task 2.
4. **Повторное закрытие или удаление уже исчезнувшей задачи.** Ожидается `200` с `"already": true`, без ошибки и без записи в журнал. Тест в Task 2.
5. **Архивация уже архивного проекта и разархивация активного.** Ожидается `200` с `"already": true`. Тест в Task 2.

---

### Task 1: Клиент — новые вызовы и `notFound`

**Files:**
- Modify: `Features/TodoistSync/TodoistAPI.swift`
- Modify: `Features/TodoistSync/TodoistClient.swift`
- Modify: `Features/TodoistSync/TaskCreator.swift` (только `switch` в `perform`: новый `case .notFound`)
- Modify: `Features/TodoistSync/TodoistEndpoint.swift` (только `switch` по `TodoistError`: новый `case .notFound`)
- Create: `Tests/TodoistSyncTests/FakeAccount.swift` (общий фейк вместо приватного в `TaskCreatorTests.swift`)
- Modify: `Tests/TodoistSyncTests/TaskCreatorTests.swift` (удалить приватный `FakeAccount`)
- Test: `Tests/TodoistSyncTests/TodoistClientTests.swift`

**Interfaces:**
- Consumes: существующие `TodoistClient`, `TodoistAPI`, `TodoistError`.
- Produces:
  - `TodoistError.notFound` — HTTP 404 от Todoist.
  - `public struct TodoistTaskInfo: Equatable, Sendable, Decodable { id: String; projectID: String }`
  - `public struct TaskUpdate: Equatable, Sendable { content: String; description: String?; dueDate: String? }`
  - в `TodoistAPI`: `task(id:) -> TodoistTaskInfo`, `updateTask(id:_:)`, `moveTask(id:toProject:)`, `closeTask(id:)`, `deleteTask(id:)`, `archivedProjects() -> [TodoistProject]`, `archiveProject(id:)`, `unarchiveProject(id:)`
  - `final actor FakeAccount: TodoistAPI` в тестах (internal) — см. шаг 2.

- [ ] **Step 1: Ветка**

Run: `git checkout -b todoist-sync-slice2`

- [ ] **Step 2: Общий фейк аккаунта**

Создать `Tests/TodoistSyncTests/FakeAccount.swift` и удалить из `Tests/TodoistSyncTests/TaskCreatorTests.swift` приватный `actor FakeAccount` целиком (его прежнее поведение сохранено ниже: `projectList`, `tasks`, `projectCalls`, `setFailTaskCreation`, `setCreateTaskError`, задержка 20 мс в `projects()`, счётчик `new<N>`/`task<N>`):

```swift
import Foundation
@testable import TodoistSync

/// An in-memory Todoist account shared by the operation and creator tests.
actor FakeAccount: TodoistAPI {
    var projectList: [TodoistProject]
    var archivedList: [TodoistProject] = []
    var tasks: [NewTodoistTask] = []
    /// Task id → project id, for every task the fake knows about.
    var taskProjects: [String: String] = [:]
    var updates: [(id: String, update: TaskUpdate)] = []
    var moves: [(id: String, projectID: String)] = []
    var closed: [String] = []
    var deleted: [String] = []
    var archivedIDs: [String] = []
    var unarchivedIDs: [String] = []
    var projectCalls = 0
    var createTaskError: (any Error)?
    private var counter = 0

    init(_ projects: [TodoistProject] = []) { projectList = projects }

    func setFailTaskCreation() { createTaskError = TodoistError.requestFailed(status: 500, message: "down") }
    func setCreateTaskError(_ error: any Error) { createTaskError = error }
    func addTask(id: String, projectID: String) { taskProjects[id] = projectID }
    func setArchived(_ projects: [TodoistProject]) { archivedList = projects }

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
        if let createTaskError { throw createTaskError }
        tasks.append(task)
        counter += 1
        let id = "task\(counter)"
        taskProjects[id] = task.projectID
        return id
    }

    func task(id: String) async throws -> TodoistTaskInfo {
        guard let projectID = taskProjects[id] else { throw TodoistError.notFound }
        return TodoistTaskInfo(id: id, projectID: projectID)
    }

    func updateTask(id: String, _ update: TaskUpdate) async throws {
        guard taskProjects[id] != nil else { throw TodoistError.notFound }
        updates.append((id, update))
    }

    func moveTask(id: String, toProject projectID: String) async throws {
        guard taskProjects[id] != nil else { throw TodoistError.notFound }
        taskProjects[id] = projectID
        moves.append((id, projectID))
    }

    func closeTask(id: String) async throws {
        guard taskProjects.removeValue(forKey: id) != nil else { throw TodoistError.notFound }
        closed.append(id)
    }

    func deleteTask(id: String) async throws {
        guard taskProjects.removeValue(forKey: id) != nil else { throw TodoistError.notFound }
        deleted.append(id)
    }

    func archivedProjects() async throws -> [TodoistProject] { archivedList }

    func archiveProject(id: String) async throws {
        guard let index = projectList.firstIndex(where: { $0.id == id }) else { throw TodoistError.notFound }
        archivedList.append(projectList.remove(at: index))
        archivedIDs.append(id)
    }

    func unarchiveProject(id: String) async throws {
        guard let index = archivedList.firstIndex(where: { $0.id == id }) else { throw TodoistError.notFound }
        projectList.append(archivedList.remove(at: index))
        unarchivedIDs.append(id)
    }
}
```

В `TaskCreatorTests.swift` вызовы, которые раньше использовали приватный фейк, остаются без изменений: имена методов и свойств те же. Если тесты обращались к `failTaskCreation` напрямую, заменить на `setFailTaskCreation()`.

- [ ] **Step 3: Написать падающие тесты клиента**

Дописать в конец `Tests/TodoistSyncTests/TodoistClientTests.swift`:

```swift
// MARK: - Slice 2 calls

@Test func a404BecomesNotFound() async {
    let transport = FakeTransport([(404, "Not found")])
    await #expect(throws: TodoistError.notFound) {
        _ = try await client(transport).task(id: "t1")
    }
}

@Test func taskReadsItsProject() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1","project_id":"p9","content":"x"}"#)])
    let info = try await client(transport).task(id: "t1")
    #expect(info == TodoistTaskInfo(id: "t1", projectID: "p9"))
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
    #expect(transport.requests[0].httpMethod == "GET")
}

@Test func updateSendsTheWholeTask() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    try await client(transport).updateTask(id: "t1", TaskUpdate(content: "T", description: "D", dueDate: "2026-10-10"))
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
    let body = try json(request)
    #expect(body["content"] as? String == "T")
    #expect(body["description"] as? String == "D")
    #expect(body["due_date"] as? String == "2026-10-10")
    #expect(body["due_string"] == nil)
}

// Verified live: `due_date: null` is silently ignored; only `due_string: "no date"` clears it.
// An update sends the whole task, so an absent due date means "no due date".
@Test func anUpdateWithoutDueClearsIt() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    try await client(transport).updateTask(id: "t1", TaskUpdate(content: "T", description: nil, dueDate: nil))
    let body = try json(transport.requests[0])
    #expect(body["due_string"] as? String == "no date")
    #expect(body["due_date"] == nil)
    #expect(body["description"] as? String == "")
}

// Verified live: `project_id` in an update is silently ignored; moving is its own call.
@Test func moveUsesTheMoveEndpoint() async throws {
    let transport = FakeTransport([(200, "{}")])
    try await client(transport).moveTask(id: "t1", toProject: "p2")
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1/move")
    #expect(try json(request)["project_id"] as? String == "p2")
}

@Test func closeAcceptsAnEmpty204() async throws {
    let transport = FakeTransport([(204, "")])
    try await client(transport).closeTask(id: "t1")
    #expect(transport.requests[0].httpMethod == "POST")
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1/close")
}

@Test func deleteUsesDELETE() async throws {
    let transport = FakeTransport([(204, "")])
    try await client(transport).deleteTask(id: "t1")
    #expect(transport.requests[0].httpMethod == "DELETE")
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/tasks/t1")
}

@Test func archivedProjectsFollowTheCursor() async throws {
    let transport = FakeTransport([
        (200, #"{"results":[{"id":"a","name":"A","parent_id":null}],"next_cursor":"c"}"#),
        (200, #"{"results":[{"id":"b","name":"B","parent_id":"a"}],"next_cursor":null}"#),
    ])
    let projects = try await client(transport).archivedProjects()
    #expect(projects.map(\.id) == ["a", "b"])
    #expect(transport.requests[0].url!.absoluteString == "https://api.todoist.com/api/v1/projects/archived?limit=200")
    #expect(transport.requests[1].url!.absoluteString == "https://api.todoist.com/api/v1/projects/archived?limit=200&cursor=c")
}

@Test func archiveAndUnarchiveHitTheirEndpoints() async throws {
    let transport = FakeTransport([(200, "{}"), (200, "{}")])
    let client = client(transport)
    try await client.archiveProject(id: "p1")
    try await client.unarchiveProject(id: "p1")
    #expect(transport.requests.map { $0.url!.absoluteString } == [
        "https://api.todoist.com/api/v1/projects/p1/archive",
        "https://api.todoist.com/api/v1/projects/p1/unarchive",
    ])
    #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" })
}
```

- [ ] **Step 4: Запустить, убедиться, что падает**

Run: `swift test --filter TodoistSyncTests`
Expected: FAIL — не компилируется (`TodoistTaskInfo`, `TaskUpdate`, `notFound`, новые методы не определены).

- [ ] **Step 5: Типы и протокол**

В `Features/TodoistSync/TodoistAPI.swift`:

После `NewTodoistTask` добавить:

```swift
public struct TodoistTaskInfo: Equatable, Sendable, Decodable {
    public let id: String
    public let projectID: String

    public init(id: String, projectID: String) {
        self.id = id
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
    }
}

/// The whole editable state of a task. Sent whole on every update, so a retry is harmless and
/// an absent field means "empty", not "unchanged".
public struct TaskUpdate: Equatable, Sendable {
    public let content: String
    public let description: String?
    public let dueDate: String?

    public init(content: String, description: String?, dueDate: String?) {
        self.content = content
        self.description = description
        self.dueDate = dueDate
    }
}
```

В протокол `TodoistAPI` после `createTask` добавить:

```swift
    func task(id: String) async throws -> TodoistTaskInfo
    func updateTask(id: String, _ update: TaskUpdate) async throws
    func moveTask(id: String, toProject projectID: String) async throws
    func closeTask(id: String) async throws
    func deleteTask(id: String) async throws
    func archivedProjects() async throws -> [TodoistProject]
    func archiveProject(id: String) async throws
    func unarchiveProject(id: String) async throws
```

В `TodoistError` добавить case и описание:

```swift
    /// HTTP 404: Todoist has no such task or project (deleted, or never existed).
    case notFound
```

```swift
        case .notFound:
            return "Todoist has no such task or project"
```

- [ ] **Step 6: Клиент**

В `Features/TodoistSync/TodoistClient.swift`:

Заменить тело `projects()` вызовом общего хелпера и добавить хелпер:

```swift
    public func projects() async throws -> [TodoistProject] {
        try await pagedProjects(path: "projects")
    }

    public func archivedProjects() async throws -> [TodoistProject] {
        try await pagedProjects(path: "projects/archived")
    }

    private func pagedProjects(path: String) async throws -> [TodoistProject] {
        struct Page: Decodable {
            let results: [TodoistProject]
            let nextCursor: String?
            enum CodingKeys: String, CodingKey {
                case results
                case nextCursor = "next_cursor"
            }
        }
        var all: [TodoistProject] = []
        var cursor: String?
        repeat {
            var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let data = try await send(method: "GET", url: components.url!, body: nil)
            let page = try Self.decode(Page.self, from: data)
            all += page.results
            // A repeated or empty cursor would loop forever on a Todoist bug.
            guard page.nextCursor != cursor, page.nextCursor?.isEmpty != true else { break }
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }
```

После `createTask` добавить:

```swift
    public func task(id: String) async throws -> TodoistTaskInfo {
        let data = try await send(method: "GET", url: Self.taskURL(id), body: nil)
        return try Self.decode(TodoistTaskInfo.self, from: data)
    }

    public func updateTask(id: String, _ update: TaskUpdate) async throws {
        var body: [String: Any] = ["content": update.content, "description": update.description ?? ""]
        if let dueDate = update.dueDate {
            body["due_date"] = dueDate
        } else {
            // The only way to clear a due date; `due_date: null` is ignored (verified 2026-10-07).
            // `due_string` is never used to set a date: it is parsed by language.
            body["due_string"] = "no date"
        }
        _ = try await send(method: "POST", url: Self.taskURL(id), body: body)
    }

    public func moveTask(id: String, toProject projectID: String) async throws {
        _ = try await send(method: "POST", url: Self.taskURL(id, "move"), body: ["project_id": projectID])
    }

    public func closeTask(id: String) async throws {
        _ = try await send(method: "POST", url: Self.taskURL(id, "close"), body: nil)
    }

    public func deleteTask(id: String) async throws {
        _ = try await send(method: "DELETE", url: Self.taskURL(id), body: nil)
    }

    public func archiveProject(id: String) async throws {
        _ = try await send(method: "POST", url: Self.projectURL(id, "archive"), body: nil)
    }

    public func unarchiveProject(id: String) async throws {
        _ = try await send(method: "POST", url: Self.projectURL(id, "unarchive"), body: nil)
    }

    private static func taskURL(_ id: String, _ action: String? = nil) -> URL {
        let url = base.appendingPathComponent("tasks").appendingPathComponent(id)
        return action.map { url.appendingPathComponent($0) } ?? url
    }

    private static func projectURL(_ id: String, _ action: String) -> URL {
        base.appendingPathComponent("projects").appendingPathComponent(id).appendingPathComponent(action)
    }
```

В `send`, перед проверкой `(200..<300).contains(http.statusCode)`:

```swift
        if http.statusCode == 404 {
            throw TodoistError.notFound
        }
```

- [ ] **Step 7: Исчерпывающие `switch`**

В `Features/TodoistSync/TaskCreator.swift`, в `catch let error as TodoistError` внутри `perform`, расширить первую ветку:

```swift
            case .requestFailed(let status, _) where (400..<500).contains(status):
                throw error  // Todoist refused: the task does not exist.
            case .notFound:
                throw error  // The target project vanished; Todoist refused the task.
```

В `Features/TodoistSync/TodoistEndpoint.swift`, в `switch error` по `TodoistError`:

```swift
            case .notFound:
                return .json(404, ["error": error.localizedDescription])
```

- [ ] **Step 8: Тесты зелёные**

Run: `swift test --filter TodoistSyncTests`
Expected: PASS.

Run: `swift test`
Expected: 810 + новые, 0 падений.

- [ ] **Step 9: Коммит**

```bash
git add Features/TodoistSync Tests/TodoistSyncTests
git commit -m "Todoist: чтение, изменение, перенос, закрытие, удаление задач и архив проектов в клиенте"
```

---

### Task 2: `TodoistOperations` — все операции в одной очереди

**Files:**
- Rename: `Features/TodoistSync/TaskCreator.swift` → `Features/TodoistSync/TodoistOperations.swift` (`git mv`)
- Rename: `Tests/TodoistSyncTests/TaskCreatorTests.swift` → `Tests/TodoistSyncTests/TodoistOperationsTests.swift` (`git mv`)
- Create: `Features/TodoistSync/ProjectRequest.swift`
- Modify: `Features/TodoistSync/ActionJournal.swift` (новые виды действий)
- Modify: `App/AppDelegate.swift` (`TaskCreator(` → `TodoistOperations(`; endpoint по-прежнему через замыкание до Task 3)
- Test: `Tests/TodoistSyncTests/TodoistOperationsTests.swift`, `Tests/TodoistSyncTests/ProjectRequestTests.swift`

**Interfaces:**
- Consumes: Task 1 (`TodoistAPI` с новыми методами, `TodoistError.notFound`, `TaskUpdate`, `TodoistTaskInfo`, `FakeAccount`).
- Produces:
  - `public struct ProjectRequest: Equatable, Sendable { area: String; project: String }` + `static func decode(_ data: Data) throws -> ProjectRequest` (ошибки `RequestError.malformedJSON`, `.missingField`)
  - `public struct UpdateTaskResult: Equatable, Sendable { projectID: String; moved: Bool; createdProjects: [String]; warning: String? }`
  - `public struct OperationResult: Equatable, Sendable { already: Bool; warning: String? }`
  - `public struct EnsureProjectResult: Equatable, Sendable { id: String; created: Bool; warning: String? }`
  - `public enum OperationError: Error, Equatable, LocalizedError { case taskNotFound(String); case projectNotFound(String) }`
  - `public protocol TodoistOperating: Sendable` с методами `create(_:)`, `update(id:_:)`, `close(id:)`, `delete(id:)`, `ensureProject(_:)`, `archiveProject(_:)`, `unarchiveProject(_:)`
  - `public actor TodoistOperations: TodoistOperating` с `public init(api: any TodoistAPI, journal: ActionJournal)`
  - `ActionJournal.Action`: `taskUpdated = "task.updated"`, `taskMoved = "task.moved"`, `taskClosed = "task.closed"`, `taskDeleted = "task.deleted"`, `projectArchived = "project.archived"`, `projectUnarchived = "project.unarchived"`

- [ ] **Step 1: Переименование**

```bash
git mv Features/TodoistSync/TaskCreator.swift Features/TodoistSync/TodoistOperations.swift
git mv Tests/TodoistSyncTests/TaskCreatorTests.swift Tests/TodoistSyncTests/TodoistOperationsTests.swift
```

В `TodoistOperationsTests.swift` заменить все `TaskCreator(` на `TodoistOperations(`. В `App/AppDelegate.swift` заменить `TaskCreator(` на `TodoistOperations(` и имя переменной `creator` на `operations`.

- [ ] **Step 2: Падающие тесты `ProjectRequest`**

Создать `Tests/TodoistSyncTests/ProjectRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

@Test func aProjectRequestIsDecodedAndTrimmed() throws {
    let request = try ProjectRequest.decode(Data(#"{"area":" RooX ","project":" ИНДИД "}"#.utf8))
    #expect(request == ProjectRequest(area: "RooX", project: "ИНДИД"))
}

@Test func aProjectRequestNeedsBothFields() {
    #expect(throws: RequestError.missingField("project")) {
        try ProjectRequest.decode(Data(#"{"area":"RooX"}"#.utf8))
    }
    #expect(throws: RequestError.missingField("area")) {
        try ProjectRequest.decode(Data(#"{"area":"  ","project":"P"}"#.utf8))
    }
}

@Test func aProjectRequestThatIsNotAnObjectIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try ProjectRequest.decode(Data("[]".utf8)) }
}
```

- [ ] **Step 3: Падающие тесты операций**

Дописать в конец `Tests/TodoistSyncTests/TodoistOperationsTests.swift` (хелперы `journal()`, `skolkovo`, `khibiny`, `request(area:project:)` уже есть в файле):

```swift
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
```

- [ ] **Step 4: Запустить, убедиться, что падает**

Run: `swift test --filter TodoistSyncTests`
Expected: FAIL — не компилируется (`ProjectRequest`, `TodoistOperations.update` и др. не определены).

- [ ] **Step 5: `ProjectRequest`**

Создать `Features/TodoistSync/ProjectRequest.swift`:

```swift
import Foundation

/// A project addressed by its Todoist-side names: the area (a root project) and the project
/// inside it. The same pair BigHead keeps in its schema and project pages.
public struct ProjectRequest: Equatable, Sendable {
    public let area: String
    public let project: String

    public init(area: String, project: String) {
        self.area = area
        self.project = project
    }

    public static func decode(_ data: Data) throws -> ProjectRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            throw RequestError.malformedJSON
        }
        func required(_ name: String) throws -> String {
            guard let text = (fields[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw RequestError.missingField(name)
            }
            return text
        }
        return ProjectRequest(area: try required("area"), project: try required("project"))
    }
}
```

- [ ] **Step 6: Новые виды действий журнала**

В `Features/TodoistSync/ActionJournal.swift`, в `enum Action`, после `taskCreated`:

```swift
        public static let taskUpdated = "task.updated"
        public static let taskMoved = "task.moved"
        public static let taskClosed = "task.closed"
        public static let taskDeleted = "task.deleted"
        public static let projectArchived = "project.archived"
        public static let projectUnarchived = "project.unarchived"
```

- [ ] **Step 7: Операции**

В `Features/TodoistSync/TodoistOperations.swift`:

1. Переименовать `public actor TaskCreator` в `public actor TodoistOperations: TodoistOperating` и обновить doc-комментарий: «Every change NoHands makes in Todoist, behind one queue. Finds or creates the area and project by name…».
2. Добавить перед актором:

```swift
public struct UpdateTaskResult: Equatable, Sendable {
    public let projectID: String
    public let moved: Bool
    public let createdProjects: [String]
    public let warning: String?
}

public struct OperationResult: Equatable, Sendable {
    /// Todoist was already in the requested state: the task gone, the project (un)archived.
    public let already: Bool
    public let warning: String?
}

public struct EnsureProjectResult: Equatable, Sendable {
    public let id: String
    public let created: Bool
    public let warning: String?
}

public enum OperationError: Error, Equatable, LocalizedError {
    case taskNotFound(String)
    case projectNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Todoist has no task \(id); it was probably deleted there"
        case .projectNotFound(let name):
            return "Todoist has no project called \"\(name)\" at this level"
        }
    }
}

public protocol TodoistOperating: Sendable {
    func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult
    func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult
    func close(id: String) async throws -> OperationResult
    func delete(id: String) async throws -> OperationResult
    func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult
    func archiveProject(_ request: ProjectRequest) async throws -> OperationResult
    func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult
}
```

3. Заменить метод `create` общей очередью и добавить публичные методы:

```swift
    /// One queue for every operation: actor methods interleave at each `await`, so without it
    /// two requests touching a new area would both see it missing and both create it.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task { () throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    public func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        try await enqueue { try await self.perform(request) }
    }

    public func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        try await enqueue { try await self.performUpdate(id: id, request) }
    }

    public func close(id: String) async throws -> OperationResult {
        try await enqueue { try await self.performGone(id: id, action: ActionJournal.Action.taskClosed) { try await $0.closeTask(id: id) } }
    }

    public func delete(id: String) async throws -> OperationResult {
        try await enqueue { try await self.performGone(id: id, action: ActionJournal.Action.taskDeleted) { try await $0.deleteTask(id: id) } }
    }

    public func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        try await enqueue { try await self.performEnsure(request) }
    }

    public func archiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try await enqueue { try await self.performArchive(request, archive: true) }
    }

    public func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try await enqueue { try await self.performArchive(request, archive: false) }
    }
```

4. Добавить приватные реализации:

```swift
    private func performUpdate(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        let current: TodoistTaskInfo
        do {
            current = try await api.task(id: id)
        } catch TodoistError.notFound {
            throw OperationError.taskNotFound(id)
        }
        var progress = Progress(projects: try await api.projects())
        let area = try await resolve(request.area, parentID: nil, progress: &progress)
        var target = area
        if let name = request.project { target = try await resolve(name, parentID: area.id, progress: &progress) }

        do {
            try await api.updateTask(id: id, TaskUpdate(
                content: request.title, description: request.description, dueDate: request.due
            ))
        } catch TodoistError.notFound {
            throw OperationError.taskNotFound(id)
        }
        await note(ActionJournal.Action.taskUpdated, id: id, name: nil, into: &progress.warnings)

        var moved = false
        if current.projectID != target.id {
            try await api.moveTask(id: id, toProject: target.id)
            moved = true
            await note(ActionJournal.Action.taskMoved, id: id, name: target.name, into: &progress.warnings)
        }
        return UpdateTaskResult(
            projectID: target.id,
            moved: moved,
            createdProjects: progress.created,
            warning: progress.warnings.isEmpty ? nil : progress.warnings.joined(separator: "; ")
        )
    }

    /// Close and delete: the task leaves Todoist. Already gone counts as done, and is not
    /// journaled — NoHands did nothing.
    private func performGone(
        id: String,
        action: String,
        _ call: @Sendable (any TodoistAPI) async throws -> Void
    ) async throws -> OperationResult {
        do {
            try await call(api)
        } catch TodoistError.notFound {
            return OperationResult(already: true, warning: nil)
        }
        var warnings: [String] = []
        await note(action, id: id, name: nil, into: &warnings)
        return OperationResult(already: false, warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    private func performEnsure(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        var progress = Progress(projects: try await api.projects())
        let area = try await resolve(request.area, parentID: nil, progress: &progress)
        let createdBefore = progress.created.count
        let project = try await resolve(request.project, parentID: area.id, progress: &progress)
        return EnsureProjectResult(
            id: project.id,
            created: progress.created.count > createdBefore,
            warning: progress.warnings.isEmpty ? nil : progress.warnings.joined(separator: "; ")
        )
    }

    /// Finds, never creates: archiving something that does not exist is a mistake to name.
    private func performArchive(_ request: ProjectRequest, archive: Bool) async throws -> OperationResult {
        let active = try await api.projects()
        guard let area = try Self.find(request.area, parentID: nil, in: active) else {
            throw OperationError.projectNotFound(request.area)
        }
        let activeProject = try Self.find(request.project, parentID: area.id, in: active)
        var warnings: [String] = []

        if archive {
            guard let project = activeProject else {
                let archived = try await api.archivedProjects()
                if try Self.find(request.project, parentID: area.id, in: archived) != nil {
                    return OperationResult(already: true, warning: nil)
                }
                throw OperationError.projectNotFound(request.project)
            }
            try await api.archiveProject(id: project.id)
            await note(ActionJournal.Action.projectArchived, id: project.id, name: project.name, into: &warnings)
        } else {
            if activeProject != nil { return OperationResult(already: true, warning: nil) }
            let archived = try await api.archivedProjects()
            guard let project = try Self.find(request.project, parentID: area.id, in: archived) else {
                throw OperationError.projectNotFound(request.project)
            }
            try await api.unarchiveProject(id: project.id)
            await note(ActionJournal.Action.projectUnarchived, id: project.id, name: project.name, into: &warnings)
        }
        return OperationResult(already: false, warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }

    private static func find(_ name: String, parentID: String?, in projects: [TodoistProject]) throws -> TodoistProject? {
        let matches = projects.filter { $0.parentID == parentID && same($0.name, name) }
        if matches.count > 1 { throw ResolveError.ambiguousProject(name) }
        return matches.first
    }
```

5. В `resolve` заменить поиск совпадений вызовом `Self.find`:

```swift
        if let found = try Self.find(name, parentID: parentID, in: progress.projects) { return found }
```

Если Swift 6 не пропускает `@Sendable` замыкание `call`, захватывающее `id`, передавать вместо замыкания перечисление `enum GoneKind { case close, delete }` и вызывать `api.closeTask`/`api.deleteTask` по нему. Поведение и тесты не меняются.

- [ ] **Step 8: Тесты зелёные**

Run: `swift test --filter TodoistSyncTests`
Expected: PASS. `overlappingCreateAndUpdateCreateTheAreaOnce` прогнать 5 раз.

Run: `swift test`
Expected: 0 падений.

- [ ] **Step 9: Коммит**

```bash
git add -A Features/TodoistSync Tests/TodoistSyncTests App/AppDelegate.swift
git commit -m "Todoist: TaskCreator стал TodoistOperations — изменение, закрытие, удаление, проекты в одной очереди"
```

---

### Task 3: Маршруты локального HTTP

**Files:**
- Modify: `Features/TodoistSync/TodoistEndpoint.swift` (переписать целиком)
- Modify: `App/AppDelegate.swift` (`TodoistEndpoint(operations: operations)`)
- Test: `Tests/TodoistSyncTests/TodoistEndpointTests.swift` (переписать целиком)

**Interfaces:**
- Consumes: Task 2 (`TodoistOperating`, результаты, `OperationError`, `ProjectRequest`), Task 1 (`TodoistError.notFound`), срез 1 (`CreateTaskRequest`, `RequestError`, `TaskCreateError`, `ResolveError`, `HTTPResponse`).
- Produces: `public struct TodoistEndpoint: Sendable` с `public init(operations: any TodoistOperating)` и прежним `respond(method:path:body:)`.

- [ ] **Step 1: Переписать тесты маршрутизатора**

Заменить содержимое `Tests/TodoistSyncTests/TodoistEndpointTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

/// Records the call and answers with a canned result or error.
private actor FakeOperations: TodoistOperating {
    var calls: [String] = []
    var error: (any Error)?
    var already = false
    var created = true

    init(error: (any Error)? = nil, already: Bool = false, created: Bool = true) {
        self.error = error
        self.already = already
        self.created = created
    }

    private func record(_ call: String) throws {
        calls.append(call)
        if let error { throw error }
    }

    func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        try record("create \(request.title)")
        return CreateTaskResult(id: "6hRv", projectID: "p1", createdProjects: ["Хибины"], warning: nil)
    }

    func update(id: String, _ request: CreateTaskRequest) async throws -> UpdateTaskResult {
        try record("update \(id) \(request.title)")
        return UpdateTaskResult(projectID: "p2", moved: true, createdProjects: [], warning: nil)
    }

    func close(id: String) async throws -> OperationResult {
        try record("close \(id)")
        return OperationResult(already: already, warning: nil)
    }

    func delete(id: String) async throws -> OperationResult {
        try record("delete \(id)")
        return OperationResult(already: already, warning: nil)
    }

    func ensureProject(_ request: ProjectRequest) async throws -> EnsureProjectResult {
        try record("ensure \(request.area)/\(request.project)")
        return EnsureProjectResult(id: "p9", created: created, warning: nil)
    }

    func archiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try record("archive \(request.area)/\(request.project)")
        return OperationResult(already: already, warning: "journal")
    }

    func unarchiveProject(_ request: ProjectRequest) async throws -> OperationResult {
        try record("unarchive \(request.area)/\(request.project)")
        return OperationResult(already: already, warning: nil)
    }
}

private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private let taskBody = Data(#"{"title":"T","area":"Сколково","project":"Хибины"}"#.utf8)
private let projectBody = Data(#"{"area":"RooX","project":"ИНДИД"}"#.utf8)

@Test func healthAnswers200() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations()).respond(method: "GET", path: "/health", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["ok"] as? Bool == true)
}

@Test func aCreatedTaskAnswers201WithItsId() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations()).respond(method: "POST", path: "/tasks", body: taskBody)
    #expect(response.status == 201)
    let json = try object(response)
    #expect(json["id"] as? String == "6hRv")
    #expect(json["created_projects"] as? [String] == ["Хибины"])
}

@Test func anUpdateAnswers200WithItsProjectAndMove() async throws {
    let fake = FakeOperations()
    let response = await TodoistEndpoint(operations: fake).respond(method: "PUT", path: "/tasks/t1", body: taskBody)
    #expect(response.status == 200)
    let json = try object(response)
    #expect(json["project_id"] as? String == "p2")
    #expect(json["moved"] as? Bool == true)
    #expect(await fake.calls == ["update t1 T"])
}

@Test func closeAndDeleteRouteByMethodAndPath() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1/close", body: Data()).status == 200)
    #expect(await endpoint.respond(method: "DELETE", path: "/tasks/t1", body: Data()).status == 200)
    #expect(await fake.calls == ["close t1", "delete t1"])
}

@Test func alreadyGoneIsPassedOn() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(already: true))
        .respond(method: "POST", path: "/tasks/t1/close", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["already"] as? Bool == true)
}

@Test func ensureProjectAnswers201WhenCreatedAnd200WhenFound() async throws {
    let created = await TodoistEndpoint(operations: FakeOperations(created: true))
        .respond(method: "POST", path: "/projects", body: projectBody)
    #expect(created.status == 201)
    #expect(try object(created)["id"] as? String == "p9")
    let found = await TodoistEndpoint(operations: FakeOperations(created: false))
        .respond(method: "POST", path: "/projects", body: projectBody)
    #expect(found.status == 200)
    #expect(try object(found)["created"] as? Bool == false)
}

@Test func archiveAndUnarchiveRoute() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    let archived = await endpoint.respond(method: "POST", path: "/projects/archive", body: projectBody)
    #expect(archived.status == 200)
    #expect(try object(archived)["warning"] as? String == "journal")
    #expect(await endpoint.respond(method: "POST", path: "/projects/unarchive", body: projectBody).status == 200)
    #expect(await fake.calls == ["archive RooX/ИНДИД", "unarchive RooX/ИНДИД"])
}

@Test func aBadBodyIs400AndNeverReachesTodoist() async throws {
    let fake = FakeOperations()
    let endpoint = TodoistEndpoint(operations: fake)
    #expect(await endpoint.respond(method: "POST", path: "/tasks", body: Data(#"{"area":"A"}"#.utf8)).status == 400)
    #expect(await endpoint.respond(method: "PUT", path: "/tasks/t1", body: Data("[]".utf8)).status == 400)
    #expect(await endpoint.respond(method: "POST", path: "/projects", body: Data(#"{"area":"A"}"#.utf8)).status == 400)
    #expect(await fake.calls.isEmpty)
}

// The id goes into a Todoist URL; only plain ASCII letters and digits are let through.
@Test(arguments: ["a%2Fb", "t-1", "..", "ид"])
func aStrangeIdIs400(id: String) async {
    let fake = FakeOperations()
    let response = await TodoistEndpoint(operations: fake).respond(method: "DELETE", path: "/tasks/\(id)", body: Data())
    #expect(response.status == 400)
    #expect(await fake.calls.isEmpty)
}

@Test func errorsMapToStatusCodes() async {
    let cases: [(any Error, Int)] = [
        (RequestError.missingField("x"), 400),
        (OperationError.taskNotFound("t1"), 404),
        (OperationError.projectNotFound("P"), 404),
        (TodoistError.notFound, 404),
        (ResolveError.ambiguousProject("P"), 409),
        (TodoistError.requestFailed(status: 429, message: "slow"), 502),
        (TodoistError.unexpectedResponse("x"), 502),
        (TodoistError.tokenMissing, 503),
        (TodoistError.keychain("denied"), 503),
        (TaskCreateError.outcomeUnknown("x"), 504),
        (URLError(.timedOut), 500),
    ]
    for (error, status) in cases {
        let response = await TodoistEndpoint(operations: FakeOperations(error: error))
            .respond(method: "PUT", path: "/tasks/t1", body: taskBody)
        #expect(response.status == status, "\(error)")
    }
}

@Test func aTodoistFailureCarriesItsStatus() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(error: TodoistError.requestFailed(status: 429, message: "slow")))
        .respond(method: "POST", path: "/tasks/t1/close", body: Data())
    #expect(try object(response)["todoist_status"] as? Int == 429)
}

@Test func anUnknownOutcomeSaysSo() async throws {
    let response = await TodoistEndpoint(operations: FakeOperations(error: TaskCreateError.outcomeUnknown("x")))
        .respond(method: "POST", path: "/tasks", body: taskBody)
    #expect(try object(response)["outcome"] as? String == "unknown")
}

@Test func theWrongMethodIs405() async {
    let endpoint = TodoistEndpoint(operations: FakeOperations())
    #expect(await endpoint.respond(method: "GET", path: "/tasks", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "GET", path: "/tasks/t1/close", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "GET", path: "/projects/archive", body: Data()).status == 405)
    #expect(await endpoint.respond(method: "POST", path: "/health", body: Data()).status == 405)
}

@Test func anUnknownPathIs404() async {
    let endpoint = TodoistEndpoint(operations: FakeOperations())
    #expect(await endpoint.respond(method: "POST", path: "/nope", body: Data()).status == 404)
    #expect(await endpoint.respond(method: "POST", path: "/tasks/t1/reopen", body: Data()).status == 404)
    #expect(await endpoint.respond(method: "POST", path: "/projects/rename", body: Data()).status == 404)
}
```

- [ ] **Step 2: Запустить, убедиться, что падает**

Run: `swift test --filter TodoistEndpointTests`
Expected: FAIL — `TodoistEndpoint(operations:)` не определён.

- [ ] **Step 3: Переписать маршрутизатор**

Заменить содержимое `Features/TodoistSync/TodoistEndpoint.swift`:

```swift
import Foundation

/// Turns one local HTTP request into one answer. Every failure becomes a status code and a
/// sentence the agent can repeat to the owner; nothing falls back silently.
public struct TodoistEndpoint: Sendable {
    private let operations: any TodoistOperating

    public init(operations: any TodoistOperating) {
        self.operations = operations
    }

    enum Route: Equatable {
        case health
        case createTask
        case updateTask(String)
        case closeTask(String)
        case deleteTask(String)
        case ensureProject
        case archiveProject
        case unarchiveProject
    }

    enum Resolution: Equatable {
        case route(Route)
        case methodNotAllowed
        case notFound
    }

    static func resolve(method: String, path: String) -> Resolution {
        let parts = path.split(separator: "/").map(String.init)
        func allow(_ expected: String, _ route: Route) -> Resolution {
            method == expected ? .route(route) : .methodNotAllowed
        }
        switch parts.count {
        case 1 where parts[0] == "health": return allow("GET", .health)
        case 1 where parts[0] == "tasks": return allow("POST", .createTask)
        case 1 where parts[0] == "projects": return allow("POST", .ensureProject)
        case 2 where parts[0] == "tasks":
            switch method {
            case "PUT": return .route(.updateTask(parts[1]))
            case "DELETE": return .route(.deleteTask(parts[1]))
            default: return .methodNotAllowed
            }
        case 2 where parts[0] == "projects" && parts[1] == "archive": return allow("POST", .archiveProject)
        case 2 where parts[0] == "projects" && parts[1] == "unarchive": return allow("POST", .unarchiveProject)
        case 3 where parts[0] == "tasks" && parts[2] == "close": return allow("POST", .closeTask(parts[1]))
        default: return .notFound
        }
    }

    public func respond(method: String, path: String, body: Data) async -> HTTPResponse {
        switch Self.resolve(method: method, path: path) {
        case .notFound:
            return .json(404, ["error": "No such endpoint: \(path)"])
        case .methodNotAllowed:
            return .json(405, ["error": "Method \(method) is not allowed on \(path)"])
        case .route(let route):
            do {
                return try await handle(route, body: body)
            } catch {
                return Self.failure(error)
            }
        }
    }

    private func handle(_ route: Route, body: Data) async throws -> HTTPResponse {
        switch route {
        case .health:
            return .json(200, ["ok": true])

        case .createTask:
            let result = try await operations.create(try CreateTaskRequest.decode(body))
            return .json(201, Self.withWarning([
                "id": result.id,
                "project_id": result.projectID,
                "created_projects": result.createdProjects,
            ], result.warning))

        case .updateTask(let id):
            try Self.check(id)
            let result = try await operations.update(id: id, try CreateTaskRequest.decode(body))
            return .json(200, Self.withWarning([
                "project_id": result.projectID,
                "moved": result.moved,
                "created_projects": result.createdProjects,
            ], result.warning))

        case .closeTask(let id):
            try Self.check(id)
            return Self.gone(try await operations.close(id: id))

        case .deleteTask(let id):
            try Self.check(id)
            return Self.gone(try await operations.delete(id: id))

        case .ensureProject:
            let result = try await operations.ensureProject(try ProjectRequest.decode(body))
            return .json(result.created ? 201 : 200, Self.withWarning([
                "id": result.id,
                "created": result.created,
            ], result.warning))

        case .archiveProject:
            return Self.gone(try await operations.archiveProject(try ProjectRequest.decode(body)))

        case .unarchiveProject:
            return Self.gone(try await operations.unarchiveProject(try ProjectRequest.decode(body)))
        }
    }

    /// The id goes into a Todoist URL path; anything but ASCII letters and digits is refused.
    private static func check(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw InvalidID()
        }
    }

    private struct InvalidID: Error, LocalizedError {
        var errorDescription: String? { "Task id must be ASCII letters and digits only" }
    }

    private static func gone(_ result: OperationResult) -> HTTPResponse {
        .json(200, withWarning(["already": result.already], result.warning))
    }

    private static func withWarning(_ answer: [String: Any], _ warning: String?) -> [String: Any] {
        var answer = answer
        if let warning { answer["warning"] = warning }
        return answer
    }

    static func failure(_ error: any Error) -> HTTPResponse {
        switch error {
        case let error as RequestError:
            return .json(400, ["error": error.localizedDescription])
        case let error as InvalidID:
            return .json(400, ["error": error.localizedDescription])
        case let error as TodoistError:
            switch error {
            case .tokenMissing, .keychain:
                return .json(503, ["error": error.localizedDescription])
            case .notFound:
                return .json(404, ["error": error.localizedDescription])
            case .requestFailed(let status, _):
                return .json(502, ["error": error.localizedDescription, "todoist_status": status])
            case .unexpectedResponse:
                return .json(502, ["error": error.localizedDescription])
            }
        case let error as OperationError:
            return .json(404, ["error": error.localizedDescription])
        case let error as TaskCreateError:
            return .json(504, ["error": error.localizedDescription, "outcome": "unknown"])
        case let error as ResolveError:
            return .json(409, ["error": error.localizedDescription])
        default:
            return .json(500, ["error": error.localizedDescription])
        }
    }
}
```

- [ ] **Step 4: `AppDelegate`**

В `startTodoistSync()` заменить строку создания `endpoint` на:

```swift
        let endpoint = TodoistEndpoint(operations: operations)
```

- [ ] **Step 5: Тесты зелёные**

Run: `swift test --filter TodoistSyncTests`
Expected: PASS.

Run: `swift build && swift test`
Expected: сборка без новых предупреждений, 0 падений.

- [ ] **Step 6: Коммит**

```bash
git add Features/TodoistSync Tests/TodoistSyncTests App/AppDelegate.swift
git commit -m "Todoist: маршруты изменения, закрытия, удаления задач и проектов в локальном HTTP"
```

---

### Task 4: Установка и живая проверка — с разрешения владельца

**Files:** нет.

- [ ] **Step 1: Разрешение владельца** на установку (`make-app.sh` перезапускает NoHands; запись созвона в этот момент прервётся) и на тестовые задачи и проект в Todoist.

- [ ] **Step 2: Установка**

Run: `./Scripts/make-app.sh` (если в конце `_LSOpenURLsWithCompletionHandler() failed with error -600`, запустить `open -a /Applications/NoHands.app`)
Run: `curl -sS http://127.0.0.1:41730/health`
Expected: `{"ok":true}`

- [ ] **Step 3: Задачи на живом Todoist**

```bash
B=http://127.0.0.1:41730; H='Content-Type: application/json'
ID=$(curl -sS -X POST $B/tasks -H "$H" -H 'Expect:' -d '{"title":"Срез 2: проверка — удалить","area":"Сколково","due":"2026-10-20"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
curl -sS -X PUT $B/tasks/$ID -H "$H" -d '{"title":"Срез 2: переименована — удалить","area":"Сколково","project":"Переход Хибин на модель одного админа"}'
curl -sS -X POST $B/tasks/$ID/close
curl -sS -X POST $B/tasks/$ID/close
```

Expected:
- `PUT` → `{"moved":true,…}`; в Todoist задача переименована, перенесена в подпроект, срока нет.
- первое закрытие → `{"already":false}`; второе → `200`.
- Записать фактический ответ второго закрытия и ответ `DELETE` на уже закрытую задачу. Если Todoist отвечает не `404`/`204` (например `400` на чужой `id`), зафиксировать в `docs/DECISIONS.md` и решить, считать ли это `already`.

Вторая задача: создать, `curl -sS -X DELETE $B/tasks/$ID2` → `{"already":false}`, повторить → `{"already":true}`.

- [ ] **Step 4: Проект на живом Todoist**

```bash
curl -sS -X POST $B/projects -H "$H" -d '{"area":"Сколково","project":"Срез 2 проверка"}'
curl -sS -X POST $B/projects/archive -H "$H" -d '{"area":"Сколково","project":"Срез 2 проверка"}'
curl -sS -X POST $B/projects/archive -H "$H" -d '{"area":"Сколково","project":"Срез 2 проверка"}'
curl -sS -X POST $B/projects/unarchive -H "$H" -d '{"area":"Сколково","project":"Срез 2 проверка"}'
```

Expected: `201` `{"created":true}`; `{"already":false}`; `{"already":true}`; `{"already":false}`. Тестовый проект владелец удаляет руками.

- [ ] **Step 5: Журнал**

Run: `tail -12 ~/Library/Application\ Support/NoHands/todoist-actions.jsonl`
Expected: `task.created`, `task.updated`, `task.moved`, `task.closed`, `task.deleted`, `project.created`, `project.archived`, `project.unarchived` с правильными `id`.

---

### Task 5: Правила в Башке

**Files:**
- Modify: `/Users/macintosh/BigHead/AGENTS.md` (раздел «Задачи → Todoist»)
- Modify: `/Users/macintosh/BigHead/wiki/log.md` (запись `schema`)

- [ ] **Step 1: Переписать раздел «Todoist» в `AGENTS.md`**

Заменить всё от строки `### Todoist` до строки перед `## Операции` на:

```
### Todoist

Задачи board синхронизируются с Todoist через NoHands — приложение на этой машине, адрес `http://127.0.0.1:41730`. Задача в Todoist — та же задача, не копия: создание задачи в Todoist самим Арсланом равно его «ок».

Операция определяется репликой Арслана:

| Реплика | Операция | Запрос |
|---|---|---|
| новая задача (после «ок») | создание | `POST /tasks` |
| правка задачи с `todoist:` — текст, описание, срок, перенос в другой проект | изменение | `PUT /tasks/<id>` |
| «сделал» | закрытие | `POST /tasks/<id>/close` |
| «не будем», «передумал» | удаление | `DELETE /tasks/<id>` |

Запрос:

    curl -sS -m 120 -X <метод> http://127.0.0.1:41730/<путь> \
      -H 'Content-Type: application/json' -H 'Expect:' \
      -d '{"title":"…","description":"…","due":"ГГГГ-ММ-ДД","area":"<область в Todoist>","project":"<todoist: проекта>"}'

- Тело у `POST /tasks` и `PUT /tasks/<id>` одинаковое и описывает задачу целиком, как она теперь стоит в board. `area` — из таблицы областей; `project` — поле `todoist:` страницы проекта, для задачи из «Общее» не передаётся. `description` — строка под задачей без `[[ ]]`; нет строки — поле не передаётся, и описание в Todoist очистится. `due` — только если срок назван; нет срока — поле не передаётся, и срок в Todoist снимется.
- У закрытия и удаления тела нет.

Ответы и что делать:

- Создание, `201` с `id` → в строку после даты добавления: `· todoist:<id>`. `id` — только из ответа.
- Изменение, `200` → готово.
- Закрытие или удаление, `200` (в том числе `"already": true`) → строка уходит из board, запись `task` в log: «закрыта» или «удалена».
- В ответе есть `warning` → операция выполнена, предупреждение — Арслану в чат.
- `404` на изменение → задачи нет в Todoist (удалена там): строку не трогать, сказать Арслану.
- `400`, `409` → не повторять, текст ошибки — Арслану.
- Любой другой сбой изменения, закрытия, удаления (нет ответа, `5xx`, таймаут) → пометка в строке: `· todoist-pending:update`, `:close` или `:delete`. Закрытая или удалённая задача остаётся в board с пометкой, пока Todoist не подтвердит.
- Сбой создания: `curl` не подключился (код 7) или `503` → `· todoist-pending:create`. `504`, `502`, таймаут или обрыв после подключения (коды 28, 52, 56) → `· todoist-check`: задача могла создаться, без повтора, Арслану в чат — проверить Todoist.

Повтор помеченного — при любом контакте: сообщение Арслана в чат, ingest, просьба. Перед работой найти все `todoist-pending:` в board и отправить их тем же запросом по текущему состоянию строки; успех снимает пометку и выполняет то, что положено по ответу. `todoist-check` не повторяется сам: только после ответа Арслана — «есть в Todoist» (дописать `todoist:<id>`, если Арслан его даст, иначе снять пометку) или «нет» (заменить на `todoist-pending:create`).

Проекты:

- Страница проекта заводится со `state: active` → `POST /projects` с `{"area":"<область в Todoist>","project":"<todoist:>"}`. `201` или `200` → готово.
- `state` меняется на `paused` или `done` → `POST /projects/archive` с тем же телом; обратно на `active` → `POST /projects/unarchive`.
- Сбой → во frontmatter страницы `todoist_pending: create | archive | unarchive`, повтор при любом контакте тем же порядком; успех удаляет поле.
- Страница, заведённая сразу как `paused` или `done` (исторический проект, кейс), в Todoist не отправляется.
- Переименование проекта или области в Todoist не отправляется.

Задачи Бэклога в Todoist не отправляются.
```

- [ ] **Step 2: Запись в журнал Башки**

В конец `/Users/macintosh/BigHead/wiki/log.md`:

```
## [<дата>] schema | Синхронизация с Todoist, второй срез: изменение, закрытие, удаление, проекты, пометки
- AGENTS.md: раздел «Todoist» переписан — реплика → операция, запросы PUT/close/DELETE, пометки `todoist-pending:*` и `todoist-check` с повтором при любом контакте, проекты: создание при заведении страницы, архив при paused/done
```

- [ ] **Step 3: Проверка**

Run: `grep -n "todoist-pending\|PUT /tasks\|projects/archive" /Users/macintosh/BigHead/AGENTS.md`
Expected: все три встречаются в разделе «Todoist».
