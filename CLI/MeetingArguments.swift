import Foundation

/// Arguments of `nohands meeting …`, parsed apart from being executed so the parsing can be
/// tested — the same split `TranscribeArguments` uses.
struct MeetingArguments {
    enum Subcommand: String {
        case process
        case levels
        case summarize
        case diarize
    }

    enum ParseError: Error, Equatable {
        case message(String)
    }

    var subcommand: Subcommand
    /// A folder for `process`, `levels` and `diarize`, a file for `summarize` — hence the
    /// neutral name.
    var path: URL
    /// `diarize` only: overrides `voiceMatchThreshold` for this run without touching the config.
    var threshold: Double?
    /// `diarize` only: whether to rewrite the transcript and the voice book, rather than only print.
    var write = false

    static func parse(_ arguments: [String]) throws -> MeetingArguments {
        guard arguments.count >= 3 else {
            throw ParseError.message(
                "Использование: nohands meeting <process|levels|summarize|diarize> <папка встречи или файл>"
            )
        }
        guard let subcommand = Subcommand(rawValue: arguments[1]) else {
            throw ParseError.message(
                "Неизвестная подкоманда: \(arguments[1]). Поддерживаются process, levels, summarize и diarize"
            )
        }
        var result = MeetingArguments(
            subcommand: subcommand,
            path: URL(fileURLWithPath: arguments[2]).standardizedFileURL
        )

        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--threshold":
                guard index + 1 < arguments.count else {
                    throw ParseError.message("--threshold без значения")
                }
                guard let value = Double(arguments[index + 1]) else {
                    throw ParseError.message("--threshold должен быть числом, получено: \(arguments[index + 1])")
                }
                result.threshold = value
                index += 2
            case "--write":
                result.write = true
                index += 1
            default:
                throw ParseError.message("Неизвестный аргумент: \(arguments[index])")
            }
        }
        return result
    }
}
