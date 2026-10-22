import Core
import Foundation
import os
import Testing
@testable import Telegram

private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
private let bighead = URL(fileURLWithPath: "/Users/x/BigHead")
/// Any executable will do: the agent only checks that the hook exists before launching.
private let hook = ["/usr/bin/true", "--telegram-bash-hook"]
private let settings = ReplyAgent.Settings(claude: claude, bighead: bighead, timeout: 900, hook: hook)
private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let previous = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

/// Holds runs until opened. Once open it stays open, so later runs pass straight through.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Records every launch together with the reply file as it was during the run: the file is gone
/// once the run ends. Runs listed in `failing` (1-based) fail the way claude was seen failing live.
private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var directory: URL
        var replyFile: String?
    }

    private let failing: Set<Int>
    private let started: Gate?
    private let gate: Gate?
    private let state = OSAllocatedUnfairLock(initialState: [Call]())

    init(failing: Set<Int> = [], started: Gate? = nil, gate: Gate? = nil) {
        self.failing = failing
        self.started = started
        self.gate = gate
    }

    var calls: [Call] { state.withLock { $0 } }

    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun {
        let path = Self.replyPath(in: arguments)
        let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let number = state.withLock {
            $0.append(Call(arguments: arguments, directory: directory, replyFile: text))
            return $0.count
        }
        await started?.release()
        await gate?.wait()
        if failing.contains(number) {
            return AgentRun(exitCode: 1, result: AgentResult(isError: true, terminalReason: "api_error"),
                            stderrLine: nil)
        }
        return AgentRun(exitCode: 0, result: AgentResult(isError: false, terminalReason: nil), stderrLine: nil)
    }

    /// The reply file's path, read back from the prompt.
    static func replyPath(in arguments: [String]) -> String? {
        guard arguments.count > 1 else { return nil }
        let prompt = arguments[1]
        guard let start = prompt.range(of: "Телеграма: "), let end = prompt.range(of: ". Действуй") else { return nil }
        return String(prompt[start.upperBound..<end.lowerBound])
    }
}

private final class Reports: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [ReplyAgent.Outcome]())
    var all: [ReplyAgent.Outcome] { state.withLock { $0 } }
    func add(_ outcome: ReplyAgent.Outcome) { state.withLock { $0.append(outcome) } }
}

/// Hands out `...0001`, `...0002` and so on.
private final class SessionIDs: @unchecked Sendable {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    func next() -> UUID {
        let number = counter.withLock { $0 += 1; return $0 }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}

private func generated(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

private struct Fixture {
    let root: URL
    let replies: URL
    let outbox: URL
    let meetings: URL
    let stateURL: URL
    let store: TelegramStateStore
    let runner: FakeRunner
    let reports = Reports()
    let agent: ReplyAgent

    init(runner: FakeRunner = FakeRunner(), conversation: Conversation? = nil,
         settings: ReplyAgent.Settings? = settings) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString)")
        replies = root.appendingPathComponent("telegram-replies")
        outbox = root.appendingPathComponent("telegram-outbox")
        meetings = root.appendingPathComponent("Meetings")
        stateURL = root.appendingPathComponent("telegram-state.json")
        store = TelegramStateStore(url: stateURL)
        if let conversation {
            var state = TelegramState()
            state.conversation = conversation
            try await store.save(state)
        }
        self.runner = runner
        let reports = reports
        let ids = SessionIDs()
        agent = ReplyAgent(
            agent: BigHeadAgent(runner: runner, pidFile: nil), store: store, settings: settings,
            repliesFolder: replies, outbox: outbox, meetings: meetings,
            now: { now }, newSessionID: { ids.next() }, report: { reports.add($0) })
    }

    func send(_ replies: Reply...) async {
        for reply in replies { await agent.enqueue(reply) }
        await agent.waitUntilIdle()
    }

    func conversation() async throws -> Conversation? { try await store.load().conversation }
}

private func reply(_ text: String, ref: String? = nil, quoted: String? = nil) -> Reply {
    Reply(text: text, at: now, ref: ref, quoted: quoted)
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

@Test func repliesDuringARunGoToTheNextBatch() async throws {
    let started = Gate(), gate = Gate()
    let runner = FakeRunner(started: started, gate: gate)
    let fixture = try await Fixture(runner: runner)
    await fixture.agent.enqueue(reply("первая"))
    await started.wait()
    await fixture.agent.enqueue(reply("вторая"))
    await fixture.agent.enqueue(reply("третья"))
    await gate.release()
    await fixture.agent.waitUntilIdle()

    #expect(runner.calls.count == 2)
    let first = try #require(runner.calls[0].replyFile)
    let second = try #require(runner.calls[1].replyFile)
    #expect(first.contains("первая"))
    #expect(!first.contains("вторая"))
    #expect(second.contains("вторая") && second.contains("третья"))
    #expect(!second.contains("первая"))
    #expect(fixture.reports.all == [ReplyAgent.Outcome(failure: nil), ReplyAgent.Outcome(failure: nil)])
}

@Test func theBatchFileCarriesTimeRefQuoteAndText() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(runner: runner)
    await fixture.agent.enqueue(reply("сделаю завтра", ref: "todoist-42", quoted: "Что с отчётом?\nСрок пятница"))
    await fixture.agent.waitUntilIdle()

    let text = try #require(runner.calls.first?.replyFile)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    #expect(text.contains(formatter.string(from: now)))
    #expect(text.contains("ref: todoist-42"))
    #expect(text.contains("> Что с отчётом?\n> Срок пятница"))
    #expect(text.contains("сделаю завтра"))
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let path = try #require(FakeRunner.replyPath(in: runner.calls[0].arguments))
    #expect(URL(fileURLWithPath: path).lastPathComponent == formatter.string(from: now) + ".md")
    #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == fixture.replies.path)
}

@Test func anExistingFileNameGetsASuffix() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(runner: runner)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let base = formatter.string(from: now)
    try FileManager.default.createDirectory(at: fixture.replies, withIntermediateDirectories: true)
    try Data().write(to: fixture.replies.appendingPathComponent(base + ".md"))
    try Data().write(to: fixture.replies.appendingPathComponent(base + "-2.md"))
    await fixture.send(reply("текст"))

    let path = try #require(FakeRunner.replyPath(in: runner.calls[0].arguments))
    #expect(URL(fileURLWithPath: path).lastPathComponent == base + "-3.md")
}

@Test func refStartsANewSession() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(
        runner: runner, conversation: Conversation(sessionID: previous, lastReplyAt: now - 60))
    await fixture.send(reply("со ссылкой", ref: "inbox-7"))

    let arguments = try #require(runner.calls.first?.arguments)
    #expect(value(after: "--session-id", in: arguments) == generated(1).uuidString.lowercased())
    #expect(!arguments.contains("--resume"))
    #expect(try await fixture.conversation() == Conversation(sessionID: generated(1), lastReplyAt: now))

    // One `ref` anywhere in the batch is enough.
    let fresh = UUID()
    let mixed = ReplyAgent.choose(
        batch: [reply("без ссылки"), reply("со ссылкой", ref: "inbox-7")],
        conversation: Conversation(sessionID: previous, lastReplyAt: now - 60), now: now, newSessionID: { fresh })
    #expect(mixed == .new(fresh))
}

@Test func recentReplyResumes() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(
        runner: runner, conversation: Conversation(sessionID: previous, lastReplyAt: now - 3600))
    await fixture.send(reply("продолжаем"))

    let arguments = try #require(runner.calls.first?.arguments)
    #expect(value(after: "--resume", in: arguments) == previous.uuidString.lowercased())
    #expect(!arguments.contains("--session-id"))
    #expect(try await fixture.conversation() == Conversation(sessionID: previous, lastReplyAt: now))
}

@Test func oldReplyStartsNew() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(
        runner: runner, conversation: Conversation(sessionID: previous, lastReplyAt: now - 7200))
    await fixture.send(reply("через два часа"))

    let arguments = try #require(runner.calls.first?.arguments)
    #expect(value(after: "--session-id", in: arguments) == generated(1).uuidString.lowercased())
    #expect(!arguments.contains("--resume"))
}

@Test func failureClearsConversation() async throws {
    let runner = FakeRunner(failing: [1])
    let fixture = try await Fixture(
        runner: runner, conversation: Conversation(sessionID: previous, lastReplyAt: now - 60))
    await fixture.send(reply("первая"))

    #expect(runner.calls.first.map { value(after: "--resume", in: $0.arguments) } == previous.uuidString.lowercased())
    #expect(fixture.reports.all == [ReplyAgent.Outcome(failure: .exitCode(1, reason: "api_error"))])
    #expect(try await fixture.conversation() == nil)

    await fixture.send(reply("вторая"))
    let second = runner.calls[1].arguments
    #expect(value(after: "--session-id", in: second) == generated(1).uuidString.lowercased())
    #expect(!second.contains("--resume"))
}

@Test func anUnreadableStateStartsNewAndIsLeftAsIs() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(runner: runner)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: fixture.stateURL)
    await fixture.send(reply("текст"))

    #expect(runner.calls.count == 1)
    #expect(runner.calls.first.map { value(after: "--session-id", in: $0.arguments) } == generated(1).uuidString.lowercased())
    #expect(try String(contentsOf: fixture.stateURL, encoding: .utf8) == "{ not json")
    #expect(fixture.reports.all == [ReplyAgent.Outcome(failure: nil)])
}

@Test func argumentsInExactOrder() {
    let session = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let arguments = ReplyAgent.arguments(
        replyFile: URL(fileURLWithPath: "/R/20261022-143005.md"), session: .new(session),
        bighead: bighead, outbox: URL(fileURLWithPath: "/O"), meetings: URL(fileURLWithPath: "/M"),
        replies: URL(fileURLWithPath: "/R"), hook: ["/A B/NoHands", "--telegram-bash-hook"])
    #expect(arguments == [
        "-p",
        "Реплика владельца из Телеграма: /R/20261022-143005.md. Действуй по разделу «Телеграм» в AGENTS.md: "
            + "сначала всё, что схема требует при любом контакте, потом сама реплика. Итог — в outbox /O.",
        "--restricted", "--strict-mcp-config",
        "--tools", "Read,Edit,Write,Glob,Grep,Bash",
        "--allowedTools",
        "Bash(curl -sS -m 120 -X * http://127.0.0.1:41730/*)",
        "Bash(curl -sS http://127.0.0.1:41730/health)",
        "--settings",
        #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'/A B/NoHands' '--telegram-bash-hook'"}]}]}}"#,
        "--add-dir", "/M", "--add-dir", "/O", "--add-dir", "/R",
        "--session-id", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "--permission-mode", "acceptEdits", "--output-format", "json",
    ])

    let resumed = ReplyAgent.arguments(
        replyFile: URL(fileURLWithPath: "/R/a.md"), session: .resume(session), bighead: bighead,
        outbox: URL(fileURLWithPath: "/O"), meetings: URL(fileURLWithPath: "/M"), replies: URL(fileURLWithPath: "/R"),
        hook: hook)
    #expect(Array(resumed[17...18]) == ["--resume", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
    #expect(!resumed.contains("--session-id"))
}

@Test func theRunUsesTheSettings() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(runner: runner)
    await fixture.send(reply("текст"))
    #expect(runner.calls.first?.directory == bighead)
    let arguments = try #require(runner.calls.first?.arguments)
    #expect(value(after: "--add-dir", in: arguments) == fixture.meetings.path)
    #expect(arguments.contains(fixture.replies.path))
    #expect(arguments.contains(fixture.outbox.path))
}

@Test func replyFileIsRemovedAfterRun() async throws {
    let runner = FakeRunner(failing: [2])
    let fixture = try await Fixture(runner: runner)
    await fixture.send(reply("удачная"))
    await fixture.send(reply("неудачная"))

    #expect(runner.calls.count == 2)
    #expect(runner.calls.allSatisfy { $0.replyFile != nil })
    let left = try FileManager.default.contentsOfDirectory(atPath: fixture.replies.path)
    #expect(left.isEmpty)
}

@Test func nilSettingsLaunchesNothing() async throws {
    let runner = FakeRunner()
    let fixture = try await Fixture(runner: runner, settings: nil)
    await fixture.send(reply("никуда"))

    #expect(runner.calls.isEmpty)
    // Not silent: the owner was told «Принял», so he hears that nothing will come of it.
    #expect(fixture.reports.all == [ReplyAgent.Outcome(failure: .launchFailed("агент не настроен"))])
    #expect(!FileManager.default.fileExists(atPath: fixture.replies.path))

    // Dropped, not held back: switching on later runs only what arrives after.
    await fixture.agent.update(settings: settings)
    await fixture.send(reply("теперь"))
    #expect(runner.calls.count == 1)
    let text = try #require(runner.calls.first?.replyFile)
    #expect(text.contains("теперь") && !text.contains("никуда"))
}

@Test func aMissingHookLaunchesNothing() async throws {
    let runner = FakeRunner()
    let missing = ReplyAgent.Settings(claude: claude, bighead: bighead, timeout: 900,
                                      hook: ["/nonexistent/NoHands", "--telegram-bash-hook"])
    let fixture = try await Fixture(runner: runner, settings: missing)
    await fixture.send(reply("текст"))

    // Claude Code lets a call through when the hook command is not found, so no hook, no run.
    #expect(runner.calls.isEmpty)
    #expect(fixture.reports.all == [ReplyAgent.Outcome(
        failure: .launchFailed("фильтр команд не найден: /nonexistent/NoHands"))])
    #expect(try await fixture.conversation() == nil)
}

@Test func theHookIsQuotedForTheShell() {
    #expect(ReplyAgent.hookSettings(["/it's here/x"]) == #"""
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'/it'\\''s here/x'"}]}]}}
        """#)
}

@Test func theFailureTextIsTheSpecOne() {
    #expect(ReplyAgent.failureText(.timedOut(900))
        == "Не обработал твоё сообщение: не уложился в 15 мин. Пришли его ещё раз")
}
