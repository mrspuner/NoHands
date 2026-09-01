import Core
import Foundation

let usage = """
nohands — инструмент прогонов фазы 0

nohands compare <наша-расшифровка.txt> <эталон.txt>
    Сверяет два текста пословно и печатает расхождения.

nohands transcribe <файл> --engine whisper [--language ru]
    Распознаёт файл локальной моделью Whisper и печатает текст.
    Код языка двухбуквенный, ISO-639-1: ru, en. Без --language язык определяет модель.

nohands transcribe <файл> --engine scribe [--language rus] [--keyterms "термин,термин"]
    Распознаёт файл через ElevenLabs Scribe v2 и печатает текст.
    Код языка трёхбуквенный, ISO-639-3: rus, eng. Без --language язык определяет сервис.
    --keyterms работает только с этим движком.

nohands record <секунд> <выход.wav>
    Пишет микрофон в WAV 16 кГц моно. Печатает устройство и формат перед записью.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func readFile(_ path: String) -> String {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("Не удалось прочитать файл: \(path)")
    }
    return content
}

@main
struct NoHands {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = arguments.first else {
            fail(usage)
        }

        // Every real failure — a missing key, HTTP 401, an unreadable file, an empty result,
        // an unavailable model — arrives here. Letting it escape `main` instead would make the
        // Swift runtime print `Fatal error: Error raised at top level:` with the raw reflected
        // value and exit 133, never calling `errorDescription`. The owner would get a trace
        // where a sentence was written for them.
        do {
            switch command {
            case "compare":
                runCompare(arguments)
            case "transcribe":
                try await runTranscribe(arguments)
            case "record":
                try await runRecord(arguments)
            default:
                fail("Неизвестная команда: \(command)\n\n\(usage)")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func runCompare(_ arguments: [String]) {
        guard arguments.count == 3 else {
            fail("Использование: nohands compare <наша-расшифровка.txt> <эталон.txt>")
        }
        let ours = readFile(arguments[1])
        let referenceRaw = readFile(arguments[2])

        let reference = ReferenceTranscript.parse(referenceRaw)
        guard !reference.text.isEmpty else {
            fail("В эталоне не нашлось ни одной строки с таймкодом — проверьте формат файла")
        }
        note("эталон: взято \(reference.spokenLines) строк из \(reference.nonEmptyLines) непустых")

        let result = WordDiff.compare(
            reference: TextNormalizer.words(from: reference.text),
            candidate: TextNormalizer.words(from: ours)
        )
        print(ComparisonReport.render(result))
    }

    static func runTranscribe(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            fail("Использование: nohands transcribe <файл> --engine whisper|scribe [--language <код>] [--keyterms \"термин,термин\"]")
        }
        let url = URL(fileURLWithPath: arguments[1])

        var engine = "whisper"
        var language: String? = nil
        var keyterms: [String] = []
        var keytermsGiven = false
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
            case "--keyterms":
                guard index + 1 < arguments.count else { fail("--keyterms без значения") }
                keytermsGiven = true
                keyterms = arguments[index + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                index += 2
            default:
                fail("Неизвестный аргумент: \(arguments[index])")
            }
        }

        let started = Date()
        let transcriber: any Transcriber
        switch engine {
        case "whisper":
            // Whisper has no keyterm prompting at all; accepting the flag and dropping it
            // would leave the owner reading a run they think was biased and wasn't.
            if keytermsGiven {
                fail("--keyterms поддерживается только движком scribe, у whisper такого параметра нет")
            }
            transcriber = try await WhisperTranscriber.load(language: language)
        case "scribe":
            transcriber = try ScribeTranscriber.fromKeychain(language: language, keyterms: keyterms)
        default:
            fail("Неизвестный движок: \(engine). Поддерживаются whisper и scribe")
        }
        let ready = Date()
        let text = try await transcriber.transcribe(audio: url)
        let finished = Date()

        note("""
        движок готов за \(String(format: "%.1f", ready.timeIntervalSince(started))) с
        распознавание заняло \(String(format: "%.1f", finished.timeIntervalSince(ready))) с
        """)
        print(text)
    }

    static func runRecord(_ arguments: [String]) async throws {
        guard arguments.count == 3 else {
            fail("Использование: nohands record <секунд> <выход.wav>")
        }
        guard let seconds = Double(arguments[1]), seconds > 0, seconds.isFinite else {
            fail("Длительность должна быть положительным числом секунд, получено: \(arguments[1])")
        }
        let output = URL(fileURLWithPath: arguments[2])

        guard let device = AudioInputDevice.current() else {
            fail("Устройство ввода не найдено. У Mac mini нет встроенного микрофона — подключите внешний")
        }
        print("устройство: \(device.name)")
        print("формат входа: \(Int(device.sampleRate)) Гц, каналов \(device.channelCount)")
        if device.sampleRate < 32000 {
            print("ВНИМАНИЕ: частота ниже 32 кГц — это узкополосный режим, качество распознавания будет заниженным")
        }
        print("пишу \(seconds) с…")

        try await MicrophoneRecorder().record(seconds: seconds, to: output)
        print("готово: \(output.path)")
    }
}
