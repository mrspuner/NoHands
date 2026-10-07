# Синхронизация с Todoist — первый срез. План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Агент Башки одним запросом `curl` на `127.0.0.1` создаёт задачу в Todoist в нужной области и проекте (недостающие создаются сами) и получает обратно её `id`; каждое действие NoHands в Todoist записывается в журнал.

**Architecture:** Новый таргет `TodoistSync` (`Features/TodoistSync`) поверх `Core`. Внутри четыре слоя, каждый тестируется отдельно: разбор запроса агента (`CreateTaskRequest`), клиент Todoist API v1 за протоколом `TodoistAPI` (`TodoistClient`), логика «найти или создать область и проект, создать задачу, записать в журнал» (`TaskCreator` + `ActionJournal`) и локальный HTTP (`HTTPRequestParser`, `HTTPResponse`, `TodoistEndpoint`, `LocalHTTPServer` на Network.framework). `AppDelegate` поднимает сервер один раз при запуске. Башка получает правила вызова в своей схеме.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 15, Foundation, Network.framework, swift-testing (`@Test`/`#expect`). Новых внешних зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-10-07-todoist-sync-design.md`

## Global Constraints

- Новых зависимостей SPM не добавляем. HTTP-сервер — на `Network.framework`, клиент — на `URLSession`.
- Идентификаторы, комментарии в коде и сообщения об ошибках — по-английски. Строки статуса в меню и документация — по-русски.
- **Коммитов нет.** Владелец запретил коммитить. Шаги «Commit» из шаблона заменены проверкой `swift test`.
- Токен Todoist только в Keychain: сервис `nohands-todoist`, аккаунт `api-token`. Токен нигде не печатается, не логируется и не попадает в тело ответа или ошибки.
- Ни один тест не ходит в настоящий Todoist и не читает настоящий Keychain. Ни один тест не пишет в настоящий `~/Library/Application Support/NoHands/`.
- Эндпоинт Todoist — `https://api.todoist.com/api/v1/`, не `/rest/v2/`. Срок передаётся полем `due_date` (`ГГГГ-ММ-ДД`), никогда `due_string`.
- Списки Todoist v1 пагинированы: ответ `{"results": [...], "next_cursor": "…"|null}`. Проверено живым запросом 2026-10-07.
- `id` задач и проектов — непрозрачные строки, не числа.
- Сервер слушает только loopback, порт `41730`.
- Базовая линия перед началом: **728 тестов, 0 падений** (`swift test`). Первый холодный прогон после `swift package clean` может уронить 2–3 тайминговых теста Inbox, повторный проходит; это не регрессия.
- Платформа пакета — `.macOS(.v15)`, менять её нельзя.

## Review Focus

1. **Одинаковое имя в разном регистре или с пробелами по краям** («хибины » против «Хибины»). Ожидается: найден существующий проект, второй не создан. Тест в Task 4.
2. **Два запроса одновременно с новой областью.** Ожидается: создана ровно одна область, обе задачи в ней. Тест в Task 4.
3. **Журнал не записался** (диск, права). Задача в Todoist уже создана, поэтому повтор агентом дал бы дубль. Ожидается: ответ `201` с `id` и полем `warning`, а не ошибка. Тест в Task 4.
4. **Неправильная дата** (`2026-02-30`, `10.10.2026`, «завтра»). Ожидается: `400` с названием поля, в Todoist ничего не уходит. Тест в Task 1.
5. **Тело больше лимита или запрос, оборванный на середине.** Ожидается: `413`, а оборванный — без ответа и без падения приложения. Тесты в Task 5 и Task 6.

---

### Task 1: Таргет `TodoistSync` и разбор запроса агента

**Files:**
- Modify: `Package.swift` (библиотека, таргет, тест-таргет; `App` зависит от `TodoistSync`)
- Create: `Features/TodoistSync/CreateTaskRequest.swift`
- Test: `Tests/TodoistSyncTests/CreateTaskRequestTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public struct CreateTaskRequest: Equatable, Sendable { title: String; description: String?; due: String?; area: String; project: String? }`
  - `public static func decode(_ data: Data) throws -> CreateTaskRequest`
  - `public enum RequestError: Error, Equatable, LocalizedError { case malformedJSON; case missingField(String); case invalidDue(String) }`

- [ ] **Step 1: Добавить таргеты в `Package.swift`**

В `products` после строки с `Meetings`:

```swift
        .library(name: "TodoistSync", targets: ["TodoistSync"]),
```

В `targets` после таргета `Meetings`:

```swift
        .target(
            name: "TodoistSync",
            dependencies: ["Core"],
            path: "Features/TodoistSync"
        ),
```

У `App` заменить зависимости на:

```swift
            dependencies: ["Core", "Dictation", "Inbox", "Meetings", "TodoistSync"],
```

В конец `targets`:

```swift
        .testTarget(
            name: "TodoistSyncTests",
            dependencies: ["TodoistSync"],
            path: "Tests/TodoistSyncTests"
        ),
```

- [ ] **Step 2: Написать падающий тест**

Создать `Tests/TodoistSyncTests/CreateTaskRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

private func decode(_ json: String) throws -> CreateTaskRequest {
    try CreateTaskRequest.decode(Data(json.utf8))
}

@Test func aFullRequestIsDecoded() throws {
    let request = try decode("""
    {"title":"Собрать правки","description":"п. 9–14","due":"2026-10-10","area":"Сколково","project":"Хибины"}
    """)
    #expect(request == CreateTaskRequest(
        title: "Собрать правки", description: "п. 9–14", due: "2026-10-10",
        area: "Сколково", project: "Хибины"
    ))
}

// A task from the area's «Общее» section has no project, and most tasks have no due date.
@Test func optionalFieldsMayBeAbsent() throws {
    let request = try decode(#"{"title":"Ликбез по git","area":"Сколково"}"#)
    #expect(request.description == nil)
    #expect(request.due == nil)
    #expect(request.project == nil)
}

// The agent assembles this JSON by hand; an empty string is how "no value" most often arrives.
@Test func emptyOptionalStringsBecomeNil() throws {
    let request = try decode(#"{"title":"T","area":"A","description":"  ","due":"","project":""}"#)
    #expect(request.description == nil)
    #expect(request.due == nil)
    #expect(request.project == nil)
}

@Test func surroundingWhitespaceIsTrimmed() throws {
    let request = try decode(#"{"title":"  T  ","area":" Сколково ","project":" Хибины "}"#)
    #expect(request.title == "T")
    #expect(request.area == "Сколково")
    #expect(request.project == "Хибины")
}

@Test func aMissingTitleIsNamed() {
    #expect(throws: RequestError.missingField("title")) { try decode(#"{"area":"A"}"#) }
}

@Test func aBlankAreaIsNamed() {
    #expect(throws: RequestError.missingField("area")) { try decode(#"{"title":"T","area":"   "}"#) }
}

@Test func aNonStringFieldCountsAsMissing() {
    #expect(throws: RequestError.missingField("title")) { try decode(#"{"title":42,"area":"A"}"#) }
}

@Test func notJSONIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try decode("title=T") }
}

@Test func aJSONArrayIsMalformed() {
    #expect(throws: RequestError.malformedJSON) { try decode(#"["T"]"#) }
}

// Todoist parses `due_string` by language and silently lands on the wrong day for Russian
// phrases; only a calendar date is ever passed on, and only a real one.
@Test(arguments: ["10.10.2026", "завтра", "2026-10-1", "2026-02-30", "2026-13-01"])
func anInvalidDueIsRefused(due: String) {
    #expect(throws: RequestError.invalidDue(due)) {
        try decode(#"{"title":"T","area":"A","due":"\#(due)"}"#)
    }
}

@Test func aLeapDayIsAValidDue() throws {
    #expect(try decode(#"{"title":"T","area":"A","due":"2028-02-29"}"#).due == "2028-02-29")
}
```

- [ ] **Step 3: Запустить тест, убедиться, что падает**

Run: `swift test --filter TodoistSyncTests`
Expected: FAIL — не компилируется, `CreateTaskRequest` не определён.

- [ ] **Step 4: Написать реализацию**

Создать `Features/TodoistSync/CreateTaskRequest.swift`:

```swift
import Foundation

/// What the BigHead agent sends to create one task. Names, not ids: `area` and `project` are the
/// Todoist-side names from the pair BigHead keeps, and resolving them is `TaskCreator`'s job.
public struct CreateTaskRequest: Equatable, Sendable {
    public let title: String
    public let description: String?
    /// A calendar date, `YYYY-MM-DD`, already checked to exist.
    public let due: String?
    public let area: String
    /// Absent for a task from an area's «Общее» section: it goes into the area project itself.
    public let project: String?

    public init(title: String, description: String?, due: String?, area: String, project: String?) {
        self.title = title
        self.description = description
        self.due = due
        self.area = area
        self.project = project
    }

    public static func decode(_ data: Data) throws -> CreateTaskRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            throw RequestError.malformedJSON
        }
        let due = optional(fields["due"])
        if let due, !isCalendarDate(due) {
            throw RequestError.invalidDue(due)
        }
        return CreateTaskRequest(
            title: try required(fields["title"], name: "title"),
            description: optional(fields["description"]),
            due: due,
            area: try required(fields["area"], name: "area"),
            project: optional(fields["project"])
        )
    }

    private static func optional(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func required(_ value: Any?, name: String) throws -> String {
        guard let text = optional(value) else { throw RequestError.missingField(name) }
        return text
    }

    /// Shape first, then a round trip through a strict formatter: `2026-02-30` has the right
    /// shape and no such day.
    private static func isCalendarDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }
}

public enum RequestError: Error, Equatable, LocalizedError {
    case malformedJSON
    case missingField(String)
    case invalidDue(String)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Request body is not a JSON object"
        case .missingField(let name):
            return "Required field \"\(name)\" is missing or empty"
        case .invalidDue(let value):
            return "Field \"due\" must be a real date as YYYY-MM-DD, got \"\(value)\""
        }
    }
}
```

- [ ] **Step 5: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter TodoistSyncTests`
Expected: PASS, все тесты файла.

- [ ] **Step 6: Полный прогон**

Run: `swift test`
Expected: 728 + новые, 0 падений.

---

### Task 2: Клиент Todoist API

**Files:**
- Modify: `Core/Secrets/Keychain.swift` (две константы)
- Create: `Features/TodoistSync/TodoistAPI.swift`
- Create: `Features/TodoistSync/TodoistClient.swift`
- Test: `Tests/TodoistSyncTests/TodoistClientTests.swift`

**Interfaces:**
- Consumes: `Keychain.password(service:account:)` из `Core`.
- Produces:
  - `Keychain.todoistService = "nohands-todoist"`, `Keychain.todoistAccount = "api-token"`
  - `public struct TodoistProject: Equatable, Sendable, Decodable { id: String; name: String; parentID: String? }`
  - `public struct NewTodoistTask: Equatable, Sendable { content: String; description: String?; dueDate: String?; projectID: String }`
  - `public protocol TodoistAPI: Sendable { func projects() async throws -> [TodoistProject]; func createProject(name: String, parentID: String?) async throws -> TodoistProject; func createTask(_ task: NewTodoistTask) async throws -> String }`
  - `public enum TodoistError: Error, Equatable, LocalizedError { case tokenMissing; case keychain(String); case requestFailed(status: Int, message: String); case unexpectedResponse(String) }`
  - `public actor TodoistClient: TodoistAPI` с `public init()`, `init(lookup:transport:)`, `public func warmUp()`

- [ ] **Step 1: Константы Keychain**

В `Core/Secrets/Keychain.swift` после `deepSeekAccount`:

```swift
    public static let todoistService = "nohands-todoist"
    public static let todoistAccount = "api-token"
```

- [ ] **Step 2: Написать падающий тест**

Создать `Tests/TodoistSyncTests/TodoistClientTests.swift`:

```swift
import Foundation
import os
import Testing
@testable import TodoistSync

/// Records every request and answers from a queue, so no test ever reaches api.todoist.com.
private final class FakeTransport: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (requests: [URLRequest](), answers: [(Int, String)]()))

    init(_ answers: [(Int, String)]) {
        lock.withLock { $0.answers = answers }
    }

    var requests: [URLRequest] { lock.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (status, body) = lock.withLock { state -> (Int, String) in
            state.requests.append(request)
            return state.answers.isEmpty ? (500, "no answer queued") : state.answers.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private func client(_ transport: FakeTransport, token: String? = "secret") -> TodoistClient {
    TodoistClient(lookup: { token }, transport: { try await transport.send($0) })
}

private func json(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
}

@Test func projectsFollowTheCursorUntilItRunsOut() async throws {
    let transport = FakeTransport([
        (200, #"{"results":[{"id":"a","name":"Сколково","parent_id":null}],"next_cursor":"c1"}"#),
        (200, #"{"results":[{"id":"b","name":"Хибины","parent_id":"a"}],"next_cursor":null}"#),
    ])
    let projects = try await client(transport).projects()

    #expect(projects == [
        TodoistProject(id: "a", name: "Сколково", parentID: nil),
        TodoistProject(id: "b", name: "Хибины", parentID: "a"),
    ])
    let urls = transport.requests.map { $0.url!.absoluteString }
    #expect(urls[0] == "https://api.todoist.com/api/v1/projects?limit=200")
    #expect(urls[1] == "https://api.todoist.com/api/v1/projects?limit=200&cursor=c1")
}

@Test func everyRequestCarriesTheBearerToken() async throws {
    let transport = FakeTransport([(200, #"{"results":[],"next_cursor":null}"#)])
    _ = try await client(transport).projects()
    #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
}

@Test func createProjectSendsNameAndParent() async throws {
    let transport = FakeTransport([(200, #"{"id":"p1","name":"Хибины","parent_id":"a"}"#)])
    let project = try await client(transport).createProject(name: "Хибины", parentID: "a")

    #expect(project == TodoistProject(id: "p1", name: "Хибины", parentID: "a"))
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/projects")
    let body = try json(request)
    #expect(body["name"] as? String == "Хибины")
    #expect(body["parent_id"] as? String == "a")
}

@Test func aRootProjectIsSentWithoutAParent() async throws {
    let transport = FakeTransport([(200, #"{"id":"a","name":"Сколково","parent_id":null}"#)])
    _ = try await client(transport).createProject(name: "Сколково", parentID: nil)
    #expect(try json(transport.requests[0])["parent_id"] == nil)
}

// `due_date`, never `due_string`: the string is parsed by language and silently lands on the
// wrong day for a Russian phrase.
@Test func createTaskSendsDueDateAndReturnsTheId() async throws {
    let transport = FakeTransport([(200, #"{"id":"6hRvqqQ89g3prC7Q","content":"T"}"#)])
    let id = try await client(transport).createTask(
        NewTodoistTask(content: "T", description: "D", dueDate: "2026-10-10", projectID: "p1")
    )

    #expect(id == "6hRvqqQ89g3prC7Q")
    let request = transport.requests[0]
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/tasks")
    let body = try json(request)
    #expect(body["content"] as? String == "T")
    #expect(body["description"] as? String == "D")
    #expect(body["due_date"] as? String == "2026-10-10")
    #expect(body["project_id"] as? String == "p1")
    #expect(body["due_string"] == nil)
}

@Test func absentOptionalTaskFieldsAreNotSent() async throws {
    let transport = FakeTransport([(200, #"{"id":"t1"}"#)])
    _ = try await client(transport).createTask(
        NewTodoistTask(content: "T", description: nil, dueDate: nil, projectID: "p1")
    )
    let body = try json(transport.requests[0])
    #expect(body["description"] == nil)
    #expect(body["due_date"] == nil)
}

// A response without an id means no task was created. Inventing one would confirm a task
// that does not exist — the same rule `inbox-review` follows for `card.md`.
@Test func aTaskResponseWithoutAnIdIsAnError() async {
    let transport = FakeTransport([(200, #"{"content":"T"}"#)])
    await #expect(throws: TodoistError.self) {
        _ = try await client(transport).createTask(
            NewTodoistTask(content: "T", description: nil, dueDate: nil, projectID: "p1")
        )
    }
}

@Test func aTodoistErrorKeepsItsStatusAndBody() async {
    let transport = FakeTransport([(403, "Forbidden")])
    await #expect(throws: TodoistError.requestFailed(status: 403, message: "Forbidden")) {
        _ = try await client(transport).projects()
    }
}

@Test func aLongErrorBodyIsCut() async throws {
    let transport = FakeTransport([(500, String(repeating: "x", count: 2000))])
    do {
        _ = try await client(transport).projects()
        Issue.record("expected a failure")
    } catch let TodoistError.requestFailed(_, message) {
        #expect(message.count == 501)
        #expect(message.hasSuffix("…"))
    }
}

@Test func aMissingTokenIsNamedAndNothingIsSent() async {
    let transport = FakeTransport([])
    await #expect(throws: TodoistError.tokenMissing) {
        _ = try await client(transport, token: nil).projects()
    }
    #expect(transport.requests.isEmpty)
}

// The first read of a Keychain item placed from Terminal raises an authorization dialog; doing
// that on every request would put a dialog in front of every task the agent creates.
@Test func theTokenIsReadOnce() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let transport = FakeTransport([
        (200, #"{"results":[],"next_cursor":null}"#),
        (200, #"{"results":[],"next_cursor":null}"#),
    ])
    let client = TodoistClient(
        lookup: { reads.withLock { $0 += 1 }; return "secret" },
        transport: { try await transport.send($0) }
    )
    _ = try await client.projects()
    _ = try await client.projects()
    #expect(reads.withLock { $0 } == 1)
}

@Test func warmingUpSwallowsAMissingToken() async {
    let client = TodoistClient(lookup: { nil }, transport: { _ in throw URLError(.badURL) })
    await client.warmUp()
}
```

- [ ] **Step 3: Запустить тест, убедиться, что падает**

Run: `swift test --filter TodoistClientTests`
Expected: FAIL — `TodoistClient` не определён.

- [ ] **Step 4: Написать протокол и типы**

Создать `Features/TodoistSync/TodoistAPI.swift`:

```swift
import Foundation

public struct TodoistProject: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let parentID: String?

    public init(id: String, name: String, parentID: String?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parent_id"
    }
}

public struct NewTodoistTask: Equatable, Sendable {
    public let content: String
    public let description: String?
    /// `YYYY-MM-DD`, sent as `due_date`.
    public let dueDate: String?
    public let projectID: String

    public init(content: String, description: String?, dueDate: String?, projectID: String) {
        self.content = content
        self.description = description
        self.dueDate = dueDate
        self.projectID = projectID
    }
}

/// The three calls the first slice needs. A protocol so `TaskCreator` can be tested against a
/// fake account instead of the owner's real one.
public protocol TodoistAPI: Sendable {
    func projects() async throws -> [TodoistProject]
    func createProject(name: String, parentID: String?) async throws -> TodoistProject
    /// - Returns: the id of the created task, taken from the response and only from it.
    func createTask(_ task: NewTodoistTask) async throws -> String
}

public enum TodoistError: Error, Equatable, LocalizedError {
    case tokenMissing
    /// The Keychain refused the query; the text is `KeychainError`'s description.
    case keychain(String)
    case requestFailed(status: Int, message: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Todoist token is missing from the Keychain (service nohands-todoist, account api-token)"
        case .keychain(let message):
            return message
        case .requestFailed(let status, let message):
            return "Todoist answered \(status): \(message)"
        case .unexpectedResponse(let detail):
            return "Todoist response could not be read: \(detail)"
        }
    }
}
```

- [ ] **Step 5: Написать клиент**

Создать `Features/TodoistSync/TodoistClient.swift`:

```swift
import Core
import Foundation

/// Talks to Todoist API v1. The only place in this application that holds the Todoist token.
public actor TodoistClient: TodoistAPI {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let base = URL(string: "https://api.todoist.com/api/v1/")!
    /// Error bodies are passed on to the agent and from there to the owner's chat; several KB of
    /// HTML from a proxy would bury the one line worth reading.
    private static let messageLimit = 500
    private static let timeout: TimeInterval = 20

    private let lookup: @Sendable () throws -> String?
    private let transport: Transport
    private var cachedToken: String?

    public init() {
        self.init(
            lookup: {
                try Keychain.password(service: Keychain.todoistService, account: Keychain.todoistAccount)
            },
            transport: { try await URLSession.shared.data(for: $0) }
        )
    }

    init(lookup: @escaping @Sendable () throws -> String?, transport: @escaping Transport) {
        self.lookup = lookup
        self.transport = transport
    }

    /// Reads the token at launch, so the Keychain authorization dialog appears while the owner is
    /// at the machine rather than in the middle of an agent's request. Never throws: a missing
    /// token is a request-time failure with its own status code.
    public func warmUp() {
        _ = try? resolvedToken()
    }

    public func projects() async throws -> [TodoistProject] {
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
            var components = URLComponents(url: Self.base.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let data = try await send(method: "GET", url: components.url!, body: nil)
            let page = try Self.decode(Page.self, from: data)
            all += page.results
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func createProject(name: String, parentID: String?) async throws -> TodoistProject {
        var body: [String: Any] = ["name": name]
        if let parentID { body["parent_id"] = parentID }
        let data = try await send(method: "POST", url: Self.base.appendingPathComponent("projects"), body: body)
        return try Self.decode(TodoistProject.self, from: data)
    }

    public func createTask(_ task: NewTodoistTask) async throws -> String {
        var body: [String: Any] = ["content": task.content, "project_id": task.projectID]
        if let description = task.description { body["description"] = description }
        if let dueDate = task.dueDate { body["due_date"] = dueDate }
        let data = try await send(method: "POST", url: Self.base.appendingPathComponent("tasks"), body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            throw TodoistError.unexpectedResponse("task response has no id")
        }
        return id
    }

    private func send(method: String, url: URL, body: [String: Any]?) async throws -> Data {
        let token = try resolvedToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw TodoistError.unexpectedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "no body"
            throw TodoistError.requestFailed(status: http.statusCode, message: Self.cut(message))
        }
        return data
    }

    /// Only success is cached: a token added while the app runs starts working without a restart.
    func resolvedToken() throws -> String {
        if let cachedToken { return cachedToken }
        let found: String?
        do {
            found = try lookup()
        } catch {
            throw TodoistError.keychain(error.localizedDescription)
        }
        guard let found, !found.isEmpty else { throw TodoistError.tokenMissing }
        cachedToken = found
        return found
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TodoistError.unexpectedResponse(String(describing: error))
        }
    }

    static func cut(_ text: String) -> String {
        text.count > messageLimit ? String(text.prefix(messageLimit)) + "…" : text
    }
}
```

- [ ] **Step 6: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter TodoistClientTests`
Expected: PASS.

- [ ] **Step 7: Полный прогон**

Run: `swift test`
Expected: 0 падений.

---

### Task 3: Журнал собственных действий

**Files:**
- Create: `Features/TodoistSync/ActionJournal.swift`
- Test: `Tests/TodoistSyncTests/ActionJournalTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public actor ActionJournal` с `public init(url: URL, now: @escaping @Sendable () -> Date = Date.init)`, `public static var defaultURL: URL`, `public func record(action: String, todoistID: String, name: String?) throws`, `public func entries() throws -> [ActionJournal.Entry]`
  - `public struct Entry: Codable, Equatable, Sendable { time: String; action: String; todoistID: String; name: String? }`
  - `public enum Action { public static let projectCreated = "project.created"; public static let taskCreated = "task.created" }` — вложен в `ActionJournal`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/TodoistSyncTests/ActionJournalTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-\(UUID().uuidString)")
        .appendingPathComponent("todoist-actions.jsonl")
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_791_400_000) }

@Test func aRecordIsReadBack() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)

    let entries = try await journal.entries()
    #expect(entries == [ActionJournal.Entry(
        time: "2026-10-07T19:06:40Z", action: "task.created", todoistID: "t1", name: nil
    )])
}

// The second slice reads this file to recognise its own changes among those the poll returns;
// a record that replaced the previous one would make every earlier action look like the owner's.
@Test func recordsAreAppendedInOrder() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    try await journal.record(action: ActionJournal.Action.projectCreated, todoistID: "p1", name: "Хибины")
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)

    let entries = try await journal.entries()
    #expect(entries.map(\.todoistID) == ["p1", "t1"])
    #expect(entries[0].name == "Хибины")
}

@Test func theFileIsOneJSONObjectPerLine() async throws {
    let url = temporaryJournalURL()
    let journal = ActionJournal(url: url, now: fixedNow)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)
    try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t2", name: nil)

    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains(#""todoist_id":"t1""#))
}

@Test func aJournalThatWasNeverWrittenIsEmpty() async throws {
    let journal = ActionJournal(url: temporaryJournalURL(), now: fixedNow)
    #expect(try await journal.entries().isEmpty)
}

@Test func anUnwritableLocationThrows() async {
    let journal = ActionJournal(url: URL(fileURLWithPath: "/dev/null/journal.jsonl"), now: fixedNow)
    await #expect(throws: (any Error).self) {
        try await journal.record(action: ActionJournal.Action.taskCreated, todoistID: "t1", name: nil)
    }
}

@Test func theDefaultLocationIsOutsideTheRepository() {
    #expect(ActionJournal.defaultURL.path.hasSuffix("Library/Application Support/NoHands/todoist-actions.jsonl"))
}
```

- [ ] **Step 2: Запустить тест, убедиться, что падает**

Run: `swift test --filter ActionJournalTests`
Expected: FAIL — `ActionJournal` не определён.

- [ ] **Step 3: Написать реализацию**

Создать `Features/TodoistSync/ActionJournal.swift`:

```swift
import Foundation

/// Every change NoHands itself makes in Todoist, one JSON object per line.
///
/// Written now, read by the second slice: the poll returns the owner's changes and NoHands's own
/// alike, and only this file can tell them apart. Lives outside the repository, like the meeting
/// archive and the voice book.
public actor ActionJournal {
    public enum Action {
        public static let projectCreated = "project.created"
        public static let taskCreated = "task.created"
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let time: String
        public let action: String
        public let todoistID: String
        public let name: String?

        public init(time: String, action: String, todoistID: String, name: String?) {
            self.time = time
            self.action = action
            self.todoistID = todoistID
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case time, action, name
            case todoistID = "todoist_id"
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/todoist-actions.jsonl")
    }

    private let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    public func record(action: String, todoistID: String, name: String?) throws {
        let entry = Entry(
            time: ISO8601DateFormatter().string(from: now()),
            action: action,
            todoistID: todoistID,
            name: name
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
```

- [ ] **Step 4: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter ActionJournalTests`
Expected: PASS. Ожидаемая строка `2026-10-07T19:06:40Z` проверена от `1_791_400_000`.

- [ ] **Step 5: Полный прогон**

Run: `swift test`
Expected: 0 падений.

---

### Task 4: Создание задачи с областью и проектом

**Files:**
- Create: `Features/TodoistSync/TaskCreator.swift`
- Test: `Tests/TodoistSyncTests/TaskCreatorTests.swift`

**Interfaces:**
- Consumes: `CreateTaskRequest` (Task 1); `TodoistAPI`, `TodoistProject`, `NewTodoistTask` (Task 2); `ActionJournal` (Task 3).
- Produces:
  - `public struct CreateTaskResult: Equatable, Sendable { id: String; projectID: String; createdProjects: [String]; warning: String? }`
  - `public enum ResolveError: Error, Equatable, LocalizedError { case ambiguousProject(String) }`
  - `public actor TaskCreator` с `public init(api: any TodoistAPI, journal: ActionJournal)` и `public func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/TodoistSyncTests/TaskCreatorTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

/// An in-memory Todoist account.
private actor FakeAccount: TodoistAPI {
    var projectList: [TodoistProject]
    var tasks: [NewTodoistTask] = []
    var projectCalls = 0
    var failTaskCreation = false
    private var counter = 0

    init(_ projects: [TodoistProject] = []) { projectList = projects }

    func setFailTaskCreation() { failTaskCreation = true }

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
        if failTaskCreation { throw TodoistError.requestFailed(status: 500, message: "down") }
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

@Test func aFailedTaskCreationPropagates() async {
    let account = FakeAccount([skolkovo, khibiny])
    await account.setFailTaskCreation()
    await #expect(throws: TodoistError.requestFailed(status: 500, message: "down")) {
        _ = try await TaskCreator(api: account, journal: journal()).create(request())
    }
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
```

- [ ] **Step 2: Запустить тест, убедиться, что падает**

Run: `swift test --filter TaskCreatorTests`
Expected: FAIL — `TaskCreator` не определён.

- [ ] **Step 3: Написать реализацию**

Создать `Features/TodoistSync/TaskCreator.swift`:

```swift
import Foundation

public struct CreateTaskResult: Equatable, Sendable {
    public let id: String
    public let projectID: String
    /// Names of projects created on the way, area first.
    public let createdProjects: [String]
    /// Set when the task was created but something after it was not recorded.
    public let warning: String?
}

public enum ResolveError: Error, Equatable, LocalizedError {
    case ambiguousProject(String)

    public var errorDescription: String? {
        switch self {
        case .ambiguousProject(let name):
            return "More than one Todoist project is called \"\(name)\" at this level; rename one of them"
        }
    }
}

/// Finds or creates the area and project by name, then creates the task.
///
/// An actor with an explicit queue rather than a plain actor: actor methods interleave at every
/// `await`, so two requests for a new area would both see it missing and both create it.
public actor TaskCreator {
    private let api: any TodoistAPI
    private let journal: ActionJournal
    private var tail: Task<Void, Never>?

    public init(api: any TodoistAPI, journal: ActionJournal) {
        self.api = api
        self.journal = journal
    }

    public func create(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        let previous = tail
        let work = Task { () throws -> CreateTaskResult in
            await previous?.value
            return try await self.perform(request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private func perform(_ request: CreateTaskRequest) async throws -> CreateTaskResult {
        var projects = try await api.projects()
        var created: [String] = []
        var warnings: [String] = []

        func resolve(_ name: String, parentID: String?) async throws -> TodoistProject {
            let matches = projects.filter { $0.parentID == parentID && Self.same($0.name, name) }
            if matches.count > 1 { throw ResolveError.ambiguousProject(name) }
            if let found = matches.first { return found }
            let project = try await api.createProject(name: name, parentID: parentID)
            projects.append(project)
            created.append(name)
            await note(ActionJournal.Action.projectCreated, id: project.id, name: name, into: &warnings)
            return project
        }

        let area = try await resolve(request.area, parentID: nil)
        let target = try await request.project.map { try await resolve($0, parentID: area.id) } ?? area
        let id = try await api.createTask(NewTodoistTask(
            content: request.title,
            description: request.description,
            dueDate: request.due,
            projectID: target.id
        ))
        await note(ActionJournal.Action.taskCreated, id: id, name: nil, into: &warnings)

        return CreateTaskResult(
            id: id,
            projectID: target.id,
            createdProjects: created,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        )
    }

    /// A journal failure never fails the request: what it would have recorded has already
    /// happened in Todoist, and an error here would make the agent retry it.
    private func note(_ action: String, id: String, name: String?, into warnings: inout [String]) async {
        do {
            try await journal.record(action: action, todoistID: id, name: name)
        } catch {
            warnings.append("action journal not written for \(action) \(id): \(error.localizedDescription)")
        }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let normalize = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalize(a) == normalize(b)
    }
}
```

Примечание для исполнителя: если компилятор Swift 6 не пропускает `inout` через вложенную `async`-функцию, захватывающую `projects` и `created`, вынести `resolve` в приватный метод актора, который принимает и возвращает накопленное состояние (`inout` параметры метода актора допустимы). Поведение и тесты не меняются.

- [ ] **Step 4: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter TaskCreatorTests`
Expected: PASS.

- [ ] **Step 5: Полный прогон**

Run: `swift test`
Expected: 0 падений.

---

### Task 5: Разбор HTTP и маршрутизация

**Files:**
- Create: `Features/TodoistSync/HTTPMessages.swift`
- Create: `Features/TodoistSync/TodoistEndpoint.swift`
- Test: `Tests/TodoistSyncTests/HTTPMessagesTests.swift`
- Test: `Tests/TodoistSyncTests/TodoistEndpointTests.swift`

**Interfaces:**
- Consumes: `CreateTaskRequest`, `RequestError` (Task 1); `TodoistError` (Task 2); `TaskCreator`, `CreateTaskResult`, `ResolveError` (Task 4).
- Produces:
  - `public enum HTTPParseResult: Equatable { case incomplete; case complete(method: String, path: String, body: Data); case invalid(status: Int) }`
  - `public enum HTTPRequestParser { public static let maxBody = 65_536; public static func parse(_ buffer: Data) -> HTTPParseResult }`
  - `public struct HTTPResponse: Equatable, Sendable { status: Int; body: Data; public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse; public func serialized() -> Data }`
  - `public struct TodoistEndpoint: Sendable` с `public init(create: @escaping @Sendable (CreateTaskRequest) async throws -> CreateTaskResult)` и `public func respond(method: String, path: String, body: Data) async -> HTTPResponse`

- [ ] **Step 1: Написать падающие тесты разбора**

Создать `Tests/TodoistSyncTests/HTTPMessagesTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

private func bytes(_ text: String) -> Data { Data(text.utf8) }

@Test func aCompletePostIsParsed() {
    let raw = "POST /tasks HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .complete(method: "POST", path: "/tasks", body: bytes("{}")))
}

@Test func headerNamesAreCaseInsensitive() {
    let raw = "POST /tasks HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .complete(method: "POST", path: "/tasks", body: bytes("{}")))
}

@Test func aGetWithoutBodyIsComplete() {
    #expect(HTTPRequestParser.parse(bytes("GET /health HTTP/1.1\r\n\r\n"))
        == .complete(method: "GET", path: "/health", body: Data()))
}

@Test func theQueryStringIsDropped() {
    #expect(HTTPRequestParser.parse(bytes("GET /health?x=1 HTTP/1.1\r\n\r\n"))
        == .complete(method: "GET", path: "/health", body: Data()))
}

// TCP delivers in pieces; half a request is a reason to keep reading, not an error.
@Test func headersWithoutTheirEndAreIncomplete() {
    #expect(HTTPRequestParser.parse(bytes("POST /tasks HTTP/1.1\r\nContent-Le")) == .incomplete)
}

@Test func aBodyShorterThanItsLengthIsIncomplete() {
    let raw = "POST /tasks HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .incomplete)
}

@Test func anOversizedBodyIsRefusedBeforeItArrives() {
    let raw = "POST /tasks HTTP/1.1\r\nContent-Length: 70000\r\n\r\n"
    #expect(HTTPRequestParser.parse(bytes(raw)) == .invalid(status: 413))
}

@Test func endlessHeadersAreRefused() {
    let raw = "POST /tasks HTTP/1.1\r\n" + String(repeating: "X-Pad: aaaaaaaa\r\n", count: 2000)
    #expect(HTTPRequestParser.parse(bytes(raw)) == .invalid(status: 431))
}

@Test func garbageIsABadRequest() {
    #expect(HTTPRequestParser.parse(bytes("hello\r\n\r\n")) == .invalid(status: 400))
}

@Test func aNonNumericLengthIsABadRequest() {
    #expect(HTTPRequestParser.parse(bytes("POST /tasks HTTP/1.1\r\nContent-Length: ten\r\n\r\n")) == .invalid(status: 400))
}

@Test func aResponseIsSerializedWithLengthAndClose() {
    let response = HTTPResponse(status: 201, body: bytes("{}"))
    let text = String(decoding: response.serialized(), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
    #expect(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
    #expect(text.contains("Content-Length: 2\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{}"))
}

@Test func contentLengthCountsBytesNotCharacters() {
    let response = HTTPResponse(status: 200, body: bytes("ё"))
    #expect(String(decoding: response.serialized(), as: UTF8.self).contains("Content-Length: 2\r\n"))
}
```

- [ ] **Step 2: Написать падающие тесты маршрутизации**

Создать `Tests/TodoistSyncTests/TodoistEndpointTests.swift`:

```swift
import Foundation
import Testing
@testable import TodoistSync

private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
}

private let validBody = Data(#"{"title":"T","area":"Сколково","project":"Хибины"}"#.utf8)

private func endpoint(_ create: @escaping @Sendable (CreateTaskRequest) async throws -> CreateTaskResult) -> TodoistEndpoint {
    TodoistEndpoint(create: create)
}

private let succeeding = endpoint { _ in
    CreateTaskResult(id: "6hRv", projectID: "p1", createdProjects: ["Хибины"], warning: nil)
}

@Test func aCreatedTaskAnswers201WithItsId() async throws {
    let response = await succeeding.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(response.status == 201)
    let json = try object(response)
    #expect(json["id"] as? String == "6hRv")
    #expect(json["project_id"] as? String == "p1")
    #expect(json["created_projects"] as? [String] == ["Хибины"])
    #expect(json["warning"] == nil)
}

@Test func aWarningIsPassedOn() async throws {
    let warned = endpoint { _ in CreateTaskResult(id: "t", projectID: "p", createdProjects: [], warning: "journal") }
    let json = try object(await warned.respond(method: "POST", path: "/tasks", body: validBody))
    #expect(json["warning"] as? String == "journal")
}

@Test func theRequestIsHandedOverDecoded() async throws {
    let seen = SeenRequest()
    let recording = endpoint { request in
        await seen.set(request)
        return CreateTaskResult(id: "t", projectID: "p", createdProjects: [], warning: nil)
    }
    _ = await recording.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(await seen.value == CreateTaskRequest(title: "T", description: nil, due: nil, area: "Сколково", project: "Хибины"))
}

private actor SeenRequest {
    var value: CreateTaskRequest?
    func set(_ request: CreateTaskRequest) { value = request }
}

@Test func aBadRequestIs400AndNeverReachesTodoist() async throws {
    let untouchable = endpoint { _ in
        Issue.record("must not be called")
        throw TodoistError.tokenMissing
    }
    let response = await untouchable.respond(method: "POST", path: "/tasks", body: Data(#"{"area":"A"}"#.utf8))
    #expect(response.status == 400)
    #expect((try object(response)["error"] as? String)?.contains("title") == true)
}

@Test func aMissingTokenIs503() async {
    let failing = endpoint { _ in throw TodoistError.tokenMissing }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 503)
}

@Test func aKeychainRefusalIs503() async {
    let failing = endpoint { _ in throw TodoistError.keychain("denied") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 503)
}

@Test func aTodoistFailureIs502WithItsStatus() async throws {
    let failing = endpoint { _ in throw TodoistError.requestFailed(status: 429, message: "slow down") }
    let response = await failing.respond(method: "POST", path: "/tasks", body: validBody)
    #expect(response.status == 502)
    let json = try object(response)
    #expect(json["todoist_status"] as? Int == 429)
    #expect((json["error"] as? String)?.contains("slow down") == true)
}

@Test func anUnreadableTodoistAnswerIs502() async {
    let failing = endpoint { _ in throw TodoistError.unexpectedResponse("no id") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 502)
}

@Test func anAmbiguousProjectIs409() async {
    let failing = endpoint { _ in throw ResolveError.ambiguousProject("Хибины") }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 409)
}

@Test func anythingElseIs500() async {
    let failing = endpoint { _ in throw URLError(.timedOut) }
    #expect(await failing.respond(method: "POST", path: "/tasks", body: validBody).status == 500)
}

// The agent's first question after a failed request: is NoHands there at all.
@Test func healthAnswers200() async throws {
    let response = await succeeding.respond(method: "GET", path: "/health", body: Data())
    #expect(response.status == 200)
    #expect(try object(response)["ok"] as? Bool == true)
}

@Test func theWrongMethodIs405() async {
    #expect(await succeeding.respond(method: "GET", path: "/tasks", body: Data()).status == 405)
}

@Test func anUnknownPathIs404() async {
    #expect(await succeeding.respond(method: "POST", path: "/nope", body: Data()).status == 404)
}
```

- [ ] **Step 3: Запустить тесты, убедиться, что падают**

Run: `swift test --filter "HTTPMessagesTests|TodoistEndpointTests"`
Expected: FAIL — типы не определены.

- [ ] **Step 4: Написать разбор и ответ**

Создать `Features/TodoistSync/HTTPMessages.swift`:

```swift
import Foundation

public enum HTTPParseResult: Equatable {
    case incomplete
    case complete(method: String, path: String, body: Data)
    case invalid(status: Int)
}

/// Just enough HTTP/1.1 for one local caller sending one request per connection: a request line,
/// headers, and a body sized by `Content-Length`. No chunked encoding, no keep-alive.
public enum HTTPRequestParser {
    public static let maxBody = 65_536
    static let maxHeaders = 16_384

    public static func parse(_ buffer: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaders ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaders else { return .invalid(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return .invalid(status: 400)
        }
        let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        var length = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(value), parsed >= 0 else { return .invalid(status: 400) }
            length = parsed
        }
        guard length <= maxBody else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(method: String(parts[0]), path: path, body: body)
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
```

- [ ] **Step 5: Написать маршрутизацию**

Создать `Features/TodoistSync/TodoistEndpoint.swift`:

```swift
import Foundation

/// Turns one local HTTP request into one answer. Every failure becomes a status code and a
/// sentence the agent can repeat to the owner; nothing falls back silently.
public struct TodoistEndpoint: Sendable {
    private let create: @Sendable (CreateTaskRequest) async throws -> CreateTaskResult

    public init(create: @escaping @Sendable (CreateTaskRequest) async throws -> CreateTaskResult) {
        self.create = create
    }

    public func respond(method: String, path: String, body: Data) async -> HTTPResponse {
        switch (method, path) {
        case ("GET", "/health"):
            return .json(200, ["ok": true])
        case ("POST", "/tasks"):
            return await createTask(body)
        case (_, "/tasks"), (_, "/health"):
            return .json(405, ["error": "Method \(method) is not allowed on \(path)"])
        default:
            return .json(404, ["error": "No such endpoint: \(path)"])
        }
    }

    private func createTask(_ body: Data) async -> HTTPResponse {
        let request: CreateTaskRequest
        do {
            request = try CreateTaskRequest.decode(body)
        } catch {
            return .json(400, ["error": error.localizedDescription])
        }
        do {
            let result = try await create(request)
            var answer: [String: Any] = [
                "id": result.id,
                "project_id": result.projectID,
                "created_projects": result.createdProjects,
            ]
            if let warning = result.warning { answer["warning"] = warning }
            return .json(201, answer)
        } catch let error as TodoistError {
            switch error {
            case .tokenMissing, .keychain:
                return .json(503, ["error": error.localizedDescription])
            case .requestFailed(let status, _):
                return .json(502, ["error": error.localizedDescription, "todoist_status": status])
            case .unexpectedResponse:
                return .json(502, ["error": error.localizedDescription])
            }
        } catch let error as ResolveError {
            return .json(409, ["error": error.localizedDescription])
        } catch {
            return .json(500, ["error": error.localizedDescription])
        }
    }
}
```

- [ ] **Step 6: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter "HTTPMessagesTests|TodoistEndpointTests"`
Expected: PASS.

- [ ] **Step 7: Полный прогон**

Run: `swift test`
Expected: 0 падений.

---

### Task 6: Локальный HTTP-сервер

**Files:**
- Create: `Features/TodoistSync/LocalHTTPServer.swift`
- Test: `Tests/TodoistSyncTests/LocalHTTPServerTests.swift`

**Interfaces:**
- Consumes: `HTTPRequestParser`, `HTTPParseResult`, `HTTPResponse` (Task 5).
- Produces:
  - `public final class LocalHTTPServer: @unchecked Sendable` с `public init(port: UInt16, handler: @escaping @Sendable (String, String, Data) async -> HTTPResponse)`, `public func start() async throws -> UInt16` (возвращает фактический порт; `port: 0` — любой свободный), `public func stop()`
  - `public enum TodoistSyncConfig { public static let port: UInt16 = 41730 }`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/TodoistSyncTests/LocalHTTPServerTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import TodoistSync

private func startEcho() async throws -> (LocalHTTPServer, UInt16) {
    let server = LocalHTTPServer(port: 0) { method, path, body in
        .json(200, ["method": method, "path": path, "size": body.count])
    }
    let port = try await server.start()
    return (server, port)
}

private func call(_ port: UInt16, method: String, path: String, body: Data? = nil) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 5
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return ((response as! HTTPURLResponse).statusCode, json)
}

@Test func aRequestReachesTheHandlerAndTheAnswerComesBack() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }

    let (status, json) = try await call(port, method: "POST", path: "/tasks", body: Data(#"{"a":1}"#.utf8))
    #expect(status == 200)
    #expect(json["method"] as? String == "POST")
    #expect(json["path"] as? String == "/tasks")
    #expect(json["size"] as? Int == 7)
}

@Test func severalRequestsInARowAreServed() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }
    for _ in 0..<5 {
        let (status, _) = try await call(port, method: "GET", path: "/health")
        #expect(status == 200)
    }
}

@Test func anOversizedBodyGets413() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }
    let (status, _) = try await call(port, method: "POST", path: "/tasks",
                                     body: Data(repeating: 0x61, count: HTTPRequestParser.maxBody + 1))
    #expect(status == 413)
}

// A client that sends half a request and hangs up must not take the server with it.
@Test func aClientThatHangsUpMidRequestDoesNotBreakTheServer() async throws {
    let (server, port) = try await startEcho()
    defer { server.stop() }

    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global())
    connection.send(content: Data("POST /tasks HTTP/1.1\r\nContent-Length: 100\r\n\r\n{".utf8),
                    completion: .contentProcessed { _ in })
    try await Task.sleep(for: .milliseconds(100))
    connection.cancel()

    let (status, _) = try await call(port, method: "GET", path: "/health")
    #expect(status == 200)
}

@Test func aTakenPortIsAnError() async throws {
    let (first, port) = try await startEcho()
    defer { first.stop() }
    let second = LocalHTTPServer(port: port) { _, _, _ in .json(200, [:]) }
    await #expect(throws: (any Error).self) { _ = try await second.start() }
}
```

- [ ] **Step 2: Запустить тест, убедиться, что падает**

Run: `swift test --filter LocalHTTPServerTests`
Expected: FAIL — `LocalHTTPServer` не определён.

- [ ] **Step 3: Написать реализацию**

Создать `Features/TodoistSync/LocalHTTPServer.swift`:

```swift
import Foundation
import Network
import os

public enum TodoistSyncConfig {
    /// Fixed so BigHead's schema can name it. Loopback only — see `LocalHTTPServer`.
    public static let port: UInt16 = 41730
}

/// The local door BigHead's agent knocks on with `curl`. Loopback interface only: nothing outside
/// this machine can reach it. One request per connection, then the connection is closed.
public final class LocalHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String, String, Data) async -> HTTPResponse

    /// A client that opens a connection and never finishes its request is dropped after this.
    private static let readDeadline: TimeInterval = 10
    private static let logger = Logger(subsystem: "com.nohands.app", category: "todoist-sync")

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.nohands.todoist-sync.server")
    private let state = OSAllocatedUnfairLock<NWListener?>(initialState: nil)

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// - Returns: the port actually bound — the requested one, or a free one when 0 was asked for.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: nwPort)
        state.withLock { $0 = listener }

        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { newState in
                let finish: (Result<UInt16, Error>) -> Void = { result in
                    let first = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(with: result) }
                }
                switch newState {
                case .ready:
                    finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    listener.cancel()
                    finish(.failure(error))
                case .waiting(let error):
                    // A taken port shows up here rather than as `.failed`.
                    listener.cancel()
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(NWError.posix(.ECANCELED)))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        state.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readDeadline) { [weak connection] in
            // Cancelling a connection that has already answered and closed is harmless.
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            switch HTTPRequestParser.parse(buffer) {
            case .complete(let method, let path, let body):
                let handler = self.handler
                Task {
                    let response = await handler(method, path, body)
                    self.reply(response, on: connection)
                }
            case .invalid(let status):
                self.reply(.json(status, ["error": HTTPResponse.reason(status)]), on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func reply(_ response: HTTPResponse, on connection: NWConnection) {
        Self.logger.info("local request answered \(response.status, privacy: .public)")
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
```

Примечание для исполнителя: сообщение в лог содержит только код ответа. Тело запроса и ответа не логируется: в них текст задач владельца.

- [ ] **Step 4: Запустить тесты, убедиться, что проходят**

Run: `swift test --filter LocalHTTPServerTests`
Expected: PASS. Если `aTakenPortIsAnError` зависает, а не падает, — значит занятый порт приходит другим состоянием слушателя. Логировать `newState` в тесте, найти фактическое состояние и обработать его тем же `finish(.failure)`.

- [ ] **Step 5: Полный прогон**

Run: `swift test`
Expected: 0 падений.

---

### Task 7: Подключение в приложении

**Files:**
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `TodoistClient`, `ActionJournal`, `TaskCreator`, `TodoistEndpoint`, `LocalHTTPServer`, `TodoistSyncConfig` (Tasks 2–6).
- Produces: работающий `http://127.0.0.1:41730` в запущенном `NoHands.app`.

Тестов на `AppDelegate` в проекте нет, поведение проверяется руками в шаге 4.

- [ ] **Step 1: Импорт и свойства**

В начало `App/AppDelegate.swift` к импортам:

```swift
import TodoistSync
```

К свойствам класса, после `private var sounds: SoundPlayer?`:

```swift
    /// Built once and kept: the port is fixed, and a second server could not bind it anyway.
    /// Nil until it has started — a failed start is retried by «Перечитать конфиг».
    private var todoistServer: LocalHTTPServer?
    /// Why the local Todoist door is closed, for the menu's status line. Nil when it is open.
    private var todoistNote: String?
    private let todoistClient = TodoistClient()
```

- [ ] **Step 2: Запуск сервера**

Добавить метод в класс:

```swift
    /// Opens the local door BigHead's agent uses to create Todoist tasks. Started inside the build
    /// task, before meetings, so its failure lands on the same status line as everything else.
    private func startTodoistSync() async {
        guard todoistServer == nil else { return }
        let creator = TaskCreator(api: todoistClient, journal: ActionJournal(url: ActionJournal.defaultURL))
        let endpoint = TodoistEndpoint(create: { try await creator.create($0) })
        let server = LocalHTTPServer(port: TodoistSyncConfig.port) { method, path, body in
            await endpoint.respond(method: method, path: path, body: body)
        }
        do {
            _ = try await server.start()
            todoistServer = server
            todoistNote = nil
        } catch {
            todoistNote = "todoist: порт \(TodoistSyncConfig.port) не открылся — \(error.localizedDescription)"
            return
        }
        // Raises the Keychain dialog now, while the owner is at the machine, instead of in the
        // middle of the first task an agent creates.
        await todoistClient.warmUp()
    }
```

В `startBuild`, внутри `buildTask = Task { [weak self] in`, первой строкой:

```swift
            await self?.startTodoistSync()
```

- [ ] **Step 3: Строка статуса**

Заменить `status`:

```swift
    /// The menu has one status line and, on a bad day, several things to say on it.
    private static func status(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }
```

В `buildCoordinator` оба вызова дополнить заметкой:

```swift
            menu.setStatus(Self.status("Готов", meetingsNote, todoistNote))
```

```swift
            menu.setStatus(Self.status(error.localizedDescription, meetingsNote, todoistNote))
```

- [ ] **Step 4: Собрать, установить, проверить руками**

Run: `swift build && swift test && ./Scripts/make-app.sh`
Expected: сборка без ошибок, тесты зелёные, `NoHands.app` установлен в `/Applications` и запущен.

Run: `curl -sS http://127.0.0.1:41730/health`
Expected: `{"ok":true}`

Run: `curl -sS -X POST http://127.0.0.1:41730/tasks -d '{"area":"X"}'`
Expected: `400` с текстом про `title`. В Todoist ничего не создано.

Run: `curl -sS http://127.0.0.1:41730/nope`
Expected: `404`.

При первом запуске может появиться диалог Keychain «NoHands хочет использовать nohands-todoist»: владелец разрешает один раз.

- [ ] **Step 5: Живая проверка создания — только с разрешения владельца**

Создаёт настоящую задачу в Todoist владельца. Перед шагом спросить владельца в чате, получить «да».

```bash
curl -sS -X POST http://127.0.0.1:41730/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"Проверка синхронизации NoHands — удалить","area":"Сколково"}'
```

Expected: `201`, `{"created_projects":[],"id":"…","project_id":"…"}`. Задача видна в Todoist в проекте «Сколково». В `~/Library/Application Support/NoHands/todoist-actions.jsonl` есть строка `task.created` с тем же `id`. Повторить запрос: второй проект «Сколково» не появился. Тестовую задачу владелец удаляет руками.

---

### Task 8: Правила в Башке

**Files:**
- Modify: `/Users/macintosh/BigHead/AGENTS.md` (раздел «Задачи», список областей)
- Modify: `/Users/macintosh/BigHead/wiki/projects/<проект>.md` для активных проектов board — поле `todoist:` во frontmatter
- Modify: `/Users/macintosh/BigHead/wiki/log.md` — запись `schema`

**Interfaces:**
- Consumes: работающий `POST /tasks` на `127.0.0.1:41730` (Task 7).
- Produces: ingest Башки отправляет каждую новую задачу в Todoist и пишет `· todoist:<id>` в строку.

Значения пар названий подтверждает владелец до этой задачи. Предложение из живого списка проектов Todoist от 2026-10-07:

| Башка | Todoist |
|---|---|
| область `skolkovo` | Сколково |
| область `roox` | RooX |
| область `job-search` | Обновление портфолио и поиск работы |
| `khibiny` | Переход Хибин на модель одного админа |
| `brandsim` | Бренд симулятор |
| `roox-indid` | ИНДИД (будет создан) |
| `roox-ai-site` | Сайт RooX через ИИ (будет создан) |
| `portfolio` | Портфолио (будет создан) |

- [ ] **Step 1: Список областей в схеме**

В `AGENTS.md` заменить строку:

```
Области — не папки, а поле `area` во frontmatter. Текущие значения: `skolkovo`, `roox`, `job-search`, `all`. Новая область = новое значение + секция в board и index.
```

на:

```
Области — не папки, а поле `area` во frontmatter. Текущие значения: `skolkovo`, `roox`, `job-search`, `all`. Новая область = новое значение + секция в board и index + имя в Todoist в таблице ниже.

| Область | Проект в Todoist |
|---|---|
| `skolkovo` | Сколково |
| `roox` | RooX |
| `job-search` | Обновление портфолио и поиск работы |
```

(значения правой колонки — подтверждённые владельцем)

- [ ] **Step 2: Поле проекта**

В блоке «**projects/** — доп. поле `state: active | paused | done`.» дописать после этого предложения:

```
Активный проект в board — ещё поле `todoist: "<имя проекта в Todoist>"`: под этим именем он живёт подпроектом своей области.
```

- [ ] **Step 3: Раздел о Todoist**

В `AGENTS.md` в конец раздела «## Задачи» (перед «## Операции») добавить:

```
### Todoist

Задачи board синхронизируются с Todoist через NoHands — приложение на этой машине. Todoist — та же задача, не копия: создание задачи в Todoist самим Арсланом равно его «ок».

После того как задача записана в board (с «ок» Арслана), она отправляется в NoHands:

    curl -sS -m 120 -X POST http://127.0.0.1:41730/tasks \
      -H 'Content-Type: application/json' -H 'Expect:' \
      -d '{"title":"…","description":"…","due":"ГГГГ-ММ-ДД","area":"<область в Todoist>","project":"<todoist: проекта>"}'

- `area` — имя области из таблицы областей; `project` — поле `todoist:` страницы проекта. Для задачи из «Общее» `project` не передаётся. `description` — строка под задачей, если есть. `due` — только если срок назван.
- Ответ `201` с `id` → в строку задачи после даты добавления: `· todoist:<id>`. `id` берётся из ответа и только из него; без `id` в ответе ничего не пишется.
- В ответе есть `warning` → задача создана, `id` записывается, предупреждение — Арслану в чат.
- `400`, `409` — запрос неправильный или проект неоднозначен: не повторять, сказать Арслану текст ошибки.
- `curl` не смог подключиться (код выхода 7) или ответ `503` → ещё две попытки; затем `open -a NoHands`, подождать 5 секунд, `curl -sS http://127.0.0.1:41730/health`, ещё одна попытка; не вышло — задача остаётся в board без `todoist:`, Арслану в чат: задача в Todoist не ушла и почему.
- `504`, `502`, таймаут `curl` или обрыв после подключения (коды выхода 28, 52, 56) → **не повторять**: задача могла создаться. Задача остаётся в board без `todoist:`, Арслану в чат: проверить Todoist, прежде чем отправлять снова.
- Задачи Бэклога не отправляются: это идеи, а не задачи.
- Задачи, у которых уже есть `todoist:`, не отправляются повторно.
```

- [ ] **Step 4: Поле `todoist:` в проектах**

Для каждого проекта из таблицы пар добавить во frontmatter строку после `area:`:

```yaml
todoist: "<имя в Todoist>"
```

и обновить `updated:` на дату правки.

- [ ] **Step 5: Запись в журнал Башки**

В конец `/Users/macintosh/BigHead/wiki/log.md`:

```
## [2026-10-07] schema | Синхронизация задач с Todoist через NoHands, первый срез

- AGENTS.md: таблица областей с именами в Todoist; поле `todoist:` у активных проектов; раздел «Todoist» в «Задачах» — отправка новой задачи в NoHands после записи в board, формат `· todoist:<id>`
- wiki/projects/<список изменённых>: поле `todoist:`
```

(список проектов — фактически изменённые в шаге 4)

- [ ] **Step 6: Проверка**

Run: `grep -n "todoist" /Users/macintosh/BigHead/AGENTS.md /Users/macintosh/BigHead/wiki/projects/*.md`
Expected: таблица областей, раздел «Todoist», поле в каждом проекте из таблицы пар.

Run: `curl -sS http://127.0.0.1:41730/health`
Expected: `{"ok":true}` — адрес из схемы отвечает.

- [ ] **Step 7: Разовая выгрузка существующих задач**

Решение владельца 2026-10-07: задачи, уже лежащие в board без `todoist:`, уезжают в Todoist один раз. Бэклог не трогается.

Для каждой строки `- [ ]` в секциях областей `board.md` без `· todoist:` — запрос из раздела «Todoist» схемы: `title` — текст задачи без хвоста « · добавлена …» и без ссылок `[[…]]`, `description` — строка под задачей, если есть, `area` и `project` — по секции. Вложенные подзадачи (`  - [ ]`) уходят отдельными задачами в тот же проект. `id` из ответа дописать в строку `· todoist:<id>`.

Run: `grep -c "todoist:" /Users/macintosh/BigHead/wiki/board.md`
Expected: число равно числу задач `- [ ]` в секциях областей.

Запись в `log.md`: `## [2026-10-07] task | Разовая выгрузка задач board в Todoist` со списком задач и их `id`.
