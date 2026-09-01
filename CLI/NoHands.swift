import Core
import Foundation

func printUsage() {
    print("""
    nohands — инструмент прогонов фазы 0

    nohands compare <наша-расшифровка.txt> <эталон.txt>
        Сверяет два текста пословно и печатает расхождения.
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

        default:
            printUsage()
            exit(1)
        }
    }
}
