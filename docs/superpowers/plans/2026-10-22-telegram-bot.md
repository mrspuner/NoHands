# Телеграм-бот Башки: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** NoHands доставляет владельцу в Телеграм всё новое из `~/BigHead/wiki/inbox.md` и ответы агента. Любая реплика владельца в бот уходит агенту Башки, итог возвращается в тот же чат.

**Architecture:** новый модуль `Features/Telegram` (таргет `Telegram`, зависит только от `Core`). Чистые части:
- разбор inbox на пункты;
- разбор файлов outbox;
- перевод markdown в HTML Телеграма с нарезкой;
- состояние в `telegram-state.json`.

Актор `TelegramBot` держит два цикла:
- long polling `getUpdates`;
- раз в 3 с проход по inbox и outbox с отправкой.

Реплики владельца копятся в `ReplyAgent`, который запускает агента через общий `BigHeadAgent`. `AppDelegate` собирает всё это и показывает сбои на панели.

**Tech Stack:** Swift 6.2, Swift Testing (`@Test`, `#expect`), `URLSession`, Foundation `Process` (через `BigHeadAgent`), `os.Logger`.

**Spec:** `docs/superpowers/specs/2026-10-21-telegram-bot-design.md`

## Global Constraints

- Новых зависимостей SPM нет. Bot API — прямые HTTPS-запросы через `URLSession`.
- Идентификаторы, комментарии и `errorDescription` — по-английски. Текст в чат, на панели и в строке состояния меню — по-русски.
- Текст сообщений (входящих и исходящих) и текст реплик не логируется. `os.Logger`: subsystem `com.nohands.app`, category `telegram`. Пишутся только направление (`in`/`out`), `ref`, длина, исход.
- Сообщения от любого `from.id`, кроме `ownerUserId`, отбрасываются: агент не запускается, ответа нет, текст не логируется.
- Состояние — `~/Library/Application Support/NoHands/telegram-state.json`. Outbox — `~/Library/Application Support/NoHands/telegram-outbox/`. Файлы реплик — `~/Library/Application Support/NoHands/telegram-replies/`.
- Конфиг — секция `telegram` в `config.json`: `enabled` (по умолчанию `false`), `ownerUserId` (по умолчанию нет), `replyTimeoutSeconds` (по умолчанию `900`).
- Токен — в Keychain: service `nohands-telegram`, account `bot-token`. Кладётся руками через `security add-generic-password`, как остальные ключи: `Keychain` в проекте только читает. Это расхождение со спекой («из окна настроек или CLI»), его фиксирует задача 11.
- Лимит сообщения Телеграма — 4096 символов на часть. Long polling — `timeout=50`. Проход по inbox и outbox — раз в 3 с. Блок inbox считается дописанным, если `inbox.md` не менялся 5 с.
- Повтор отправки — пауза 5 с, удваивается до 300 с. Строка сбоя на панели — если самое старое неотправленное ждёт дольше 3600 с, один раз за эпизод.
- Продолжение сессии агента — если с прошлой реплики прошло меньше 7200 с и в пачке нет `ref`.
- Ответ «Принял» уходит сразу на каждую реплику владельца, реплаем на неё.
- Текст сбоя агента в чат ровно: `Не обработал твоё сообщение: <причина>. Пришли его ещё раз`.

## Review Focus

1. **Агент правит `inbox.md` несколькими Edit подряд.** Блок не уходит недописанным: отправка ждёт 5 с тишины по mtime. Тест в задаче 9.
2. **Блок inbox отредактировали после отправки или он исчез.** Повторно не отправляется, исчезновение ничего не делает. Если блок с тем же заголовком появился заново, он тоже не отправляется: ключ — заголовок. Тест в задаче 3.
3. **Телеграм недоступен (сеть, 5xx).** Файлы outbox остаются на диске, пункт inbox не помечается отправленным. После восстановления всё уходит один раз и по порядку. Тест в задаче 9.
4. **Реплика пришла, пока агент работает.** Она не теряется и уходит следующим запуском, в одной пачке с другими такими же. Тест в задаче 8.
5. **`--resume` на сессию, которой больше нет.** Например, локальная история claude очищена. Агент падает, владелец получает текст сбоя, а следующая реплика начинает новую сессию, а не снова `--resume`. Тест в задаче 8.

---

### Task 1: Общие куски в `Core`: причина сбоя и ключ Keychain

**Files:**
- Modify: `Core/BigHead/BigHeadAgent.swift` — добавить расширение `AgentFailure`
- Modify: `Core/Secrets/Keychain.swift` — константы
- Modify: `Features/Meetings/PanelNotice.swift` — `forIngest` берёт причину из `Core`
- Test: `Tests/CoreTests/BigHeadAgentTests.swift`, `Tests/MeetingsTests/PanelNoticeTests.swift` (существующие тесты `forIngest` должны остаться зелёными)

**Interfaces:**
- Produces:
  - `extension AgentFailure { public var ownerReason: String }` — русская причина, ровно как сейчас в `PanelNotice.forIngest`: `код выхода N (reason)`, `не уложился в N мин`, `ошибка claude: X`, `непонятный ответ claude`, `не запустился: X`.
  - `Keychain.telegramService = "nohands-telegram"`, `Keychain.telegramAccount = "bot-token"`.

- [ ] **Step 1: Тест** `ownerReasonMatchesThePanelWording`. По одному `#expect` на каждый case:
  - `.exitCode(1, reason: "api_error")` → `"код выхода 1 (api_error)"`;
  - `.timedOut(900)` → `"не уложился в 15 мин"`;
  - `.agentError("x")` → `"ошибка claude: x"`;
  - `.unreadableResult` → `"непонятный ответ claude"`;
  - `.launchFailed("y")` → `"не запустился: y"`.
- [ ] **Step 2:** `swift test --filter BigHeadAgentTests` — FAIL (нет `ownerReason`).
- [ ] **Step 3:** Перенести `switch` из `PanelNotice.forIngest` в `ownerReason`. `forIngest` вызывает `failure.ownerReason`. Добавить константы Keychain.
- [ ] **Step 4:** `swift test --filter "BigHeadAgentTests|PanelNoticeTests"` — PASS.
- [ ] **Step 5:** Commit `Core: причина сбоя агента по-русски в одном месте, ключ Keychain для бота`.

### Task 2: Модуль `Telegram` и его конфиг

**Files:**
- Modify: `Package.swift`:
  - библиотека и таргет `Telegram` (path `Features/Telegram`, зависимость `Core`);
  - тест-таргет `TelegramTests`;
  - `Telegram` в зависимостях `App` и `CLI`.
- Create: `Features/Telegram/TelegramConfig.swift`
- Test: `Tests/TelegramTests/TelegramConfigTests.swift`

**Interfaces:**
- Produces:
  - `public struct TelegramConfig: Equatable, Sendable, Codable { enabled: Bool; ownerUserId: Int64?; replyTimeoutSeconds: Double }`;
  - `static let default` (`false`, `nil`, `900`);
  - `static var configFileURL: URL` — тот же путь, что `TodoistInboundConfig.configFileURL`: `TodoistSync` из `Telegram` недоступен;
  - `static func loadOrCreate(at url: URL = configFileURL) throws -> TelegramConfig`. Контракт тот же, что у `TodoistInboundConfig.loadOrCreate`: файла нет — `.default` без создания; секции нет — дописать её с умолчаниями, сохранив остальные ключи;
  - `var isComplete: Bool` — `enabled && ownerUserId != nil`.

- [ ] **Step 1: Тесты:**
  - `missingSectionIsAppendedWithDefaults`: во временном `config.json` с `{"language":"ru"}` после вызова есть `telegram.enabled == false`, `telegram.replyTimeoutSeconds == 900`, и `language` на месте;
  - `missingKeysTakeDefaults`: `{"telegram":{"ownerUserId":42}}` → `enabled == false`, `ownerUserId == 42`, `replyTimeoutSeconds == 900`;
  - `missingFileIsNotCreated`.
- [ ] **Step 2:** `swift test --filter TelegramConfigTests` — FAIL.
- [ ] **Step 3:** Реализовать.
- [ ] **Step 4:** `swift build && swift test --filter TelegramConfigTests` — PASS.
- [ ] **Step 5:** Commit `Telegram: модуль и секция конфига`.

### Task 3: Пункты inbox

**Files:**
- Create: `Features/Telegram/InboxItems.swift`
- Test: `Tests/TelegramTests/InboxItemsTests.swift`

**Interfaces:**
- Produces:
  - `public struct InboxItem: Equatable, Sendable { ref: String; text: String }`;
  - `public enum InboxItems { static func parse(_ markdown: String) -> [InboxItem] }`.

  Правила разбора:
  - Внутри `## Ждёт ответа` каждый `### <заголовок>` до следующего `###`/`##` — пункт. `ref` — заголовок без `### `, `text` — весь блок с заголовком.
  - Внутри `## Сбои` каждая непустая строка — пункт. `ref` — `Сбой: <строка>`, `text` — строка.
  - Порядок — как в файле.

- [ ] **Step 1: Тесты:**
  - `blocksUnderWaitingAreItems`: два блока → два пункта, `ref` равны заголовкам, текст первого не содержит заголовка второго;
  - `failureLinesAreItems`;
  - `emptySectionsGiveNothing` — на нынешнем пустом inbox `# Inbox\n\n## Ждёт ответа\n\n## Сбои` результат `[]`;
  - `headingOutsideSectionsIsIgnored`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test --filter InboxItemsTests` — PASS.
- [ ] **Step 5:** Commit `Telegram: пункты inbox`.

### Task 4: Текст для Телеграма

**Files:**
- Create: `Features/Telegram/TelegramText.swift`
- Test: `Tests/TelegramTests/TelegramTextTests.swift`

**Interfaces:**
- Produces:
  - `public enum TelegramText`:
    - `static func html(fromMarkdown: String) -> String`;
    - `static func chunks(_ html: String, limit: Int = 4096) -> [String]`;
    - `static func extractButtons(_ markdown: String) -> (body: String, buttons: [String])`.

  Правила перевода:
  - экранировать `& < >`;
  - `**x**` → `<b>x</b>`;
  - `` `x` `` → `<code>x</code>`;
  - `[[x]]` → `x`;
  - строка `#…# x` → `<b>x</b>`;
  - остальное как есть.

  Нарезка — по границам абзацев (`\n\n`). Абзац длиннее лимита режется по строкам, строка длиннее лимита — по символам. Тег не может разорваться: разметка внутри одной строки.

  Блок кнопок (формат фиксируется здесь, задача 11 переносит его в спеку):
  ```
  <!-- кнопки
  Созвон 20.10 16:33
  Lint 2026-10-26
  -->
  ```
  Каждая непустая строка — кнопка. Блок вырезается из тела.

- [ ] **Step 1: Тесты:**
  - `linksLoseBrackets`: `"см. [[brandsim]]"` → `"см. brandsim"`;
  - `htmlIsEscaped`: `"a < b & c"` → `"a &lt; b &amp; c"`;
  - `boldAndHeadings`: `"### Созвон\n**ок**"` → `"<b>Созвон</b>\n<b>ок</b>"`;
  - `chunksRespectLimit`: 10 абзацев по 1000 символов → все части `≤ 4096`, склейка частей через `\n\n` равна исходному;
  - `oversizedLineIsHardSplit`;
  - `buttonsAreExtracted`: тело без блока, `buttons == ["Созвон 20.10 16:33", "Lint 2026-10-26"]`;
  - `noButtonsBlockGivesEmpty`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS.
- [ ] **Step 5:** Commit `Telegram: перевод markdown и нарезка`.

### Task 5: Файлы outbox

**Files:**
- Create: `Features/Telegram/Outbox.swift`
- Test: `Tests/TelegramTests/OutboxTests.swift`

**Interfaces:**
- Produces:
  - `public struct OutboxMessage: Equatable, Sendable { url: URL; ref: String?; body: String }`;
  - `public enum Outbox`:
    - `static var defaultURL: URL`;
    - `static func pending(in folder: URL) -> [OutboxMessage]` — только `*.md`, имя не начинается с `.`, по возрастанию имени. Писатель пишет `.<имя>.tmp` и переименовывает: так недописанный файл не виден;
    - `static func parse(url: URL, contents: String) -> OutboxMessage` — frontmatter с `ref:` необязателен;
    - `static func write(ref: String?, body: String, to folder: URL, now: Date) throws -> URL` — для CLI и тестов. Имя `yyyyMMdd-HHmmss-<6 hex>.md`, атомарно через `.tmp`.

- [ ] **Step 1: Тесты:**
  - `pendingSkipsDotFilesAndSortsByName`;
  - `refIsReadFromFrontmatter`;
  - `fileWithoutFrontmatterHasNilRef`;
  - `writeProducesAParsableFile`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS.
- [ ] **Step 5:** Commit `Telegram: outbox`.

### Task 6: Состояние бота

**Files:**
- Create: `Features/Telegram/TelegramStateStore.swift`
- Test: `Tests/TelegramTests/TelegramStateStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct TelegramState: Codable, Equatable, Sendable`:
    - `updateOffset: Int64` — следующий `offset` для `getUpdates`;
    - `sentInboxRefs: [String]`;
    - `sentMessages: [String: SentMessage]` — ключ `message_id` строкой, не больше 500 записей, лишние старейшие выбрасываются;
    - `conversation: Conversation?`.
  - `public struct SentMessage: Codable, Equatable, Sendable { ref: String?; buttons: [String]; sentAt: Date }`. Текст сообщения не хранится: при реплае Телеграм сам присылает `reply_to_message.text`.
  - `public struct Conversation: Codable, Equatable, Sendable { sessionID: UUID; lastReplyAt: Date }`.
  - `public actor TelegramStateStore`:
    - `init(url: URL)`;
    - `load() throws -> TelegramState`;
    - `save(_:) throws`.

  Нет файла — пустое состояние (`updateOffset` 0) без записи. Есть, но не читается — throw, файл не трогается.

- [ ] **Step 1: Тесты:**
  - `missingFileIsEmptyState`;
  - `roundTrip`;
  - `unreadableFileThrowsAndIsKept`;
  - `sentMessagesAreCappedAt500OldestFirst`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS.
- [ ] **Step 5:** Commit `Telegram: состояние`.

### Task 7: Клиент Bot API

**Files:**
- Create: `Features/Telegram/TelegramAPI.swift` (протокол и типы), `Features/Telegram/TelegramClient.swift` (URLSession)
- Test: `Tests/TelegramTests/TelegramAPITests.swift`

**Interfaces:**
- Produces:
  - `public protocol TelegramAPI: Sendable`:
    - `func updates(offset: Int64, timeout: Int) async throws -> [TelegramUpdate]`;
    - `func send(chatID: Int64, html: String, replyTo: Int64?, buttons: [String]) async throws -> Int64` — возвращает `message_id`;
    - `func answerCallback(id: String) async throws`.
  - `public struct TelegramUpdate: Decodable, Equatable, Sendable`:
    - `updateID`;
    - `message: Message?`, где `Message` — `messageID`, `fromID`, `chatID`, `text?`, `replyTo: (messageID, text?)?`;
    - `callback: Callback?`, где `Callback` — `id`, `fromID`, `data`, `messageID`.

    Ключи JSON — `update_id`, `message.message_id`, `message.from.id`, `message.chat.id`, `message.text`, `message.reply_to_message`, `callback_query.{id,from.id,data,message.message_id}`.
  - `public struct TelegramClient: TelegramAPI { init(token: String) }`:
    - запросы `POST https://api.telegram.org/bot<token>/<method>` с JSON;
    - `parse_mode: "HTML"`;
    - кнопки — `reply_markup.inline_keyboard`, по кнопке в ряд, `callback_data` = `"b:<индекс>"`;
    - `ok: false` или не-2xx → `TelegramError.api(code: Int, description: String)`;
    - токен не попадает ни в `errorDescription`, ни в лог;
    - таймаут запроса для `getUpdates` — 60 с.
  - Чистые функции для тестов: `static func request(token:method:body:) -> URLRequest` и `static func decodeUpdates(_ data: Data) throws -> [TelegramUpdate]`.

- [ ] **Step 1: Тесты:**
  - `decodesMessageReplyAndCallback` на фикстуре из трёх апдейтов;
  - `sendBodyCarriesButtonsAsCallbackIndexes`: `buttons ["a","b"]` → `inline_keyboard [[{text:"a",callback_data:"b:0"}],[{text:"b",callback_data:"b:1"}]]`;
  - `apiErrorDoesNotLeakToken`: `errorDescription` не содержит строку токена.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** PASS.
- [ ] **Step 5:** Commit `Telegram: клиент Bot API`.

### Task 8: Агент ответа

**Files:**
- Create: `Features/Telegram/ReplyAgent.swift`
- Test: `Tests/TelegramTests/ReplyAgentTests.swift`

**Interfaces:**
- Consumes: `BigHeadAgent.run(executable:arguments:directory:timeout:) -> AgentReport`, `AgentFailure.ownerReason`, `TelegramStateStore`.
- Produces:
  - `public struct Reply: Equatable, Sendable { text: String; at: Date; ref: String?; quoted: String? }`;
  - `public actor ReplyAgent`:
    - `init(agent: BigHeadAgent, store: TelegramStateStore, settings: Settings?, repliesFolder: URL, outbox: URL, meetings: URL, now: @Sendable () -> Date, newSessionID: @Sendable () -> UUID, report: @Sendable (Outcome) -> Void)`, где `Settings { claude: URL; bighead: URL; timeout: TimeInterval }`;
    - `enqueue(_ reply: Reply)`;
    - `update(settings:)`;
    - `waitUntilIdle()`.
  - `Outcome { failure: AgentFailure? }` — при сбое бот шлёт в чат `Не обработал твоё сообщение: \(failure.ownerReason). Пришли его ещё раз`.
  - `static func arguments(replyFile: URL, session: SessionChoice, bighead: URL, outbox: URL, meetings: URL, replies: URL) -> [String]`, где `SessionChoice` — `.new(UUID)` или `.resume(UUID)`.

  Пачка. Всё, что накопилось к началу запуска, — один файл `<repliesFolder>/<yyyyMMdd-HHmmss>.md`. На каждую реплику в нём:
  - время;
  - `ref`, если есть;
  - `> ` цитата `quoted`, если есть;
  - текст.

  Реплики, пришедшие во время запуска, — следующая пачка. Файл удаляется после запуска при любом исходе: реплика уже есть в `raw/`, если агент дошёл до неё, а иначе владелец пришлёт её ещё раз.

  Выбор сессии:
  - в пачке есть `ref` → `.new`;
  - иначе `conversation` есть и `now - lastReplyAt < 7200` → `.resume(sessionID)`;
  - иначе `.new`.

  После успеха `conversation = (выбранная сессия, now)`. После сбоя `conversation = nil`, поэтому следующая реплика начинает новую сессию.

  Аргументы — ровно по порядку:
  ```
  -p "Реплика владельца из Телеграма: <путь к файлу реплики>. Действуй по разделу «Телеграм» в AGENTS.md: сначала всё, что схема требует при любом контакте, потом сама реплика. Итог — в outbox <путь outbox>."
  --restricted --strict-mcp-config
  --tools Read,Edit,Write,Glob,Grep,Bash
  --allowedTools "Bash(curl -sS -m 120 -X * http://127.0.0.1:41730/*)" "Bash(curl -sS http://127.0.0.1:41730/health)"
  --add-dir <meetings> --add-dir <outbox> --add-dir <replies>
  --session-id <uuid>      (для .new)   |   --resume <uuid>   (для .resume)
  --permission-mode acceptEdits --output-format json
  ```
  `--restricted` возвращает Bash, только когда `--tools` его называет. Неразрешённая команда в `-p` отклоняется без вопроса. Проверка — в задаче 11.

- [ ] **Step 1: Тесты** (фейковый `ProcessRunning` с воротами, как в `MeetingIngestTests`):
  - `repliesDuringARunGoToTheNextBatch`: `enqueue` A, ворота держат запуск, `enqueue` B и C → два запуска, во втором файле есть B и C;
  - `refStartsANewSession`;
  - `recentReplyResumes`: `lastReplyAt = now - 3600` → аргументы содержат `--resume` и прежний UUID;
  - `oldReplyStartsNew`: `now - 7200` → `--session-id` и новый UUID;
  - `failureClearsConversation` (Review Focus 5): запуск с `--resume` падает → `Outcome.failure != nil`, следующая реплика идёт с `--session-id`;
  - `argumentsInExactOrder`: сравнение массива целиком для `.new`;
  - `replyFileIsRemovedAfterRun`;
  - `nilSettingsLaunchesNothing`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test --filter ReplyAgentTests` — PASS.
- [ ] **Step 5:** Commit `Telegram: агент ответа`.

### Task 9: Бот: доставка и приём

**Files:**
- Create: `Features/Telegram/TelegramBot.swift`
- Test: `Tests/TelegramTests/TelegramBotTests.swift` (фейковый `TelegramAPI`, ручные часы)

**Interfaces:**
- Consumes: всё из задач 3–8.
- Produces:
  - `public actor TelegramBot`:
    - `init(api: any TelegramAPI, ownerID: Int64, inbox: URL, outbox: URL, store: TelegramStateStore, replies: ReplyAgent, now: @Sendable () -> Date, report: @Sendable (Notice) -> Void)`;
    - `start()` — запускает оба цикла;
    - `stop()`;
    - `deliverOnce() async` и `pollOnce() async` — по одному шагу каждого цикла, для тестов и CLI.
  - `public enum Notice: Equatable, Sendable { case deliveryStalled(since: Date); case stateUnreadable }`.

  `deliverOnce`:
  1. Если mtime `inbox.md` моложе 5 с, inbox в этом проходе пропускается.
  2. Иначе пункты `InboxItems.parse`, которых нет в `sentInboxRefs`, по порядку: текст → `TelegramText` → части. Первая часть несёт кнопки и запоминается в `sentMessages` с `ref`. `ref` добавляется в `sentInboxRefs` после отправки всех частей.
  3. Затем `Outbox.pending`: тот же путь, файл удаляется после отправки всех частей.
  4. Первый сбой отправки прерывает проход. Следующий проход — через паузу 5 с с удвоением до 300 с. Если самое старое неотправленное ждёт дольше 3600 с — `report(.deliveryStalled)`, один раз до ближайшего успеха.

  `pollOnce` — `updates(offset:timeout: 50)`. На каждый апдейт `updateOffset = update_id + 1`, сохраняется сразу.
  - **Сообщение от не-владельца** — ничего.
  - **Сообщение владельца с текстом:**
    - `send("Принял", replyTo: message_id)`;
    - `ref` = `sentMessages[replyTo.messageID]?.ref`;
    - `enqueue(Reply(text:, at:, ref:, quoted: replyTo?.text))`.
  - **Callback владельца:**
    - `answerCallback`;
    - кнопка — `sentMessages[messageID].buttons[индекс из "b:N"]`;
    - `enqueue(Reply(text: кнопка, ref: sentMessages[messageID].ref, quoted: nil))`.

  Состояние не читается → `report(.stateUnreadable)`, оба цикла стоят.

- [ ] **Step 1: Тесты:**
  - `newInboxBlockIsSentOnce`: два прохода → одна отправка;
  - `editedBlockIsNotResent` (Review Focus 2);
  - `freshInboxWaitsForQuiet` (Review Focus 1): mtime = now − 2 с → ничего; now + 5 с → отправка;
  - `outboxFileIsSentAndDeleted`;
  - `sendFailureKeepsEverythingAndRetriesInOrder` (Review Focus 3): API падает на первом → файл на месте, ref не помечен; API ожил → обе отправки по порядку, по одной;
  - `stalledOverAnHourIsReportedOnce`;
  - `strangerIsIgnored`: апдейт с чужим `from.id` → ни `send`, ни `enqueue`;
  - `ownerMessageGetsAckAndIsQueued`;
  - `replyToInboxMessageCarriesRef`;
  - `callbackMapsToButtonText`;
  - `offsetIsPersistedPerUpdate`.
- [ ] **Step 2:** FAIL. **Step 3:** реализовать. **Step 4:** `swift test --filter TelegramBotTests` — PASS.
- [ ] **Step 5:** Commit `Telegram: доставка и приём`.

### Task 10: Агент созвона без `ListAgents` и `SendMessage`

**Files:**
- Modify: `Features/Meetings/MeetingIngest.swift` (`arguments`)
- Modify: `Tests/MeetingsTests/MeetingIngestTests.swift` (ожидаемый массив)

- [ ] **Step 1:** В тесте аргументов ожидать `--tools Read,Edit,Write,Glob,Grep`.
- [ ] **Step 2:** `swift test --filter MeetingIngestTests` — FAIL.
- [ ] **Step 3:** Убрать `,ListAgents,SendMessage` из `--tools`. Поправить doc-комментарий: выжимку доставляет бот из inbox.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `Созвоны: выжимку доставляет бот, агенту больше не нужны ListAgents и SendMessage`.

### Task 11: Сборка в приложении, CLI, журнал решений, живая проверка

**Files:**
- Modify: `App/AppDelegate.swift`:
  - `TelegramBot` и `ReplyAgent` строятся один раз на общем `bigHeadAgent`;
  - «Перечитать конфиг» обновляет настройки;
  - `Notice` → `PanelNotice` красным: `deliveryStalled` → `Телеграм: не отправляется больше часа`, `stateUnreadable` → `Телеграм: файл состояния не читается, бот остановлен`;
  - сбой `ReplyAgent` → строка на панели `Реплика из Телеграма не обработана: <ownerReason>` и сообщение в чат.
- Modify: `App/StatusMenu.swift` / строка состояния: `телеграм: не настроен` — нет токена, `ownerUserId` или `enabled == false`; `телеграм: <ошибка Keychain>` — Keychain не читается.
- Modify: `CLI/NoHands.swift`, Create: `CLI/TelegramCommands.swift`:
  - `nohands telegram send <файл.md>` — отправить файл владельцу сразу, без outbox и состояния;
  - `nohands telegram reply "<текст>"` — запуск агента ответа без очереди приложения и без состояния (`.new`), печатает код выхода и длительность. По образцу `runMeetingIngest`.
- Modify: `docs/DECISIONS.md` — запись `2026-10-22 — Телеграм-бот Башки`:
  - выжимки уходят на серверы Телеграма — новая сторонняя граница поверх записи 2026-10-19 «Созвоны уходят в облако Anthropic»;
  - агенту ответа выдан Bash, ограниченный `curl` на `127.0.0.1:41730`;
  - токен кладётся в Keychain руками.
- Modify: `docs/superpowers/specs/2026-10-21-telegram-bot-design.md` — отметить расхождения:
  - токен через `security`;
  - текст исходного сообщения берётся из `reply_to_message`, а не хранится;
  - сессию задаёт NoHands через `--session-id`;
  - формат блока кнопок из задачи 4.

  Статус спеки — «согласовано».

- [ ] **Step 1:** Подключить в `AppDelegate`, `StatusMenu`, CLI. `swift build` — без ошибок, `swift test` — всё зелёное.
- [ ] **Step 2: Живая проверка ограничения Bash.** `nohands telegram reply "выполни ls ~ и curl -sS http://127.0.0.1:41730/health, напиши в outbox, что вышло"`:
  - в outbox — `ls` отклонён, `health` вернул `{"ok":true}`;
  - если `ls` прошёл — остановиться и вернуться к форме `--allowedTools`, дальше не идти.
- [ ] **Step 3:** Записать журнал решений и правки спеки.
- [ ] **Step 4:** Собрать приложение `Scripts/make-app.sh`. Владелец кладёт токен:
  ```bash
  security add-generic-password -s nohands-telegram -a bot-token -w '<токен>'
  ```
  Затем `telegram.enabled: true`, `ownerUserId` в конфиге, «Перечитать конфиг». Пройти проверки спеки 0, 1, 2, 7. Проверки 3–6 — после правок `AGENTS.md` (библиотекарь Башки, вне этого плана).
- [ ] **Step 5:** Commit `Телеграм-бот: сборка в приложении, CLI, журнал решений`.

---

## После плана — на стороне Башки (не исполнителю NoHands)

Библиотекарь Башки в чате правит `~/BigHead/AGENTS.md`:
- шаг 7 «Созвоны → входящие» — доставку делает бот;
- удалить сессию «Башка · входящие»;
- новый раздел «Телеграм»: привязка реплики, формат outbox и блока кнопок, итог всегда в outbox.

Затем проверки спеки 3–6.
