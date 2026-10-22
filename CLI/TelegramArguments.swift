import Foundation

/// Arguments of `nohands telegram …`, parsed apart from being executed so the parsing can be
/// tested — the same split `MeetingArguments` uses.
enum TelegramArguments: Equatable {
    case send(URL)
    /// `bighead` overrides `bigheadPath`, so the agent's restrictions can be checked against a
    /// scratch folder instead of the real BigHead.
    case reply(text: String, bighead: URL?)

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static let usageLine = "Использование: nohands telegram send <файл.md> | nohands telegram reply \"<текст>\" [--bighead <папка>]"

    static func parse(_ arguments: [String]) throws -> TelegramArguments {
        guard arguments.count >= 3 else { throw ParseError.message(usageLine) }
        switch arguments[1] {
        case "send":
            guard arguments.count == 3 else { throw ParseError.message(usageLine) }
            return .send(URL(fileURLWithPath: arguments[2]).standardizedFileURL)
        case "reply":
            let text = arguments[2]
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError.message("Пустая реплика")
            }
            var bighead: URL?
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--bighead":
                    guard index + 1 < arguments.count else {
                        throw ParseError.message("--bighead без значения")
                    }
                    bighead = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                    index += 2
                default:
                    throw ParseError.message("Неизвестный аргумент: \(arguments[index])")
                }
            }
            return .reply(text: text, bighead: bighead)
        default:
            throw ParseError.message(
                "Неизвестная подкоманда: \(arguments[1]). Поддерживаются send и reply")
        }
    }
}
