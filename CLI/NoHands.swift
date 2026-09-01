import Core
import Foundation

let usage = """
nohands — инструмент прогонов фазы 0

nohands compare <наша-расшифровка.txt> <эталон.txt>
    Сверяет два текста пословно и печатает расхождения.

nohands transcribe <файл> --engine whisper [--language ru] [--model <имя>] [--vad] [--relaxed-thresholds]
    Распознаёт файл локальной моделью Whisper и печатает текст.
    Код языка двухбуквенный, ISO-639-1: ru, en. Без --language язык определяет модель.
    --model задаёт сборку модели, по умолчанию \(WhisperTranscriber.defaultModel).
    --vad нарезает аудио по обнаруженной речи вместо слепых 30-секундных окон.
    --relaxed-thresholds ослабляет пороги отбраковки неуверенных фрагментов.
    Все три флага только для whisper, у scribe таких параметров нет.

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
        let parsed: TranscribeArguments
        do {
            parsed = try TranscribeArguments.parse(arguments)
        } catch TranscribeArguments.ParseError.message(let message) {
            fail(message)
        }
        let url = parsed.url

        let started = Date()
        let transcriber: any Transcriber
        switch parsed.engine {
        case "whisper":
            transcriber = try await WhisperTranscriber.load(
                model: parsed.model ?? WhisperTranscriber.defaultModel,
                language: parsed.language,
                useVAD: parsed.useVAD,
                relaxedThresholds: parsed.relaxedThresholds
            )
        case "scribe":
            transcriber = try ScribeTranscriber.fromKeychain(language: parsed.language, keyterms: parsed.keyterms)
        default:
            fail("Неизвестный движок: \(parsed.engine). Поддерживаются whisper и scribe")
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
