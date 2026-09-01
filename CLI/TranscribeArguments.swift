import Foundation

/// Parsed `nohands transcribe` command-line arguments.
///
/// Split out from `main.swift` so parsing can be unit-tested without touching `exit(1)`:
/// `parse` throws a plain `ParseError` instead of calling `fail`, and the caller decides what
/// to do with the message.
struct TranscribeArguments {
    var url: URL
    var engine = "whisper"
    var language: String?
    var keyterms: [String] = []
    var keytermsGiven = false
    var model: String?
    var useVAD = false
    var relaxedThresholds = false

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static let usage = """
    Использование: nohands transcribe <файл> --engine whisper|scribe|parakeet [--language <код>] \
    [--keyterms "термин,термин"] [--model <имя>] [--vad] [--relaxed-thresholds]
    """

    static func parse(_ arguments: [String]) throws -> TranscribeArguments {
        guard arguments.count >= 2 else {
            throw ParseError.message(usage)
        }

        var result = TranscribeArguments(url: URL(fileURLWithPath: arguments[1]))
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--engine":
                guard index + 1 < arguments.count else { throw ParseError.message("--engine без значения") }
                result.engine = arguments[index + 1]
                index += 2
            case "--language":
                guard index + 1 < arguments.count else { throw ParseError.message("--language без значения") }
                result.language = arguments[index + 1]
                index += 2
            case "--keyterms":
                guard index + 1 < arguments.count else { throw ParseError.message("--keyterms без значения") }
                result.keytermsGiven = true
                result.keyterms = arguments[index + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                index += 2
            case "--model":
                guard index + 1 < arguments.count else { throw ParseError.message("--model без значения") }
                result.model = arguments[index + 1]
                index += 2
            case "--vad":
                result.useVAD = true
                index += 1
            case "--relaxed-thresholds":
                result.relaxedThresholds = true
                index += 1
            default:
                throw ParseError.message("Неизвестный аргумент: \(arguments[index])")
            }
        }

        // Keyterm prompting is a Scribe API feature; neither local engine has anything like it.
        // Accepting the flag and dropping it would leave the owner reading a run they think was
        // biased and wasn't.
        if result.engine != "scribe", result.keytermsGiven {
            throw ParseError.message("--keyterms поддерживается только движком scribe, у \(result.engine) такого параметра нет")
        }
        // Symmetric check: --model, --vad and --relaxed-thresholds tune WhisperKit's decoding
        // and model choice specifically. Scribe is a hosted API with none of these knobs, and
        // Parakeet is a different local model with its own (currently fixed) configuration.
        if result.engine != "whisper", result.model != nil || result.useVAD || result.relaxedThresholds {
            throw ParseError.message(
                "--model, --vad и --relaxed-thresholds поддерживаются только движком whisper, у \(result.engine) таких параметров нет"
            )
        }

        return result
    }
}
