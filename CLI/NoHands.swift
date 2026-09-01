import Core
import Foundation

func printUsage() {
    print("""
    nohands — инструмент прогонов фазы 0

    nohands compare <наша-расшифровка.txt> <эталон.txt>
        Сверяет два текста пословно и печатает расхождения.

    nohands transcribe <файл> --engine whisper [--language ru]
        Распознаёт файл локальной моделью и печатает текст.
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readFile(_ path: String) -> String {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("Не удалось прочитать файл: \(path)")
    }
    return content
}

@main
struct NoHands {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = arguments.first else {
            printUsage()
            exit(1)
        }

        switch command {
        case "compare":
            guard arguments.count == 3 else {
                fail("Использование: nohands compare <наша-расшифровка.txt> <эталон.txt>")
            }
            let ours = readFile(arguments[1])
            let referenceRaw = readFile(arguments[2])

            let referenceText = ReferenceTranscript.spokenText(from: referenceRaw)
            guard !referenceText.isEmpty else {
                fail("В эталоне не нашлось ни одной строки с таймкодом — проверьте формат файла")
            }

            let result = WordDiff.compare(
                reference: TextNormalizer.words(from: referenceText),
                candidate: TextNormalizer.words(from: ours)
            )
            print(ComparisonReport.render(result))

        case "transcribe":
            guard arguments.count >= 2 else {
                fail("Использование: nohands transcribe <файл> --engine whisper [--language ru]")
            }
            let path = arguments[1]
            let url = URL(fileURLWithPath: path)

            var engine = "whisper"
            var language: String? = nil
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--engine":
                    guard index + 1 < arguments.count else { fail("--engine без значения") }
                    engine = arguments[index + 1]
                    index += 2
                case "--language":
                    guard index + 1 < arguments.count else { fail("--language без значения") }
                    language = arguments[index + 1]
                    index += 2
                default:
                    fail("Неизвестный аргумент: \(arguments[index])")
                }
            }

            guard engine == "whisper" else {
                fail("Пока поддерживается только --engine whisper")
            }

            let started = Date()
            let transcriber = try await WhisperTranscriber.load(language: language)
            let loaded = Date()
            let text = try await transcriber.transcribe(audio: url)
            let finished = Date()

            FileHandle.standardError.write(Data("""
            модель загружена за \(String(format: "%.1f", loaded.timeIntervalSince(started))) с
            распознавание заняло \(String(format: "%.1f", finished.timeIntervalSince(loaded))) с

            """.utf8))
            print(text)

        default:
            printUsage()
            exit(1)
        }
    }
}
