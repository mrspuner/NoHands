# Созвоны → Башка: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** готовый созвон из `~/Meetings` сам уходит агенту Башки через `claude -p`, в одной последовательной очереди с ingest Todoist.

**Architecture:** запуск процесса и последовательная очередь агентов переезжают из `TodoistSync` в `Core/BigHead/`: `SystemProcessRunner` разбирает `--output-format json`, `BigHeadAgent` выполняет запуски по одному. Новый актор `MeetingIngest` в `Features/Meetings` после каждого круга `ArchivePasses` выбирает файлы с саммари и ставит их агенту, а своё состояние хранит в `meeting-ingest-state.json`. `AppDelegate` держит один `BigHeadAgent` на оба потребителя.

**Tech Stack:** Swift 6.2, Swift Testing (`@Test`, `#expect`), Foundation `Process`, `os.Logger`.

**Spec:** `docs/superpowers/specs/2026-10-19-meeting-ingest-design.md`

## Global Constraints

- Новых зависимостей SPM нет. CLI получает зависимость от таргета `TodoistSync` из этого же пакета.
- Идентификаторы, комментарии в коде и сообщения об ошибках (`errorDescription`) — по-английски. Текст панели и строки состояния меню — по-русски, как у соседних `PanelNotice`.
- Поле `result` из JSON агента не декодируется, не хранится и не логируется. Stdout разбирается только на `is_error` и `terminal_reason`.
- В лог (`os.Logger`, subsystem `com.nohands.app`) попадают только имя файла, код выхода, длительность, а при сбое ещё `terminal_reason` и первая строка stderr.
- Системных уведомлений нет: сбой показывается через `PanelNotice` на панели.
- Команда агента созвона ровно такая, по порядку: `-p <prompt> --restricted --strict-mcp-config --tools Read,Edit,Write,Glob,Grep,ListAgents,SendMessage --add-dir <meetings> --permission-mode acceptEdits --output-format json`.
- Промпт агента созвона: `Обработай созвон <абсолютный путь к файлу> по разделу «Созвоны → входящие» в AGENTS.md.`
- Умолчания: `ingestEnabled: true`, `ingestTimeoutSeconds: 900`. Таймаут Todoist остаётся 600.
- Лимиты буферов: stdout — 1 МБ, первая строка stderr — 200 символов.

## Review Focus

1. Файл состояния есть, но испорчен: ничего не ставится в очередь, файл не перезаписывается, на панели сбой. Тест в задаче 5.
2. Агент печатает в stdout больше 1 МБ: процесс не виснет, итог считается неразобранным, это сбой. Тест в задаче 1.
3. `scan()` вызывается несколько раз подряд, пока идёт запуск: ни один файл не ставится в очередь дважды. Тест в задаче 6.
4. В `~/Meetings` лежит посторонняя заметка с именем без даты, или созвон, удалённый между постановкой в очередь и запуском: заметка молча пропускается, удалённый файл не запускается и не помечается переданным. Тесты в задаче 6.
5. PID-файл от прошлого сеанса указывает на номер, который уже занял другой процесс: этот процесс не трогается. Тест в задаче 2.

---

### Task 1: Запуск процесса с разбором JSON, в `Core`

**Files:**
- Create: `Core/BigHead/AgentProcess.swift`
- Delete from: `Features/TodoistSync/IngestRunner.swift` (`ProcessRunning`, `SystemProcessRunner`, `IngestError`)
- Test: `Tests/CoreTests/AgentProcessTests.swift`; перенести `theSystemRunner*` и `aMissingExecutableIsALaunchFailure` из `Tests/TodoistSyncTests/IngestRunnerTests.swift`

**Interfaces:**
- Produces:
  - `public struct AgentRun: Equatable, Sendable { public var exitCode: Int32; public var result: AgentResult?; public var stderrLine: String? }`. `result == nil` значит, что stdout не разобран.
  - `public struct AgentResult: Equatable, Sendable, Decodable { public var isError: Bool; public var terminalReason: String? }` с ключами `is_error` и `terminal_reason`. Других полей у типа нет. `static func parse(_ stdout: Data) -> AgentResult?`.
  - `public enum AgentLaunchError: Error, Equatable { case timedOut, launchFailed(String) }`.
  - `public protocol ProcessRunning: Sendable { func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval, pidFile: URL?) async throws -> AgentRun }`.
  - `public struct SystemProcessRunner: ProcessRunning`.

- [ ] **Step 1: Тесты**
  - `aResultIsParsedFromJSON`: `AgentResult.parse` от `{"type":"result","is_error":true,"terminal_reason":"api_error","result":"Not logged in · Please run /login"}` возвращает `AgentResult(isError: true, terminalReason: "api_error")`.
  - `garbageIsNotAResult`: `parse(Data("Not logged in".utf8)) == nil`.
  - `theRunnerReadsStdoutAndStderr`: `/bin/sh -c 'echo "{\"is_error\":false}"; echo "boom" >&2; echo "second" >&2; exit 2'` даёт `exitCode == 2`, `result == AgentResult(isError: false, terminalReason: nil)`, `stderrLine == "boom"`.
  - `hugeStdoutDoesNotHangAndIsUnparsed`: `/bin/sh -c 'head -c 3000000 /dev/zero | tr "\\0" a'` с таймаутом 10 даёт `exitCode == 0` и `result == nil`.
  - `aLongStderrLineIsCut`: строка stderr из 500 символов `x` возвращается длиной 200.
  - `thePIDFileExistsOnlyWhileRunning`: `/bin/sh -c 'cat "$0"' <pidFile>` печатает PID, совпадающий с PID процесса, а после возврата файла нет.
  - Перенесённые: код выхода 3, `sleep 30` при таймауте 0.5 даёт `AgentLaunchError.timedOut`, несуществующий исполняемый файл даёт `.launchFailed`.
- [ ] **Step 2: Прогон** — `swift test --filter AgentProcessTests` падает: типов нет.
- [ ] **Step 3: Реализация.** Логика таймаута и убийства процесса переносится из нынешнего `SystemProcessRunner` как есть. Stdout и stderr идут в `Pipe`, каждый читается до EOF в своём потоке, `readabilityHandler` или `DispatchQueue.global`. Stdout копится до 1 МБ; всё сверх лимита читается и выбрасывается, а флаг переполнения делает `result = nil`. От stderr сохраняется только первая непустая строка, обрезанная до 200 символов. Возврат происходит после завершения процесса и EOF обоих pipe. PID пишется в `pidFile` сразу после `process.run()` и удаляется перед возвратом на всех путях.
- [ ] **Step 4: Прогон** — `swift test --filter AgentProcessTests` проходит.
- [ ] **Step 5: Commit** — «BigHead: запуск агента разбирает итоговый JSON».

### Task 2: Последовательная очередь агентов и остаток прошлого сеанса

**Files:**
- Create: `Core/BigHead/BigHeadAgent.swift`
- Test: `Tests/CoreTests/BigHeadAgentTests.swift`

**Interfaces:**
- Consumes: `ProcessRunning`, `AgentRun`, `AgentLaunchError` (задача 1).
- Produces:
  - `public enum AgentFailure: Error, Equatable, LocalizedError { case exitCode(Int32), agentError(String), unreadableResult, timedOut(TimeInterval), launchFailed(String) }`. Это ошибка по-английски. `agentError` несёт `terminal_reason`, а при его отсутствии `"unknown"`.
  - `public struct AgentReport: Equatable, Sendable { public var failure: AgentFailure?; public var exitCode: Int32?; public var stderrLine: String?; public var duration: TimeInterval }`.
  - `public actor BigHeadAgent { public static var defaultPIDFile: URL; public init(runner: any ProcessRunning, pidFile: URL? = BigHeadAgent.defaultPIDFile, clock: @Sendable () -> Date = Date.init); public func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval) async -> AgentReport }`.
  - `public enum LeftoverAgent { public static func stop(pidFile: URL, isAgent: (pid_t) -> Bool = LeftoverAgent.isClaude) }`.
  - `defaultPIDFile` = `~/Library/Application Support/NoHands/bighead-agent.pid`.

- [ ] **Step 1: Тесты**
  - `runsNeverOverlap`: фейковый runner спит 50 мс и считает максимум одновременных вызовов. Пять параллельных `run` дают максимум 1, и вызовы идут в порядке поступления.
  - Классификация, по одному тесту на правило:
    - код 0 и `AgentResult(isError: false)` дают `failure == nil`;
    - код 1 даёт `.exitCode(1)`;
    - код 0 и `isError: true, terminalReason: "api_error"` дают `.agentError("api_error")`;
    - код 0 и `result == nil` дают `.unreadableResult`;
    - выброшенный `.timedOut` при таймауте 900 даёт `.timedOut(900)`;
    - `.launchFailed("x")` даёт `.launchFailed("x")`.
    Ненулевой код важнее `is_error`.
  - `leftoverIsStoppedOnlyWhenItIsTheAgent`: запустить `/bin/sleep 30` и записать его PID в файл. `stop(isAgent: { _ in false })` процесс не трогает, `stop(isAgent: { _ in true })` его гасит, и файла после этого нет.
  - `aMissingPIDFileIsNothingToStop`: вызов без файла не падает.
- [ ] **Step 2: Прогон** — `swift test --filter BigHeadAgentTests` падает.
- [ ] **Step 3: Реализация.** Порядок держит цепочка задач: актор хранит `tail: Task<Void, Never>?`, каждый `run` ставит новую задачу, ждущую предыдущую. Причина: actor reentrancy, одного `await` внутри метода актора мало. `LeftoverAgent.isClaude` сравнивает `proc_pidpath` с последним компонентом `claude`. Остановка по образцу таймаута: `SIGTERM`, через две секунды `SIGKILL`.
- [ ] **Step 4: Прогон** — проходит.
- [ ] **Step 5: Commit** — «BigHead: один агент за раз на всё приложение».

### Task 3: Ingest Todoist через общую очередь

**Files:**
- Modify: `Features/TodoistSync/IngestRunner.swift`, `Features/TodoistSync/InboundPoller.swift`
- Test: `Tests/TodoistSyncTests/IngestRunnerTests.swift`, `Tests/TodoistSyncTests/InboundPollerTests.swift`

**Interfaces:**
- Consumes: `BigHeadAgent`, `AgentReport`, `AgentFailure` (задача 2).
- Produces: `public init(claude: URL, bighead: URL, agent: BigHeadAgent, timeout: TimeInterval = 600)` и `public func ingest(rawFile: String) async throws`, который бросает `AgentFailure`. У `InboundPoller.update(config:)` собирается новый `IngestRunner` с тем же `agent` и `timeout`.

- [ ] **Step 1: Тесты.** В `theAgentIsRunInBigHeadWithFileToolsOnly` хвост аргументов становится `["--restricted", "--strict-mcp-config", "--permission-mode", "acceptEdits", "--tools", "Read,Edit,Write,Glob,Grep", "--output-format", "json"]`. Новый тест `anAgentErrorWithZeroExitIsAFailure`: фейковый runner возвращает `AgentRun(exitCode: 0, result: .init(isError: true, terminalReason: "api_error"), stderrLine: nil)`, и ожидается `AgentFailure.agentError("api_error")`. Фейки в обоих файлах переходят на новую сигнатуру `ProcessRunning` и оборачиваются в `BigHeadAgent(runner:, pidFile: nil)`.
- [ ] **Step 2: Прогон** — `swift test --filter TodoistSyncTests` падает.
- [ ] **Step 3: Реализация.** `catch let error as AgentFailure` в `InboundPoller.tick` логирует `error.localizedDescription` (по-английски, без содержимого), а строка меню остаётся прежней: «todoist: ingest не прошёл — …».
- [ ] **Step 4: Прогон** — `swift test --filter TodoistSyncTests` проходит.
- [ ] **Step 5: Commit** — «Todoist: ingest идёт через общую очередь агентов Башки».

### Task 4: Настройки созвонов

**Files:**
- Modify: `Features/Meetings/MeetingsConfig.swift`
- Test: `Tests/MeetingsTests/MeetingsConfigTests.swift`

**Interfaces:**
- Produces: `MeetingsConfig.ingestEnabled: Bool` (по умолчанию `true`) и `MeetingsConfig.ingestTimeoutSeconds: Double` (по умолчанию `900`). Оба есть в `default`, в `init` с умолчаниями и в декодере через `decodeIfPresent ?? fallback`, как у `summaryEnabled`.

- [ ] **Step 1: Тест** `ingestDefaultsWhenAbsent`: секция без новых ключей даёт `true` и `900`. Тест `ingestKeysAreRead`: `{"ingestEnabled": false, "ingestTimeoutSeconds": 60}` даёт `false` и `60`.
- [ ] **Step 2–4:** прогон падает, реализация, прогон проходит (`swift test --filter MeetingsConfigTests`).
- [ ] **Step 5: Commit** — «Созвоны: настройки передачи в Башку».

### Task 5: Состояние передачи

**Files:**
- Create: `Features/Meetings/MeetingIngestStore.swift`
- Test: `Tests/MeetingsTests/MeetingIngestStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct MeetingIngestState: Codable, Equatable, Sendable { public var enabledAt: Date; public var handedOver: [String] }`. Даты кодируются в ISO 8601.
  - `public actor MeetingIngestStore { public static var defaultURL: URL; public init(url: URL, now: @Sendable () -> Date = Date.init); public func load() throws -> MeetingIngestState; public func markHandedOver(_ name: String) throws }`.
  - `defaultURL` = `~/Library/Application Support/NoHands/meeting-ingest-state.json`.

- [ ] **Step 1: Тесты**
  - `aMissingFileStartsTodayAndIsSaved`: `load()` без файла даёт `enabledAt == now`, `handedOver == []`, и файл после этого существует.
  - `enabledAtNeverMoves`: повторный `load()` с другим `now` возвращает первую дату.
  - `markedNamesPersist`: после `markHandedOver("a.md")` новый экземпляр хранилища видит `["a.md"]`. Повторная пометка не дублирует имя.
  - `aCorruptFileThrowsAndIsLeftAlone`: файл `"{"` — `load()` бросает, и содержимое файла после этого побайтово прежнее.
- [ ] **Step 2–4:** прогон падает, реализация (атомарная запись, `sortedKeys`, `prettyPrinted`), прогон проходит.
- [ ] **Step 5: Commit** — «Созвоны: состояние передачи в Башку».

### Task 6: Отбор и передача созвонов

**Files:**
- Create: `Features/Meetings/MeetingIngest.swift`
- Modify: `Features/Meetings/PanelNotice.swift` (добавить `forIngest`)
- Test: `Tests/MeetingsTests/MeetingIngestTests.swift`, `Tests/MeetingsTests/PanelNoticeTests.swift`

**Interfaces:**
- Consumes: `BigHeadAgent`, `AgentReport`, `AgentFailure` (задача 2), `MeetingIngestStore` (задача 5), `TranscriptIndex.hasHeading`, `SummaryInsertion.hasSummary`.
- Produces:
  - `public struct MeetingIngest.Settings: Equatable, Sendable { public var claude: URL; public var bighead: URL; public var timeout: TimeInterval }`.
  - `public struct MeetingIngest.Outcome: Equatable, Sendable { public var file: String; public var failure: AgentFailure? }`. Сюда же попадает сбой чтения состояния: для него `file == ""`, а `failure == .launchFailed(<описание>)`.
  - `public actor MeetingIngest`. Инициализатор: `init(archive: URL = MeetingFolder.archiveURL, store: MeetingIngestStore, agent: BigHeadAgent, settings: Settings?, report: @escaping @Sendable (Outcome) -> Void)`. При `settings == nil` функция выключена.
  - Методы: `func update(settings: Settings?)`, `func clearFailures()`, `func scan() async` (ставит в очередь и возвращается, не дожидаясь агента), `func waitUntilIdle() async` (для тестов и CLI).
  - `static func arguments(file: URL, meetings: URL) -> [String]` возвращает ровно команду из Global Constraints.
  - `static func timestamp(ofName: String) -> Date?` читает префикс `yyyy-MM-dd-HHmm` в локальном поясе, без префикса возвращает `nil`.
  - `public static func forIngest(_ outcome: MeetingIngest.Outcome) -> PanelNotice?` в `PanelNotice`. Успех даёт `nil`. Сбой даёт `"Созвон \(file) не обработан: \(reason)"`, `isFailure: true`, где reason соответственно: «код выхода N», «не уложился в N мин» (`Int(seconds / 60)`), «ошибка claude: X», «непонятный ответ claude», «не запустился: X». Сбой состояния (`file == ""`) даёт `"Созвоны → Башка: \(reason)"`.

- [ ] **Step 1: Тесты в `MeetingIngestTests`.** Фикстура: временный архив, файл с заголовком транскрипта и `## Саммари`, хранилище с `now` из прошлого. Фейковый runner записывает аргументы и возвращает заданный `AgentRun`.
  - `aSummarizedMeetingIsHandedOverOnce`: `scan`, `waitUntilIdle` — один вызов с `arguments(file:meetings:)`, рабочая папка `bighead`, имя файла в `handedOver`. Повторные `scan` и `waitUntilIdle` новых вызовов не дают.
  - `filesWithoutSummaryOrHeadingAreSkipped`: файл без `## Саммари` и заметка без заголовка не запускаются.
  - `meetingsBeforeEnabledAtAreSkipped`: `enabledAt` = 2026-10-19 12:00 локального времени. `2026-10-19-1130-zoom.md` не передаётся, `2026-10-19-1200-zoom.md` передаётся, `notes.md` без даты не передаётся.
  - `oldestFirst`: три файла передаются в порядке имён.
  - `repeatedScansDoNotDuplicate`: агент блокирован до сигнала, `scan()` вызывается три раза, после отпускания каждый файл запущен ровно один раз.
  - `aFailureIsReportedNotMarkedAndNotRetriedThisSession`: код 1 даёт `Outcome(file:, failure: .exitCode(1))`, имени нет в `handedOver`, следующий `scan` файл не запускает. После `clearFailures()` и `scan` файл запускается снова.
  - `aFailureDoesNotStopTheRest`: первый файл падает, второй передаётся.
  - `aFileGoneBeforeItsTurnIsNotRun`: файл удалён после `scan`, пока агент занят предыдущим, — запуска и пометки нет.
  - `aCorruptStateReportsAndRunsNothing`: испорченный файл состояния даёт один `Outcome` с `file == ""`, ноль запусков.
  - `nilSettingsRunNothing`: `settings == nil` — ноль запусков.
  - `theCommandIsExactlyTheSpecOne`: `arguments(file: /Users/x/Meetings/a.md, meetings: /Users/x/Meetings)` равен массиву из Global Constraints. Bash в строке аргументов отсутствует.
- [ ] **Step 2: Тесты в `PanelNoticeTests`:** по одному на каждую причину `forIngest` и `forIngest(success) == nil`.
- [ ] **Step 3: Прогон** — `swift test --filter "MeetingIngestTests|PanelNoticeTests"` падает.
- [ ] **Step 4: Реализация.** Очередь — массив имён плюс множества `queued`, `failed` (на сеанс) и `running`. Один рабочий `Task` разбирает очередь, пока она не пуста. Перед каждым запуском он проверяет, что файл существует, и снимает снимок `settings`. После запуска пишет лог: `Logger(subsystem: "com.nohands.app", category: "meeting-ingest")` — имя, код, длительность, при сбое `terminal_reason` и `stderrLine`, всё `privacy: .public`. Затем помечает файл или добавляет его в `failed` и вызывает `report`.
- [ ] **Step 5: Прогон** — проходит.
- [ ] **Step 6: Commit** — «Созвоны: готовый созвон уходит агенту Башки».

### Task 7: Проход передачи после каждого круга архива

**Files:**
- Modify: `Features/Meetings/ArchivePasses.swift`
- Test: `Tests/MeetingsTests/ArchivePassesTests.swift`

**Interfaces:**
- Consumes: `MeetingIngest.scan()` (задача 6).
- Produces: `public init(summarizer: MeetingSummarizer, naming: SpeakerNaming, afterRound: @escaping @Sendable () async -> Void = {})`. `afterRound` вызывается в конце каждого круга, после `naming.scanArchive()`.

- [ ] **Step 1: Тест** `afterRoundRunsAfterBothPasses`: по образцу существующих тестов файла `afterRound` вызывается после обоих проходов и один раз на круг.
- [ ] **Step 2–4:** прогон падает, реализация, прогон проходит (`swift test --filter ArchivePassesTests`).
- [ ] **Step 5: Commit** — «Созвоны: проход передачи после конспекта и имён».

### Task 8: Подключение в приложении

**Files:**
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: всё выше.

- [ ] **Step 1: Реализация.**
  - Поле `private let bigHeadAgent = BigHeadAgent(runner: SystemProcessRunner())`.
  - В `applicationDidFinishLaunching` до `startBuild` вызвать `LeftoverAgent.stop(pidFile: BigHeadAgent.defaultPIDFile)`.
  - `startInbound` передаёт в `IngestRunner` агент `bigHeadAgent`.
  - В `rebuildMeetings` из `MeetingsConfig` и `TodoistInboundConfig.loadOrCreate()` собираются `Settings`: `nil`, если `!ingestEnabled` или пуст `claudePath` либо `bigheadPath`. `MeetingIngest` создаётся один раз, как `meetingSummarizer`, а при перечитывании конфига получает `update(settings:)` и `clearFailures()`.
  - `report` показывает `PanelNotice.forIngest`, если он не `nil`, тем же способом, что `forSummary`. `ArchivePasses` получает `afterRound: { await ingest.scan() }`.
  - Если `ingestEnabled`, но пути пусты, `rebuildMeetings` возвращает примечание «созвоны → Башка: не настроены (claudePath, bigheadPath в разделе todoist)». Приоритет у других ошибок `rebuildMeetings`, примечание идёт, только если их нет.
- [ ] **Step 2: Сборка и все тесты** — `swift build && swift test` без ошибок.
- [ ] **Step 3: Commit** — «Приложение: созвоны и Todoist делят одного агента Башки».

### Task 9: Команда CLI для ручной проверки

**Files:**
- Modify: `Package.swift` (CLI получает `"TodoistSync"`), `CLI/MeetingArguments.swift`, `CLI/MeetingCommands.swift`, `CLI/NoHands.swift` (usage и switch)
- Test: тесты разбора в `Tests/CLITests/` по образцу существующих для `MeetingArguments`

**Interfaces:**
- Produces: подкоманда `ingest` в `MeetingArguments.Subcommand`, `func runMeetingIngest(_ file: URL) async`.

- [ ] **Step 1: Тест разбора** `ingestParses`: `["meeting", "ingest", "/x/a.md"]` даёт `.ingest` и путь.
- [ ] **Step 2–3:** прогон падает, реализация. `runMeetingIngest` читает `TodoistInboundConfig.loadOrCreate()` и `MeetingsConfig.loadOrCreate()`. Он запускает `BigHeadAgent(runner: SystemProcessRunner(), pidFile: nil).run(...)` с `MeetingIngest.arguments(file:meetings: MeetingFolder.archiveURL)`, не трогая состояние. Печатает код выхода, длительность и, при сбое, причину с первой строкой stderr. Выход 1 при сбое.
- [ ] **Step 4: Прогон** — `swift test --filter CLITests` проходит.
- [ ] **Step 5: Commit** — «CLI: ручная передача созвона в Башку».

### Task 10: Живая проверка

- [ ] **Step 1:** `swift run nohands meeting ingest ~/Meetings/<уже обработанный файл>.md` — код 0, и `git -C ~/BigHead status` не показывает изменений (или агент сообщает, что файл уже есть в `wiki/log.md`).
- [ ] **Step 2:** `Scripts/make-app.sh`. Приложение стартует, в `meeting-ingest-state.json` записан `enabledAt`, старые созвоны не запускаются (`log show --predicate 'category == "meeting-ingest"' --last 10m` пуст).
- [ ] **Step 3:** неверный `claudePath`, «Перечитать конфиг», ручной `scan` через тестовый созвон или копию с сегодняшним временем в имени — на панели «Созвон … не обработан: не запустился: …», в `handedOver` имени нет.
- [ ] **Step 4:** тестовый созвон владельца: выжимка в «Башка · входящие», запись в `~/BigHead/wiki/inbox.md`, имя в `handedOver`.
- [ ] **Step 5:** запись в `docs/DECISIONS.md` по итогам живой проверки, если она что-то опровергла.
