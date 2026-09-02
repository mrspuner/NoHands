import Core
import Dictation
import Foundation

/// Parsed `nohands dictate` arguments. Same shape as `TranscribeArguments`: parsing throws
/// instead of calling `fail`, so it is testable without `exit(1)`.
struct DictateArguments {
    var raw = false

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static let usage = "Использование: nohands dictate [--raw]"

    static func parse(_ arguments: [String]) throws -> DictateArguments {
        var result = DictateArguments()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--raw":
                result.raw = true
                index += 1
            default:
                throw ParseError.message("Неизвестный аргумент: \(arguments[index])")
            }
        }
        return result
    }
}
