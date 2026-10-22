import Core
import Foundation
import Meetings
import Telegram
import TodoistSync

/// Sends one markdown file to the owner right away: no outbox, no state. Its `ref`, if any, is
/// ignored — nothing remembers the message, so a reply to it reaches the agent without one.
func runTelegramSend(_ file: URL) async throws {
    let config = try TelegramConfig.loadOrCreate()
    guard let owner = config.ownerUserId else {
        fail("В секции telegram конфига не задан ownerUserId: \(TelegramConfig.configFileURL.path)")
    }
    guard let token = try Keychain.password(service: Keychain.telegramService, account: Keychain.telegramAccount),
          !token.isEmpty
    else {
        fail("В связке ключей нет токена бота: service \(Keychain.telegramService), account \(Keychain.telegramAccount)")
    }
    let message = Outbox.parse(url: file, contents: readFile(file.path))
    let (body, buttons) = TelegramText.extractButtons(message.body)
    // Same limit as `TelegramBot.partLimit`, which is internal to its module.
    let parts = TelegramText.chunks(TelegramText.html(fromMarkdown: body), limit: 4000)
    guard !parts.isEmpty else { fail("Нечего отправлять: файл пуст") }

    let client = TelegramClient(token: token)
    for (index, part) in parts.enumerated() {
        _ = try await client.send(chatID: owner, html: part, replyTo: nil, buttons: index == 0 ? buttons : [])
    }
    print("отправлено частей: \(parts.count)")
}

/// Runs the reply agent once on one reply, outside the app's queue and state: always a new session.
func runTelegramReply(_ text: String, bighead override: URL?) async throws {
    let telegram = try TelegramConfig.loadOrCreate()
    let todoist = try TodoistInboundConfig.loadOrCreate()
    guard !todoist.claudePath.isEmpty else {
        fail("В секции todoist конфига не задан claudePath: \(TodoistInboundConfig.configFileURL.path)")
    }
    let bighead: URL
    if let override {
        bighead = override
    } else if !todoist.bigheadPath.isEmpty {
        bighead = URL(fileURLWithPath: todoist.bigheadPath)
    } else {
        fail("В секции todoist конфига не задан bigheadPath, и нет --bighead: \(TodoistInboundConfig.configFileURL.path)")
    }

    let replies = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-telegram-reply-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: replies) }
    let file = replies.appendingPathComponent("reply.md")
    try Data(ReplyAgent.render([Reply(text: text, at: Date(), ref: nil, quoted: nil)]).utf8).write(to: file)

    // This very binary is the hook, through `telegram bash-hook`. Resolved, so the hook still
    // runs when the command was started through a symlink or a relative path.
    let binary = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    let hook = [binary, "telegram", "bash-hook"]
    guard FileManager.default.isExecutableFile(atPath: binary) else {
        fail("Фильтр команд не найден: \(binary)")
    }

    let agent = BigHeadAgent(runner: SystemProcessRunner(), pidFile: nil)
    note("запускаю агента ответа в \(bighead.path)")
    let report = await agent.run(
        executable: URL(fileURLWithPath: todoist.claudePath),
        arguments: ReplyAgent.arguments(replyFile: file, session: .new(UUID()), bighead: bighead,
                                        outbox: Outbox.defaultURL, meetings: MeetingFolder.archiveURL,
                                        replies: replies, hook: hook),
        directory: bighead,
        timeout: telegram.replyTimeoutSeconds
    )
    note("код выхода: \(report.exitCode.map(String.init) ?? "нет"), \(Int(report.duration)) с")
    if let failure = report.failure {
        note("сбой: \(failure.localizedDescription)")
        if let line = report.stderrLine { note("stderr: \(line)") }
        exit(1)
    }
}
