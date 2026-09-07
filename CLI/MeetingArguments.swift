import Foundation

/// Arguments of `nohands meeting …`, parsed apart from being executed so the parsing can be
/// tested — the same split `TranscribeArguments` uses.
struct MeetingArguments {
    enum Subcommand: String {
        case process
        case levels
        case summarize
    }

    enum ParseError: Error, Equatable {
        case message(String)
    }

    var subcommand: Subcommand
    /// A folder for `process` and `levels`, a file for `summarize` — hence the neutral name.
    var path: URL

    static func parse(_ arguments: [String]) throws -> MeetingArguments {
        guard arguments.count >= 3 else {
            throw ParseError.message(
                "Использование: nohands meeting <process|levels|summarize> <папка встречи или файл>"
            )
        }
        guard let subcommand = Subcommand(rawValue: arguments[1]) else {
            throw ParseError.message(
                "Неизвестная подкоманда: \(arguments[1]). Поддерживаются process, levels и summarize"
            )
        }
        return MeetingArguments(
            subcommand: subcommand,
            path: URL(fileURLWithPath: arguments[2]).standardizedFileURL
        )
    }
}
