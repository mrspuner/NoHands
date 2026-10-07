# Синхронизация с Todoist — обратный путь (срезы 3–5). План реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** NoHands раз в минуту забирает изменения Todoist через Sync API, отсеивает эхо собственных действий и всё нерабочее, пишет события в `raw/` Башки и запускает её ingest; новые проекты ждут решения владельца, отклонённые больше не приходят.

**Architecture:** Чистые части отдельно и под тестами: настройки (`TodoistInboundConfig`), модели и вызов Sync (`TodoistClient.sync`), состояние на диске (`SyncStateStore`), сборка событий с фильтрами (`InboundEvents`), формат файла (`InboundRawFile`), запуск агента (`IngestRunner` за протоколом `ProcessRunning`). Склейка — актор `InboundPoller` с одним методом `tick()`, который никогда не бросает. Отклонение проекта — новая операция `ignoreProject` и маршрут `POST /projects/ignore`. `AppDelegate` заводит таймер.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 15, Foundation, swift-testing. Новых зависимостей нет.

**Spec:** `docs/superpowers/specs/2026-10-07-todoist-sync-inbound-design.md`

## Global Constraints

- Новых зависимостей нет. Идентификаторы, комментарии, сообщения об ошибках — по-английски; строки статуса меню — по-русски.
- Токен — только в Keychain; нигде не печатается. Текст задач владельца не логируется (в лог — только счётчики и коды).
- Ни один тест не ходит в Todoist, не читает Keychain, не пишет в настоящие `~/Library/Application Support/NoHands/` и `/Users/macintosh/BigHead/`, не запускает настоящий `claude`.
- Sync API v1 проверен живьём 2026-10-07: `POST /api/v1/sync` с `{"sync_token":"*","resource_types":["items","projects"]}` → `{"full_sync", "sync_token", "items":[…], "projects":[…], …}`. Поля задачи: `id`, `content`, `description`, `due` (объект с `date` или `null`), `project_id`, `checked`, `is_deleted`, `added_at`, `updated_at` (вида `2026-10-07T14:07:22.518073Z`, шесть знаков дробной части). Поля проекта: `id`, `name`, `parent_id`, `is_archived`, `is_deleted`.
- Время журнала — `2026-10-07T14:48:22Z` (без дробной части). Сравнение времён — по первым 19 символам плюс `Z`.
- Фильтр эха: событие отбрасывается, если в журнале есть запись с тем же `id` и временем ≥ `updated_at` − 5 с. Проект — если в журнале вообще есть запись с его `id`.
- Первый опрос (нет токена) и любой ответ с `full_sync: true` — только запоминают токен и карту проектов, событий не дают.
- Состояние сохраняется до запуска ingest.
- Запуск агента: `claude -p "<промпт>" --permission-mode acceptEdits --allowedTools Read,Edit,Write,Glob,Grep`, рабочая папка — `bigheadPath`, таймаут 600 с, запуски строго по одному. Промпт — позиционный аргумент сразу после `-p`.
- Коммит в конце каждой задачи, ветка `todoist-sync-inbound`. Без push.
- Базовая линия: **852 теста, 0 падений**.

## Review Focus

1. **Токен устарел, и Todoist вернул `full_sync: true`.** Ожидается, что события не создаются (иначе вся работа пришла бы в Башку как новые задачи). Тест в Task 7.
2. **Ingest упал или превысил время.** Ожидается: файл записан, состояние сохранено, причина — в отчёт статуса, следующий такт идёт нормально. Тест в Task 7.
3. **Задача в отклонённом проекте или его подпроекте.** Ожидается: события нет. Тест в Task 4.
4. **Собственное закрытие из Башки возвращается из Todoist.** Ожидается: отфильтровано по журналу. Правка владельца через минуту после нашей — не отфильтрована. Тест в Task 4.
5. **Отклонение проекта во время опроса.** Ожидается: сохранение состояния опросом не стирает только что отклонённый проект. Тест в Task 3.

---

### Task 1: Настройки обратного пути

**Files:**
- Create: `Features/TodoistSync/TodoistInboundConfig.swift`
- Test: `Tests/TodoistSyncTests/TodoistInboundConfigTests.swift`

**Interfaces:**
- Produces: `public struct TodoistInboundConfig: Equatable, Sendable, Codable { bigheadPath: String; areas: [String]; claudePath: String; pollSeconds: Double }`, `static let default`, `var isComplete: Bool`, `static var configFileURL: URL`, `static func loadOrCreate(at:) throws -> TodoistInboundConfig`, `enum TodoistInboundConfigError: Error, Equatable { case notAnObject(String) }`.

- [ ] **Step 1: Ветка** — `git checkout -b todoist-sync-inbound` (если уже создана контроллером — пропустить).

- [ ] **Step 2: Падающий тест**

```swift
import Foundation
import Testing
@testable import TodoistSync

private func tempConfig(_ json: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    if let json { try Data(json.utf8).write(to: url) }
    return url
}

@Test func aMissingFileGivesDefaultsAndIsNotCreated() throws {
    let url = try tempConfig(nil)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url) == .default)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// The dictation and meetings sections live in the same file and must survive the append.
@Test func aMissingSectionIsAppendedWithoutTouchingOthers() throws {
    let url = try tempConfig(#"{"language":"ru","meetings":{"silenceSeconds":5}}"#)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url) == .default)
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(root["language"] as? String == "ru")
    #expect(root["meetings"] != nil)
    #expect(root["todoist"] != nil)
}

@Test func anExistingSectionIsRead() throws {
    let url = try tempConfig(#"{"todoist":{"bigheadPath":"/b","areas":["Сколково"],"claudePath":"/c","pollSeconds":30}}"#)
    let config = try TodoistInboundConfig.loadOrCreate(at: url)
    #expect(config == TodoistInboundConfig(bigheadPath: "/b", areas: ["Сколково"], claudePath: "/c", pollSeconds: 30))
    #expect(config.isComplete)
}

// Edited by hand: a missing key falls back to its default instead of failing the whole section.
@Test func missingKeysFallBackToDefaults() throws {
    let url = try tempConfig(#"{"todoist":{"areas":["RooX"]}}"#)
    let config = try TodoistInboundConfig.loadOrCreate(at: url)
    #expect(config.areas == ["RooX"])
    #expect(config.pollSeconds == 60)
    #expect(!config.isComplete)
}

@Test func aNonObjectFileIsAnError() throws {
    let url = try tempConfig("[]")
    #expect(throws: TodoistInboundConfigError.self) { try TodoistInboundConfig.loadOrCreate(at: url) }
}

@Test func aTooShortPollIsRaisedToTenSeconds() throws {
    let url = try tempConfig(#"{"todoist":{"pollSeconds":1}}"#)
    #expect(try TodoistInboundConfig.loadOrCreate(at: url).pollSeconds == 10)
}
```

- [ ] **Step 3: RED** — `swift test --filter TodoistInboundConfigTests` → не компилируется.

- [ ] **Step 4: Реализация**

```swift
import Foundation

/// The `todoist` section of NoHands's `config.json`: where BigHead lives, which Todoist root
/// projects are its areas, and how to reach `claude`. Edited by hand; every key is optional.
public struct TodoistInboundConfig: Equatable, Sendable, Codable {
    public var bigheadPath: String
    /// Names of the Todoist root projects that are BigHead areas. Everything outside them is
    /// personal and never reaches BigHead.
    public var areas: [String]
    public var claudePath: String
    public var pollSeconds: Double

    public static let `default` = TodoistInboundConfig(bigheadPath: "", areas: [], claudePath: "", pollSeconds: 60)

    /// A shorter interval buys nothing and spends Todoist's rate limit.
    static let minimumPollSeconds: Double = 10

    public init(bigheadPath: String, areas: [String], claudePath: String, pollSeconds: Double) {
        self.bigheadPath = bigheadPath
        self.areas = areas
        self.claudePath = claudePath
        self.pollSeconds = max(pollSeconds, Self.minimumPollSeconds)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bigheadPath: try c.decodeIfPresent(String.self, forKey: .bigheadPath) ?? "",
            areas: try c.decodeIfPresent([String].self, forKey: .areas) ?? [],
            claudePath: try c.decodeIfPresent(String.self, forKey: .claudePath) ?? "",
            pollSeconds: try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? 60
        )
    }

    /// Polling needs all three: where to write, what counts as work, what to run.
    public var isComplete: Bool {
        !bigheadPath.isEmpty && !areas.isEmpty && !claudePath.isEmpty
    }

    public static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoHands").appendingPathComponent("config.json")
    }

    /// Same contract as `MeetingsConfig.loadOrCreate`: a missing file is never created here
    /// (dictation owns creating it); a missing section is appended with defaults, keeping every
    /// other key in the file.
    public static func loadOrCreate(at url: URL = configFileURL) throws -> TodoistInboundConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TodoistInboundConfigError.notAnObject(url.path)
        }
        if let section = root["todoist"] {
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: section))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        root["todoist"] = try JSONSerialization.jsonObject(with: encoder.encode(Self.default))
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return .default
    }
}

public enum TodoistInboundConfigError: Error, Equatable {
    case notAnObject(String)
}
```

- [ ] **Step 5: GREEN** — `swift test --filter TodoistInboundConfigTests`, затем `swift test`.

- [ ] **Step 6: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: настройки обратного пути в config.json"`

---

### Task 2: Вызов Sync API

**Files:**
- Modify: `Features/TodoistSync/TodoistAPI.swift` (модели и протокол `TodoistSyncing`)
- Modify: `Features/TodoistSync/TodoistClient.swift` (`sync(token:)`, соответствие `TodoistSyncing`)
- Test: `Tests/TodoistSyncTests/TodoistClientTests.swift`

**Interfaces:**
- Produces:
  - `public struct SyncItem: Equatable, Sendable, Decodable { id: String; content: String; description: String?; dueDate: String?; projectID: String; checked: Bool; isDeleted: Bool; addedAt: String?; updatedAt: String? }` (`dueDate` — первые 10 символов `due.date`)
  - `public struct SyncProject: Equatable, Sendable, Decodable { id: String; name: String; parentID: String?; isArchived: Bool; isDeleted: Bool }`
  - `public struct SyncResponse: Equatable, Sendable, Decodable { syncToken: String; fullSync: Bool; items: [SyncItem]; projects: [SyncProject] }`
  - `public protocol TodoistSyncing: Sendable { func sync(token: String) async throws -> SyncResponse }`
  - `extension TodoistClient: TodoistSyncing`

- [ ] **Step 1: Падающие тесты** (дописать в `TodoistClientTests.swift`)

```swift
// MARK: - Sync

@Test func syncSendsTheTokenAndResourceTypes() async throws {
    let transport = FakeTransport([(200, #"{"sync_token":"t2","full_sync":false,"items":[],"projects":[]}"#)])
    let response = try await client(transport).sync(token: "t1")
    #expect(response == SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: []))
    let request = transport.requests[0]
    #expect(request.httpMethod == "POST")
    #expect(request.url!.absoluteString == "https://api.todoist.com/api/v1/sync")
    let body = try json(request)
    #expect(body["sync_token"] as? String == "t1")
    #expect(body["resource_types"] as? [String] == ["items", "projects"])
}

@Test func syncDecodesItemsAndProjects() async throws {
    let transport = FakeTransport([(200, """
    {"sync_token":"t2","full_sync":true,
     "items":[{"id":"i1","content":"T","description":"D","due":{"date":"2026-10-12T10:00:00","string":"x"},"project_id":"p1","checked":true,"is_deleted":false,"added_at":"2026-10-07T14:07:22.518055Z","updated_at":"2026-10-07T14:07:22.518073Z","labels":[]},
              {"id":"i2","content":"U","description":"","due":null,"project_id":"p1","checked":false,"is_deleted":true}],
     "projects":[{"id":"p1","name":"Хибины","parent_id":"a","is_archived":false,"is_deleted":false},
                 {"id":"a","name":"Сколково","parent_id":null}]}
    """)])
    let response = try await client(transport).sync(token: "*")
    #expect(response.fullSync)
    #expect(response.items[0] == SyncItem(
        id: "i1", content: "T", description: "D", dueDate: "2026-10-12", projectID: "p1",
        checked: true, isDeleted: false,
        addedAt: "2026-10-07T14:07:22.518055Z", updatedAt: "2026-10-07T14:07:22.518073Z"
    ))
    #expect(response.items[1].dueDate == nil)
    #expect(response.items[1].description == nil)
    #expect(response.items[1].isDeleted)
    #expect(response.projects[1] == SyncProject(id: "a", name: "Сколково", parentID: nil, isArchived: false, isDeleted: false))
}

@Test func syncToleratesMissingArrays() async throws {
    let transport = FakeTransport([(200, #"{"sync_token":"t2","full_sync":false}"#)])
    let response = try await client(transport).sync(token: "t1")
    #expect(response.items.isEmpty && response.projects.isEmpty)
}
```

- [ ] **Step 2: RED** — `swift test --filter TodoistClientTests` → не компилируется.

- [ ] **Step 3: Модели** (в `TodoistAPI.swift`)

```swift
public struct SyncItem: Equatable, Sendable, Decodable {
    public let id: String
    public let content: String
    /// Nil for an empty description: an empty string and no description mean the same to BigHead.
    public let description: String?
    /// The calendar date of the due, `YYYY-MM-DD`; a due with a time keeps only its date.
    public let dueDate: String?
    public let projectID: String
    public let checked: Bool
    public let isDeleted: Bool
    public let addedAt: String?
    public let updatedAt: String?

    public init(id: String, content: String, description: String?, dueDate: String?, projectID: String,
                checked: Bool, isDeleted: Bool, addedAt: String?, updatedAt: String?) {
        self.id = id; self.content = content; self.description = description; self.dueDate = dueDate
        self.projectID = projectID; self.checked = checked; self.isDeleted = isDeleted
        self.addedAt = addedAt; self.updatedAt = updatedAt
    }

    private struct Due: Decodable { let date: String }
    private enum CodingKeys: String, CodingKey {
        case id, content, description, due, checked
        case projectID = "project_id", isDeleted = "is_deleted", addedAt = "added_at", updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let description = try c.decodeIfPresent(String.self, forKey: .description)
        let due = try c.decodeIfPresent(Due.self, forKey: .due)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
            description: (description?.isEmpty ?? true) ? nil : description,
            dueDate: due.map { String($0.date.prefix(10)) },
            projectID: try c.decode(String.self, forKey: .projectID),
            checked: try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false,
            isDeleted: try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false,
            addedAt: try c.decodeIfPresent(String.self, forKey: .addedAt),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt)
        )
    }
}

public struct SyncProject: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let isArchived: Bool
    public let isDeleted: Bool

    public init(id: String, name: String, parentID: String?, isArchived: Bool, isDeleted: Bool) {
        self.id = id; self.name = name; self.parentID = parentID
        self.isArchived = isArchived; self.isDeleted = isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case parentID = "parent_id", isArchived = "is_archived", isDeleted = "is_deleted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            parentID: try c.decodeIfPresent(String.self, forKey: .parentID),
            isArchived: try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            isDeleted: try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        )
    }
}

public struct SyncResponse: Equatable, Sendable, Decodable {
    public let syncToken: String
    public let fullSync: Bool
    public let items: [SyncItem]
    public let projects: [SyncProject]

    public init(syncToken: String, fullSync: Bool, items: [SyncItem], projects: [SyncProject]) {
        self.syncToken = syncToken; self.fullSync = fullSync; self.items = items; self.projects = projects
    }

    private enum CodingKeys: String, CodingKey {
        case items, projects
        case syncToken = "sync_token", fullSync = "full_sync"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            syncToken: try c.decode(String.self, forKey: .syncToken),
            fullSync: try c.decodeIfPresent(Bool.self, forKey: .fullSync) ?? false,
            items: try c.decodeIfPresent([SyncItem].self, forKey: .items) ?? [],
            projects: try c.decodeIfPresent([SyncProject].self, forKey: .projects) ?? []
        )
    }
}

/// The poll, separate from `TodoistAPI` so the poller can be tested against its own fake.
public protocol TodoistSyncing: Sendable {
    func sync(token: String) async throws -> SyncResponse
}
```

- [ ] **Step 4: Клиент** (в `TodoistClient.swift`)

```swift
extension TodoistClient: TodoistSyncing {
    public func sync(token: String) async throws -> SyncResponse {
        let data = try await send(
            method: "POST",
            url: Self.base.appendingPathComponent("sync"),
            body: ["sync_token": token, "resource_types": ["items", "projects"]]
        )
        return try Self.decode(SyncResponse.self, from: data)
    }
}
```

Если `send`, `base` или `decode` недоступны из расширения (они `private`), сделать их `fileprivate` или перенести метод в тело актора. Поведение не меняется.

- [ ] **Step 5: GREEN** — `swift test --filter TodoistClientTests`, затем `swift test`.

- [ ] **Step 6: Коммит** — `git commit -am "Todoist: вызов Sync API и его модели"` (новых файлов нет; если есть — `git add` их).

---

### Task 3: Состояние опроса на диске

**Files:**
- Create: `Features/TodoistSync/SyncStateStore.swift`
- Test: `Tests/TodoistSyncTests/SyncStateStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProjectInfo: Codable, Equatable, Sendable { name: String; parentID: String? }`
  - `public struct SyncState: Codable, Equatable, Sendable { syncToken: String?; projects: [String: ProjectInfo]; ignored: [String] }` + `static let empty`
  - `public protocol IgnoredProjectsStore: Sendable { func ignore(projectID: String) async throws }`
  - `public actor SyncStateStore: IgnoredProjectsStore` с `init(url: URL)`, `static var defaultURL`, `load() throws -> SyncState`, `saveSync(token: String, projects: [String: ProjectInfo]) throws`, `ignore(projectID:) throws`

- [ ] **Step 1: Падающий тест**

```swift
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
```

- [ ] **Step 2: RED** — `swift test --filter SyncStateStoreTests`.

- [ ] **Step 3: Реализация**

```swift
import Foundation

public struct ProjectInfo: Codable, Equatable, Sendable {
    public let name: String
    public let parentID: String?

    public init(name: String, parentID: String?) {
        self.name = name
        self.parentID = parentID
    }
}

/// What the poll needs to remember between ticks. Lives outside the repository.
public struct SyncState: Codable, Equatable, Sendable {
    public var syncToken: String?
    /// Every known Todoist project, id → name and parent, kept current from each sync.
    public var projects: [String: ProjectInfo]
    /// Projects the owner declined; their tasks and subprojects never reach BigHead.
    public var ignored: [String]

    public static let empty = SyncState(syncToken: nil, projects: [:], ignored: [])
}

public protocol IgnoredProjectsStore: Sendable {
    func ignore(projectID: String) async throws
}

public actor SyncStateStore: IgnoredProjectsStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/todoist-sync-state.json")
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
    }

    /// Replaces the token and the project map, keeping the ignored list as it is on disk now.
    public func saveSync(token: String, projects: [String: ProjectInfo]) throws {
        var state = try load()
        state.syncToken = token
        state.projects = projects
        try write(state)
    }

    public func ignore(projectID: String) throws {
        var state = try load()
        guard !state.ignored.contains(projectID) else { return }
        state.ignored.append(projectID)
        try write(state)
    }

    private func write(_ state: SyncState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter SyncStateStoreTests`, затем `swift test`.

- [ ] **Step 5: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: состояние опроса на диске"`

---

### Task 4: Сборка событий с фильтрами

**Files:**
- Create: `Features/TodoistSync/InboundEvents.swift`
- Test: `Tests/TodoistSyncTests/InboundEventsTests.swift`

**Interfaces:**
- Consumes: `SyncResponse`, `SyncItem`, `SyncProject` (Task 2); `ProjectInfo` (Task 3); `ActionJournal.Entry`.
- Produces:
  - `public struct TaskSnapshot: Equatable, Sendable { id; title; description: String?; due: String?; area: String; project: String?; addedAt: String?; updatedAt: String? }`
  - `public enum InboundEvent: Equatable, Sendable { case closed(TaskSnapshot); case deleted(TaskSnapshot); case changed(TaskSnapshot) }`
  - `public struct ProjectAdded: Equatable, Sendable { id: String; area: String; name: String }`
  - `public struct InboundBatch: Equatable, Sendable { tasks: [InboundEvent]; projects: [ProjectAdded]; projectMap: [String: ProjectInfo] }`
  - `public enum InboundEvents { public static func build(response:previous:areas:ignored:journal:) -> InboundBatch }`

- [ ] **Step 1: Падающий тест**

```swift
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
                  updated: String? = "2026-10-07T15:00:00.123456Z") -> SyncItem {
    SyncItem(id: id, content: "T \(id)", description: "D", dueDate: "2026-10-12", projectID: project,
             checked: checked, isDeleted: deleted, addedAt: "2026-10-07T14:00:00.000001Z", updatedAt: updated)
}

private func build(_ items: [SyncItem] = [], projects: [SyncProject] = [], ignored: Set<String> = [],
                   journal: [ActionJournal.Entry] = []) -> InboundBatch {
    InboundEvents.build(
        response: SyncResponse(syncToken: "t", fullSync: false, items: items, projects: projects),
        previous: map, areas: ["Сколково"], ignored: ignored, journal: journal
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
```

- [ ] **Step 2: RED** — `swift test --filter InboundEventsTests`.

- [ ] **Step 3: Реализация**

```swift
import Foundation

public struct TaskSnapshot: Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let due: String?
    public let area: String
    /// Nil when the task sits in the area project itself.
    public let project: String?
    public let addedAt: String?
    public let updatedAt: String?
}

public enum InboundEvent: Equatable, Sendable {
    case closed(TaskSnapshot)
    case deleted(TaskSnapshot)
    /// Created or edited; BigHead tells the two apart by whether the id is already on its board.
    case changed(TaskSnapshot)
}

public struct ProjectAdded: Equatable, Sendable {
    public let id: String
    public let area: String
    public let name: String
}

public struct InboundBatch: Equatable, Sendable {
    public let tasks: [InboundEvent]
    public let projects: [ProjectAdded]
    /// The project map after this sync, to be saved.
    public let projectMap: [String: ProjectInfo]
}

/// Turns one sync answer into what BigHead should hear: only work (inside an area), never a
/// declined project, never an echo of NoHands's own change.
public enum InboundEvents {
    /// A journal entry this long before Todoist's `updated_at` still counts as ours: clocks of
    /// this machine and Todoist's servers are not the same clock.
    static let echoWindow: TimeInterval = 5

    public static func build(
        response: SyncResponse,
        previous: [String: ProjectInfo],
        areas: [String],
        ignored: Set<String>,
        journal: [ActionJournal.Entry]
    ) -> InboundBatch {
        var map = previous
        for project in response.projects {
            if project.isDeleted {
                map[project.id] = nil
            } else {
                map[project.id] = ProjectInfo(name: project.name, parentID: project.parentID)
            }
        }
        let areaNames = Set(areas.map(normalize))
        let journalTimes = Dictionary(grouping: journal, by: \.todoistID)
            .mapValues { $0.compactMap { date($0.time) } }

        func placement(_ projectID: String) -> (area: String, project: String?)? {
            var chain: [String] = []
            var current: String? = projectID
            while let id = current, let info = map[id] {
                if ignored.contains(id) { return nil }
                chain.append(id)
                guard chain.count < 32 else { return nil }  // a cycle in bad data
                current = info.parentID
            }
            guard let rootID = chain.last, let root = map[rootID], root.parentID == nil,
                  areaNames.contains(normalize(root.name)) else { return nil }
            return (root.name, projectID == rootID ? nil : map[projectID]?.name)
        }

        func isEcho(_ id: String, updatedAt: String?) -> Bool {
            guard let updatedAt, let changed = date(updatedAt) else { return false }
            return (journalTimes[id] ?? []).contains { $0 >= changed.addingTimeInterval(-echoWindow) }
        }

        var tasks: [InboundEvent] = []
        for item in response.items {
            guard let place = placement(item.projectID), !isEcho(item.id, updatedAt: item.updatedAt) else { continue }
            let snapshot = TaskSnapshot(
                id: item.id, title: item.content, description: item.description, due: item.dueDate,
                area: place.area, project: place.project, addedAt: item.addedAt, updatedAt: item.updatedAt
            )
            if item.isDeleted {
                tasks.append(.deleted(snapshot))
            } else if item.checked {
                tasks.append(.closed(snapshot))
            } else {
                tasks.append(.changed(snapshot))
            }
        }

        var added: [ProjectAdded] = []
        for project in response.projects where previous[project.id] == nil && !project.isDeleted && !project.isArchived {
            guard let parentID = project.parentID, let parent = map[parentID], parent.parentID == nil,
                  areaNames.contains(normalize(parent.name)),
                  !ignored.contains(project.id), !ignored.contains(parentID),
                  journalTimes[project.id] == nil else { continue }
            added.append(ProjectAdded(id: project.id, area: parent.name, name: project.name))
        }
        return InboundBatch(tasks: tasks, projects: added, projectMap: map)
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Todoist writes six fractional digits, the journal none; seconds are all the filter needs.
    static func date(_ text: String) -> Date? {
        guard text.count >= 19 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(text.prefix(19)) + "Z")
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter InboundEventsTests`, затем `swift test`.

- [ ] **Step 5: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: события обратного пути с фильтрами области, отклонённых проектов и эха"`

---

### Task 5: Файл в `raw/` Башки

**Files:**
- Create: `Features/TodoistSync/InboundRawFile.swift`
- Test: `Tests/TodoistSyncTests/InboundRawFileTests.swift`

**Interfaces:**
- Consumes: `InboundEvent`, `TaskSnapshot`, `ProjectAdded` (Task 4).
- Produces: `public enum InboundRawFile { static func renderTasks(_:polledAt:) -> String; static func renderProjects(_:polledAt:) -> String; static func fileName(kind: String, at: Date, timeZone: TimeZone = .current) -> String; static func write(_ text: String, kind: String, at: Date, rawDirectory: URL) throws -> URL }`

- [ ] **Step 1: Падающий тест**

```swift
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
```

- [ ] **Step 2: RED** — `swift test --filter InboundRawFileTests`.

- [ ] **Step 3: Реализация**

```swift
import Foundation

/// The files NoHands drops into BigHead's `raw/`. Plain text the BigHead agent reads; never
/// rewritten once written — `raw/` is BigHead's source of truth.
public enum InboundRawFile {
    public static func renderTasks(_ events: [InboundEvent], polledAt: Date) -> String {
        var text = header(kind: "todoist", polledAt: polledAt)
        for event in events {
            let (name, s): (String, TaskSnapshot)
            switch event {
            case .closed(let snapshot): (name, s) = ("closed", snapshot)
            case .deleted(let snapshot): (name, s) = ("deleted", snapshot)
            case .changed(let snapshot): (name, s) = ("changed", snapshot)
            }
            text += "- event: \(name)\n"
            text += field("id", s.id) + field("title", s.title) + field("description", s.description)
            text += field("due", s.due) + field("area", s.area) + field("project", s.project)
            text += field("added_at", s.addedAt) + field("updated_at", s.updatedAt) + "\n"
        }
        return text
    }

    public static func renderProjects(_ projects: [ProjectAdded], polledAt: Date) -> String {
        var text = header(kind: "todoist-project", polledAt: polledAt)
        for project in projects {
            text += "- event: project_added\n" + field("id", project.id) + field("area", project.area)
            text += field("name", project.name) + "\n"
        }
        return text
    }

    public static func fileName(kind: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HHmmss"
        return "\(day)-\(kind)-\(formatter.string(from: date)).md"
    }

    /// A second file in the same second gets `-2`, `-3`…: nothing in `raw/` is ever overwritten.
    public static func write(_ text: String, kind: String, at date: Date, rawDirectory: URL) throws -> URL {
        let base = fileName(kind: kind, at: date)
        var url = rawDirectory.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rawDirectory.appendingPathComponent(base.replacingOccurrences(of: ".md", with: "-\(suffix).md"))
            suffix += 1
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    private static func header(kind: String, polledAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "---\nkind: \(kind)\npolled_at: \(formatter.string(from: polledAt))\n---\n\n"
    }

    private static func field(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return "  \(name): \(value.replacingOccurrences(of: "\n", with: "\n    "))\n"
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter InboundRawFileTests`, затем `swift test`.

- [ ] **Step 5: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: файл событий в raw Башки"`

---

### Task 6: Запуск агента Башки

**Files:**
- Create: `Features/TodoistSync/IngestRunner.swift`
- Test: `Tests/TodoistSyncTests/IngestRunnerTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ProcessRunning: Sendable { func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 }`
  - `public struct SystemProcessRunner: ProcessRunning` (настоящий `Process`, вывод в `/dev/null`, по таймауту `terminate()` и `IngestError.timedOut`)
  - `public enum IngestError: Error, Equatable, LocalizedError { case failed(Int32); case timedOut; case launchFailed(String) }`
  - `public struct IngestRunner: Sendable { init(claude: URL, bighead: URL, runner: any ProcessRunning, timeout: TimeInterval = 600); func ingest(rawFile: String) async throws; static func arguments(rawFile: String) -> [String] }`

- [ ] **Step 1: Падающий тест**

```swift
import Foundation
import os
import Testing
@testable import TodoistSync

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<Int32, any Error>
    private let calls = OSAllocatedUnfairLock(initialState: [(URL, [String], URL, TimeInterval)]())
    init(_ result: Result<Int32, any Error>) { self.result = result }
    var recorded: [(URL, [String], URL, TimeInterval)] { calls.withLock { $0 } }
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 {
        calls.withLock { $0.append((executable, arguments, directory, timeout)) }
        return try result.get()
    }
}

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let bighead = URL(fileURLWithPath: "/tmp/BigHead")

@Test func theAgentIsRunInBigHeadWithFileToolsOnly() async throws {
    let runner = FakeRunner(.success(0))
    try await IngestRunner(claude: claude, bighead: bighead, runner: runner).ingest(rawFile: "raw/2026-10-07-todoist-190640.md")
    let call = try #require(runner.recorded.first)
    #expect(call.0 == claude)
    #expect(call.2 == bighead)
    #expect(call.3 == 600)
    let args = call.1
    #expect(args[0] == "-p")
    #expect(args[1].contains("raw/2026-10-07-todoist-190640.md"))
    #expect(args[1].contains("Todoist → входящие"))
    #expect(Array(args[2...]) == ["--permission-mode", "acceptEdits", "--allowedTools", "Read,Edit,Write,Glob,Grep"])
}

// No Bash: the agent cannot reach NoHands, so applying a Todoist event never echoes back.
@Test func theAgentGetsNoShell() {
    #expect(!IngestRunner.arguments(rawFile: "raw/x.md").joined(separator: " ").contains("Bash"))
}

@Test func aNonZeroExitIsAFailure() async {
    await #expect(throws: IngestError.failed(1)) {
        try await IngestRunner(claude: claude, bighead: bighead, runner: FakeRunner(.success(1))).ingest(rawFile: "raw/x.md")
    }
}

@Test func aTimeoutIsPassedOn() async {
    await #expect(throws: IngestError.timedOut) {
        try await IngestRunner(claude: claude, bighead: bighead, runner: FakeRunner(.failure(IngestError.timedOut))).ingest(rawFile: "raw/x.md")
    }
}

@Test func theSystemRunnerReportsExitCodes() async throws {
    let code = try await SystemProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"],
                                                   directory: FileManager.default.temporaryDirectory, timeout: 5)
    #expect(code == 3)
}

@Test func theSystemRunnerKillsAHungChild() async {
    await #expect(throws: IngestError.timedOut) {
        _ = try await SystemProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                                directory: FileManager.default.temporaryDirectory, timeout: 0.5)
    }
}

@Test func aMissingExecutableIsALaunchFailure() async {
    await #expect(throws: IngestError.self) {
        _ = try await SystemProcessRunner().run(executable: URL(fileURLWithPath: "/nonexistent/claude"), arguments: [],
                                                directory: FileManager.default.temporaryDirectory, timeout: 5)
    }
}
```

- [ ] **Step 2: RED** — `swift test --filter IngestRunnerTests`.

- [ ] **Step 3: Реализация**

```swift
import Foundation

public protocol ProcessRunning: Sendable {
    /// - Returns: the exit code. Throws `IngestError.timedOut` after terminating a child that
    ///   outlived `timeout`, `IngestError.launchFailed` when it could not start.
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32
}

public enum IngestError: Error, Equatable, LocalizedError {
    case failed(Int32)
    case timedOut
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let code): return "BigHead ingest exited with code \(code)"
        case .timedOut: return "BigHead ingest did not finish in time and was stopped"
        case .launchFailed(let reason): return "BigHead ingest could not start: \(reason)"
        }
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Output goes nowhere: a pipe nobody drains fills up and hangs the child.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: IngestError.launchFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global().async {
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                    continuation.resume(throwing: IngestError.timedOut)
                } else {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }
    }
}

/// Runs BigHead's agent on one raw file, with file tools only.
public struct IngestRunner: Sendable {
    private let claude: URL
    private let bighead: URL
    private let runner: any ProcessRunning
    private let timeout: TimeInterval

    public init(claude: URL, bighead: URL, runner: any ProcessRunning, timeout: TimeInterval = 600) {
        self.claude = claude
        self.bighead = bighead
        self.runner = runner
        self.timeout = timeout
    }

    public func ingest(rawFile: String) async throws {
        let code = try await runner.run(executable: claude, arguments: Self.arguments(rawFile: rawFile),
                                        directory: bighead, timeout: timeout)
        guard code == 0 else { throw IngestError.failed(code) }
    }

    /// The prompt goes right after `-p`, before `--allowedTools`, which takes several values.
    static func arguments(rawFile: String) -> [String] {
        ["-p", prompt(rawFile: rawFile), "--permission-mode", "acceptEdits", "--allowedTools", "Read,Edit,Write,Glob,Grep"]
    }

    static func prompt(rawFile: String) -> String {
        """
        Сделай ingest файла \(rawFile) по разделу «Todoist → входящие» в AGENTS.md. \
        Это автоматический запуск из NoHands: вопросов не задавай, в Todoist ничего не отправляй, \
        обработай только этот файл, запиши ingest в wiki/log.md.
        """
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter IngestRunnerTests` (3 раза — тест с таймаутом), затем `swift test`.

- [ ] **Step 5: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: запуск агента Башки на файле событий"`

---

### Task 7: Опрос целиком

**Files:**
- Create: `Features/TodoistSync/InboundPoller.swift`
- Test: `Tests/TodoistSyncTests/InboundPollerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6, `ActionJournal`.
- Produces: `public actor InboundPoller` с `public init(config: TodoistInboundConfig, sync: any TodoistSyncing, store: SyncStateStore, journal: ActionJournal, ingest: IngestRunner, now: @escaping @Sendable () -> Date = Date.init, report: @escaping @Sendable (String?) -> Void)` и `public func tick() async` (не бросает; `report(nil)` — всё хорошо, `report("…")` — причина по-русски для строки статуса).

- [ ] **Step 1: Падающий тест**

```swift
import Foundation
import os
import Testing
@testable import TodoistSync

private actor FakeSync: TodoistSyncing {
    var responses: [Result<SyncResponse, any Error>]
    var tokens: [String] = []
    init(_ responses: [Result<SyncResponse, any Error>]) { self.responses = responses }
    func sync(token: String) async throws -> SyncResponse {
        tokens.append(token)
        return try responses.removeFirst().get()
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String?]())
    func add(_ value: String?) { lock.withLock { $0.append(value) } }
    var all: [String?] { lock.withLock { $0 } }
}

private struct Setup {
    let dir: URL
    let raw: URL
    let store: SyncStateStore
    let journal: ActionJournal
    let runner: RecordingRunner
    let reports = Reports()

    init(exit: Result<Int32, any Error> = .success(0)) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("poll-\(UUID().uuidString)")
        raw = dir.appendingPathComponent("BigHead/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        store = SyncStateStore(url: dir.appendingPathComponent("state.json"))
        journal = ActionJournal(url: dir.appendingPathComponent("journal.jsonl"))
        runner = RecordingRunner(exit)
    }

    func poller(_ sync: FakeSync) -> InboundPoller {
        let config = TodoistInboundConfig(bigheadPath: dir.appendingPathComponent("BigHead").path,
                                          areas: ["Сколково"], claudePath: "/usr/local/bin/claude", pollSeconds: 60)
        return InboundPoller(config: config, sync: sync, store: store, journal: journal,
                             ingest: IngestRunner(claude: URL(fileURLWithPath: config.claudePath),
                                                  bighead: URL(fileURLWithPath: config.bigheadPath), runner: runner),
                             report: { [reports] in reports.add($0) })
    }

    var rawFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []).sorted()
    }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    let result: Result<Int32, any Error>
    private let lock = OSAllocatedUnfairLock(initialState: [[String]]())
    init(_ result: Result<Int32, any Error>) { self.result = result }
    var calls: [[String]] { lock.withLock { $0 } }
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async throws -> Int32 {
        lock.withLock { $0.append(arguments) }
        return try result.get()
    }
}

private let projects = [
    SyncProject(id: "a", name: "Сколково", parentID: nil, isArchived: false, isDeleted: false),
    SyncProject(id: "k", name: "Хибины", parentID: "a", isArchived: false, isDeleted: false),
]
private func closedItem(_ id: String) -> SyncItem {
    SyncItem(id: id, content: "T", description: nil, dueDate: nil, projectID: "k", checked: true, isDeleted: false,
             addedAt: nil, updatedAt: "2026-10-07T15:00:00.000000Z")
}
private let baseline = SyncResponse(syncToken: "t1", fullSync: true, items: [closedItem("old")], projects: projects)

// The very first poll only learns where things are: every existing task would otherwise
// arrive in BigHead as new.
@Test func theFirstPollIsABaselineWithoutEvents() async throws {
    let s = try Setup()
    await s.poller(FakeSync([.success(baseline)])).tick()
    #expect(s.rawFiles.isEmpty)
    #expect(s.runner.calls.isEmpty)
    let state = try await s.store.load()
    #expect(state.syncToken == "t1")
    #expect(state.projects["k"]?.name == "Хибины")
    #expect(s.reports.all == [nil])
}

@Test func changesAreWrittenAndIngested() async throws {
    let s = try Setup()
    let sync = FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [closedItem("1")], projects: []))])
    let poller = s.poller(sync)
    await poller.tick()
    await poller.tick()
    #expect(await sync.tokens == ["*", "t1"])
    #expect(s.rawFiles.count == 1)
    #expect(s.rawFiles[0].contains("-todoist-"))
    #expect(s.runner.calls.count == 1)
    #expect(s.runner.calls[0][1].contains("raw/\(s.rawFiles[0])"))
    #expect(try await s.store.load().syncToken == "t2")
}

@Test func nothingChangedMeansNoFileAndNoIngest() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
    #expect(s.runner.calls.isEmpty)
}

// Todoist resets the token with a full sync: treated as a new baseline, never as news.
@Test func aFullSyncLaterIsAlsoABaseline() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t9", fullSync: true, items: [closedItem("1")], projects: projects))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
    #expect(try await s.store.load().syncToken == "t9")
}

@Test func newProjectsGoToTheirOwnFileWithoutIngest() async throws {
    let s = try Setup()
    let added = SyncProject(id: "n", name: "Новый", parentID: "a", isArchived: false, isDeleted: false)
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: [added]))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    #expect(s.rawFiles[0].contains("-todoist-project-"))
    #expect(s.runner.calls.isEmpty)
}

// The file and the token are kept even when the agent fails: the file stays unprocessed and
// BigHead picks it up in the next conversation.
@Test func aFailedIngestIsReportedAndNothingIsLost() async throws {
    let s = try Setup(exit: .success(1))
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [closedItem("1")], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.count == 1)
    #expect(try await s.store.load().syncToken == "t2")
    #expect(s.reports.all.last??.contains("ingest") == true)
}

@Test func aFailedSyncKeepsTheTokenAndReports() async throws {
    let s = try Setup()
    let poller = s.poller(FakeSync([.success(baseline), .failure(URLError(.notConnectedToInternet)),
                                    .success(SyncResponse(syncToken: "t2", fullSync: false, items: [], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(try await s.store.load().syncToken == "t1")
    #expect(s.reports.all.last! != nil)
    await poller.tick()
    #expect(s.reports.all.last! == nil)
}

@Test func ownChangesNeverReachBigHead() async throws {
    let s = try Setup()
    try await s.journal.record(action: "task.closed", todoistID: "1", name: nil)
    let echo = SyncItem(id: "1", content: "T", description: nil, dueDate: nil, projectID: "k", checked: true, isDeleted: false,
                        addedAt: nil, updatedAt: "2020-01-01T00:00:00.000000Z")
    let poller = s.poller(FakeSync([.success(baseline), .success(SyncResponse(syncToken: "t2", fullSync: false, items: [echo], projects: []))]))
    await poller.tick()
    await poller.tick()
    #expect(s.rawFiles.isEmpty)
}

// A tick that arrives while the previous one is still running is skipped, not queued.
@Test func overlappingTicksDoNotRunTwice() async throws {
    let s = try Setup()
    let sync = FakeSync([.success(baseline), .success(baseline)])
    let poller = s.poller(sync)
    async let first: Void = poller.tick()
    async let second: Void = poller.tick()
    _ = await (first, second)
    #expect(await sync.tokens.count <= 2)
}
```

- [ ] **Step 2: RED** — `swift test --filter InboundPollerTests`.

- [ ] **Step 3: Реализация**

```swift
import Foundation
import os

/// One poll of Todoist per `tick()`: learn what changed, drop what BigHead must not hear,
/// write it into BigHead's `raw/`, and have BigHead's agent ingest it. Never throws: a failure
/// becomes a line for the menu and the next tick tries again.
public actor InboundPoller {
    private static let logger = Logger(subsystem: "com.nohands.app", category: "todoist-inbound")

    private let config: TodoistInboundConfig
    private let sync: any TodoistSyncing
    private let store: SyncStateStore
    private let journal: ActionJournal
    private let ingest: IngestRunner
    private let now: @Sendable () -> Date
    private let report: @Sendable (String?) -> Void
    private var running = false

    public init(config: TodoistInboundConfig, sync: any TodoistSyncing, store: SyncStateStore, journal: ActionJournal,
                ingest: IngestRunner, now: @escaping @Sendable () -> Date = Date.init,
                report: @escaping @Sendable (String?) -> Void) {
        self.config = config
        self.sync = sync
        self.store = store
        self.journal = journal
        self.ingest = ingest
        self.now = now
        self.report = report
    }

    public func tick() async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            try await poll()
            report(nil)
        } catch let error as IngestError {
            report("todoist: ingest не прошёл — \(error.localizedDescription)")
        } catch {
            report("todoist: опрос не прошёл — \(error.localizedDescription)")
        }
    }

    private func poll() async throws {
        let state = try await store.load()
        let response = try await sync.sync(token: state.syncToken ?? "*")

        // A first poll, or Todoist resetting the token: learn the layout, report nothing.
        if state.syncToken == nil || response.fullSync {
            let map = Dictionary(response.projects.filter { !$0.isDeleted }.map {
                ($0.id, ProjectInfo(name: $0.name, parentID: $0.parentID))
            }, uniquingKeysWith: { _, last in last })
            try await store.saveSync(token: response.syncToken, projects: map)
            return
        }

        // An unreadable journal must not stop the poll; without it echoes may slip through,
        // and applying an echo in BigHead changes nothing.
        let entries = (try? await journal.entries()) ?? []
        let batch = InboundEvents.build(response: response, previous: state.projects, areas: config.areas,
                                        ignored: Set(state.ignored), journal: entries)
        let rawDirectory = URL(fileURLWithPath: config.bigheadPath).appendingPathComponent("raw")
        let polledAt = now()

        if !batch.projects.isEmpty {
            _ = try InboundRawFile.write(InboundRawFile.renderProjects(batch.projects, polledAt: polledAt),
                                         kind: "todoist-project", at: polledAt, rawDirectory: rawDirectory)
        }
        var taskFile: URL?
        if !batch.tasks.isEmpty {
            taskFile = try InboundRawFile.write(InboundRawFile.renderTasks(batch.tasks, polledAt: polledAt),
                                                kind: "todoist", at: polledAt, rawDirectory: rawDirectory)
        }
        // Saved before the agent runs: a crash during ingest must not fetch the same changes
        // again and write them twice.
        try await store.saveSync(token: response.syncToken, projects: batch.projectMap)
        Self.logger.info("todoist poll: \(batch.tasks.count, privacy: .public) task events, \(batch.projects.count, privacy: .public) new projects")

        if let taskFile {
            try await ingest.ingest(rawFile: "raw/\(taskFile.lastPathComponent)")
        }
    }
}
```

- [ ] **Step 4: GREEN** — `swift test --filter InboundPollerTests` (3 раза), затем `swift test`.

- [ ] **Step 5: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests && git commit -m "Todoist: опрос — события в raw Башки и её ingest"`

---

### Task 8: Отклонение проекта и подключение в приложении

**Files:**
- Modify: `Features/TodoistSync/TodoistOperations.swift` (`ignoreProject`, хранилище отклонённых)
- Modify: `Features/TodoistSync/TodoistEndpoint.swift` (маршрут `POST /projects/ignore`)
- Modify: `App/AppDelegate.swift` (хранилище, опрос, таймер, строка статуса)
- Test: `Tests/TodoistSyncTests/TodoistOperationsTests.swift`, `Tests/TodoistSyncTests/TodoistEndpointTests.swift`

**Interfaces:**
- Consumes: `IgnoredProjectsStore`, `SyncStateStore` (Task 3), `InboundPoller` (Task 7), `TodoistInboundConfig` (Task 1).
- Produces:
  - `TodoistOperating.ignoreProject(_ request: ProjectRequest) async throws -> String` (возвращает `id`)
  - `TodoistOperations.init(api:journal:ignoredStore:)` с `ignoredStore: (any IgnoredProjectsStore)? = nil`
  - маршрут `POST /projects/ignore` → `200 {"id": …}`; проекта нет → `404`; хранилища нет → `500`

- [ ] **Step 1: Падающие тесты**

В `TodoistOperationsTests.swift`:

```swift
private actor RecordingIgnored: IgnoredProjectsStore {
    var ids: [String] = []
    func ignore(projectID: String) async throws { ids.append(projectID) }
}

@Test func ignoringAProjectRemembersItsId() async throws {
    let store = RecordingIgnored()
    let id = try await TodoistOperations(api: FakeAccount([skolkovo, khibiny]), journal: journal(), ignoredStore: store)
        .ignoreProject(ProjectRequest(area: "Сколково", project: "Хибины"))
    #expect(id == "b")
    #expect(await store.ids == ["b"])
}

@Test func ignoringAnUnknownProjectIsProjectNotFound() async {
    await #expect(throws: OperationError.projectNotFound("Нет")) {
        _ = try await TodoistOperations(api: FakeAccount([skolkovo]), journal: journal(), ignoredStore: RecordingIgnored())
            .ignoreProject(ProjectRequest(area: "Сколково", project: "Нет"))
    }
}
```

В `TodoistEndpointTests.swift` добавить в `FakeOperations`:

```swift
    func ignoreProject(_ request: ProjectRequest) async throws -> String {
        try record("ignore \(request.area)/\(request.project)")
        return "p7"
    }
```

и тест:

```swift
@Test func ignoreRoutes() async throws {
    let fake = FakeOperations()
    let response = await TodoistEndpoint(operations: fake).respond(method: "POST", path: "/projects/ignore", body: projectBody)
    #expect(response.status == 200)
    #expect(try object(response)["id"] as? String == "p7")
    #expect(await fake.calls == ["ignore RooX/ИНДИД"])
}
```

- [ ] **Step 2: RED** — `swift test --filter TodoistSyncTests`.

- [ ] **Step 3: Операция**

В `TodoistOperations.swift`:

- в протокол `TodoistOperating`: `func ignoreProject(_ request: ProjectRequest) async throws -> String`;
- свойство `private let ignoredStore: (any IgnoredProjectsStore)?`, параметр `ignoredStore: (any IgnoredProjectsStore)? = nil` в `init`;
- метод:

```swift
    public func ignoreProject(_ request: ProjectRequest) async throws -> String {
        try await enqueue { try await self.performIgnore(request) }
    }

    private func performIgnore(_ request: ProjectRequest) async throws -> String {
        guard let ignoredStore else { throw OperationError.ignoreUnavailable }
        let active = try await api.projects()
        guard let area = try Self.find(request.area, parentID: nil, in: active) else {
            throw OperationError.projectNotFound(request.area)
        }
        guard let project = try Self.find(request.project, parentID: area.id, in: active) else {
            throw OperationError.projectNotFound(request.project)
        }
        try await ignoredStore.ignore(projectID: project.id)
        return project.id
    }
```

- в `OperationError`: `case ignoreUnavailable` с описанием `"Declined projects cannot be stored: the inbound sync is not set up"`.

В `TodoistEndpoint.swift`:
- `Route.ignoreProject`;
- в `resolve`: `case 2 where parts[0] == "projects" && parts[1] == "ignore": return allow("POST", .ignoreProject)`;
- в `handle`: `case .ignoreProject: return .json(200, ["id": try await operations.ignoreProject(try ProjectRequest.decode(body))])`;
- в `failure`: `OperationError.ignoreUnavailable` → `500`, остальные `OperationError` — как были (`404`). Для этого в ветке `OperationError` сначала проверить `.ignoreUnavailable`.

- [ ] **Step 4: Подключение в `AppDelegate`**

Свойства:

```swift
    /// The poll of Todoist for changes made there. Built once with the server; nil when the
    /// `todoist` section of the config is incomplete.
    private var inboundPoller: InboundPoller?
    private var inboundTimer: Timer?
    /// Why changes in Todoist are not reaching BigHead, for the status line. Nil when they are.
    private var todoistInboundNote: String?
    /// The dictation half of the status line, kept so the inbound note can refresh it alone.
    private var dictationStatus = "Загружаю модель…"
```

В `startTodoistSync()`:
- создать `let stateStore = SyncStateStore(url: SyncStateStore.defaultURL)`;
- передать в операции: `TodoistOperations(api: todoistClient, journal: journal, ignoredStore: stateStore)`, где `journal` — тот же `ActionJournal(url: ActionJournal.defaultURL)` (вынести в локальную переменную);
- после успешного старта сервера вызвать `startInbound(store: stateStore, journal: journal)`.

Новый метод:

```swift
    private func startInbound(store: SyncStateStore, journal: ActionJournal) {
        let config: TodoistInboundConfig
        do {
            config = try TodoistInboundConfig.loadOrCreate()
        } catch {
            todoistInboundNote = "todoist-входящие: \(error.localizedDescription)"
            return
        }
        guard config.isComplete else {
            todoistInboundNote = "todoist-входящие: не настроены (раздел todoist в config.json)"
            return
        }
        let poller = InboundPoller(
            config: config,
            sync: todoistClient,
            store: store,
            journal: journal,
            ingest: IngestRunner(claude: URL(fileURLWithPath: config.claudePath),
                                 bighead: URL(fileURLWithPath: config.bigheadPath),
                                 runner: SystemProcessRunner()),
            report: { [weak self] note in
                Task { @MainActor in
                    self?.todoistInboundNote = note
                    self?.refreshStatus()
                }
            }
        )
        inboundPoller = poller
        inboundTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: config.pollSeconds, repeats: true) { _ in
            Task { await poller.tick() }
        }
        // `.common`: a default-mode timer stops while the menu is open — see the sweep timer.
        RunLoop.main.add(timer, forMode: .common)
        inboundTimer = timer
        Task { await poller.tick() }
    }

    private func refreshStatus() {
        statusMenu?.setStatus(Self.status(dictationStatus, meetingsNote, todoistNote, todoistInboundNote))
    }
```

Если `meetingsNote` не хранится в свойстве (сейчас он локальная переменная `startBuild`), завести свойство `private var meetingsNote: String?`, присваивать его там, где он вычисляется, и использовать в `refreshStatus`. В `buildCoordinator` заменить прямые `menu.setStatus(Self.status(…))` на присваивание `dictationStatus` («Готов» / текст ошибки / «Загружаю модель…») и вызов `refreshStatus()`.

- [ ] **Step 5: GREEN** — `swift build` (без новых предупреждений), `swift test --filter TodoistSyncTests`, затем `swift test`.

- [ ] **Step 6: Коммит** — `git add -A Features/TodoistSync Tests/TodoistSyncTests App/AppDelegate.swift && git commit -m "Todoist: отклонение проекта и опрос Todoist в приложении"`

---

### Task 9: Настройка, установка, живая проверка, схема Башки (контроллер)

- [ ] **Step 1: Раздел `todoist` в настоящем `config.json`** — `bigheadPath` `/Users/macintosh/BigHead`, `areas` из таблицы областей `AGENTS.md`, `claudePath` из `which claude`, `pollSeconds` 60. Остальные ключи файла не трогать.
- [ ] **Step 2: Схема Башки** — раздел «Todoist → входящие» в `AGENTS.md` по §3.8 спеки, вид `todoist`/`todoist-project` в списке видов raw, правило «новая область → строка в `areas` NoHands», запись `schema` в log.
- [ ] **Step 3: Установка** — `./Scripts/make-app.sh`, при `-600` — `open /Applications/NoHands.app`; `curl -sS http://127.0.0.1:41730/health`.
- [ ] **Step 4: Живая проверка** по §5.2 спеки. Каждое наблюдение — факт в отчёт; расхождение — в `docs/DECISIONS.md` и исправление тем же порядком (тест → код → ревью).
