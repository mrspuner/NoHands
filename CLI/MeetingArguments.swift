import Foundation

/// Arguments of `nohands meeting …`, parsed apart from being executed so the parsing can be
/// tested — the same split `TranscribeArguments` uses.
struct MeetingArguments {
    enum Subcommand: String {
        case process
        case levels
    }

    enum ParseError: Error, Equatable {
        case message(String)
    }

    var subcommand: Subcommand
    var folder: URL

    static func parse(_ arguments: [String]) throws -> MeetingArguments {
        guard arguments.count >= 3 else {
            throw ParseError.message("Использование: nohands meeting <process|levels> <папка встречи>")
        }
        guard let subcommand = Subcommand(rawValue: arguments[1]) else {
            throw ParseError.message("Неизвестная подкоманда: \(arguments[1]). Поддерживаются process и levels")
        }
        return MeetingArguments(
            subcommand: subcommand,
            folder: URL(fileURLWithPath: arguments[2]).standardizedFileURL
        )
    }
}
