import Foundation

/// Decides which Bash commands the reply agent may run: exactly one `curl` to NoHands on
/// `127.0.0.1:41730`, nothing else. Called from a Claude Code PreToolUse hook, because
/// `--allowedTools` only pre-approves and Claude Code still lets read-only and file commands
/// through on its own.
///
/// An allowlist, not a blocklist: anything the parser does not recognise is denied, including
/// every shell construct that could chain, substitute or redirect.
public enum BashGate {
    public enum Verdict: Equatable, Sendable {
        case allow
        /// The reason goes to the agent, so it knows what is permitted instead.
        case deny(reason: String)
    }

    static let urlPrefix = "http://127.0.0.1:41730/"
    private static let rule = "разрешён только curl к NoHands: \(urlPrefix)…"

    private static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    private static let quietFlags: Set<String> = ["-s", "-S", "-sS", "-Ss"]
    private static let dataFlags: Set<String> = ["-d", "--data", "--data-raw"]
    /// Unquoted, any of these is shell syntax rather than part of a word.
    private static let shellSyntax = Set(";&|<>()$`#*?[]{}~!".unicodeScalars)
    private static let urlCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.~%?=&-")

    public static func verdict(_ command: String) -> Verdict {
        let tokens: [String]
        switch tokenize(command) {
        case .success(let words): tokens = words
        case .failure(let failure): return .deny(reason: "\(failure.reason); \(rule)")
        }
        guard tokens.first == "curl" else { return .deny(reason: rule) }

        var urls: [String] = []
        var index = 1
        func value() -> String? {
            index += 1
            return index < tokens.count ? tokens[index] : nil
        }
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case _ where quietFlags.contains(token):
                break
            case "-m", "--max-time":
                guard let seconds = value(), !seconds.isEmpty, seconds.allSatisfy(\.isASCII),
                      seconds.allSatisfy(\.isNumber)
                else { return .deny(reason: "\(token) — только целое число секунд; \(rule)") }
            case "-X":
                guard let method = value(), methods.contains(method) else {
                    return .deny(reason: "-X — только GET, POST, PUT, PATCH или DELETE; \(rule)")
                }
            case "-H":
                guard let header = value(), !header.hasPrefix("@") else {
                    return .deny(reason: "-H — заголовок, а не файл; \(rule)")
                }
            case _ where dataFlags.contains(token):
                guard let body = value(), !body.hasPrefix("@") else {
                    return .deny(reason: "\(token) — тело запроса, а не файл; \(rule)")
                }
            case _ where token.hasPrefix("-"):
                return .deny(reason: "параметр \(token) запрещён; \(rule)")
            default:
                urls.append(token)
            }
            index += 1
        }
        guard urls.count == 1, let url = urls.first else {
            return .deny(reason: "нужен ровно один адрес; \(rule)")
        }
        guard url.hasPrefix(urlPrefix), url.dropFirst(urlPrefix.count).allSatisfy(urlCharacters.contains) else {
            return .deny(reason: rule)
        }
        return .allow
    }

    private struct TokenizeFailure: Error {
        let reason: String
    }

    /// A minimal shell-word splitter, over Unicode scalars rather than `Character`s: Swift folds
    /// CR LF into one `Character`, and bash does not — it reads backslash-CR as an escaped CR and
    /// the LF then ends the command, so the next line runs on its own.
    ///
    /// Outside quotes, words are separated only by space, tab and an unquoted backslash followed
    /// directly by LF; any other control or space character fails. Single quotes are literal,
    /// double quotes are literal as long as they hold no `$`, backtick or backslash; inside either,
    /// control characters other than LF and tab fail too.
    private static func tokenize(_ command: String) -> Result<[String], TokenizeFailure> {
        enum Quote { case none, single, double }
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var quote = Quote.none
        let scalars = Array(command.unicodeScalars)
        var index = 0

        func endWord() {
            if inWord { words.append(String(word)) }
            word = String.UnicodeScalarView()
            inWord = false
        }
        let control = TokenizeFailure(reason: "управляющие символы и необычные пробелы запрещены")

        while index < scalars.count {
            let scalar = scalars[index]
            switch quote {
            case .single, .double:
                if scalar.properties.generalCategory == .control, scalar != "\n", scalar != "\t" {
                    return .failure(control)
                }
                if quote == .single {
                    if scalar == "'" { quote = .none } else { word.append(scalar) }
                } else if scalar == "\"" {
                    quote = .none
                } else if scalar == "$" || scalar == "`" || scalar == "\\" {
                    return .failure(TokenizeFailure(reason: "в двойных кавычках нельзя $, ` и \\"))
                } else {
                    word.append(scalar)
                }
            case .none:
                if scalar == " " || scalar == "\t" {
                    endWord()
                } else if scalar == "\\" {
                    guard index + 1 < scalars.count, scalars[index + 1] == "\n" else {
                        return .failure(TokenizeFailure(reason: "обратная косая черта разрешена только для переноса строки"))
                    }
                    endWord()
                    index += 1
                } else if scalar == "\n" {
                    return .failure(TokenizeFailure(reason: "только одна команда"))
                } else if isSpaceOrControl(scalar) {
                    return .failure(control)
                } else if scalar == "'" {
                    quote = .single
                    inWord = true
                } else if scalar == "\"" {
                    quote = .double
                    inWord = true
                } else if shellSyntax.contains(scalar) {
                    return .failure(TokenizeFailure(
                        reason: "символ \(scalar) вне кавычек запрещён: цепочки, подстановки и перенаправления нельзя"))
                } else {
                    word.append(scalar)
                    inWord = true
                }
            }
            index += 1
        }
        guard quote == .none else { return .failure(TokenizeFailure(reason: "незакрытая кавычка")) }
        endWord()
        guard !words.isEmpty else { return .failure(TokenizeFailure(reason: "пустая команда")) }
        return .success(words)
    }

    /// Controls, format characters (zero-width and the like) and every kind of space or separator.
    private static func isSpaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    /// The PreToolUse hook's whole job, given its stdin. Exit 0 lets the call go on to the normal
    /// permission flow; exit 2 blocks it and hands stderr to the agent. Anything unreadable blocks.
    public static func hookDecision(stdin: Data) -> (exitCode: Int32, stderr: String) {
        guard let object = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let tool = object["tool_name"] as? String
        else {
            return (2, "Фильтр команд не понял запрос — вызов отклонён")
        }
        // Other tools are governed by `--tools` and `--add-dir`.
        guard tool == "Bash" else { return (0, "") }
        guard let input = object["tool_input"] as? [String: Any], let command = input["command"] as? String else {
            return (2, "Фильтр команд не нашёл команду — вызов отклонён")
        }
        switch verdict(command) {
        case .allow: return (0, "")
        case .deny(let reason): return (2, "Команда отклонена: \(reason)")
        }
    }

    /// Reads the hook input from stdin, writes the reason to stderr, and exits with the decision.
    public static func runHook() -> Never {
        let decision = hookDecision(stdin: FileHandle.standardInput.readDataToEndOfFile())
        if !decision.stderr.isEmpty {
            FileHandle.standardError.write(Data((decision.stderr + "\n").utf8))
        }
        exit(decision.exitCode)
    }
}
