import Core
import Dictation
import Foundation

let usage = """
nohands — инструмент прогонов фазы 0

nohands compare <наша-расшифровка.txt> <эталон.txt>
    Сверяет два текста пословно и печатает расхождения.

nohands transcribe <файл> --engine scribe [--language rus] [--keyterms "термин,термин"]
    Распознаёт файл через ElevenLabs Scribe v2 и печатает текст.
    Код языка трёхбуквенный, ISO-639-3: rus, eng. Без --language язык определяет сервис.
    --keyterms работает только с этим движком.

nohands transcribe <файл> --engine parakeet [--language ru]
    Распознаёт файл локальной моделью Parakeet TDT v3 (FluidAudio) и печатает текст. Движок по умолчанию.
    Код языка двухбуквенный, ISO-639-1: ru, en. Влияет только на выбор письменности среди
    похожих кандидатов при декодировании, а не на выбор языка модели — та многоязычная всегда.
    --keyterms к этому движку не относится.

nohands record <секунд> <выход.wav>
    Пишет микрофон в WAV 16 кГц моно. Печатает устройство и формат перед записью.

nohands dictate [--raw]
    Диктовка целиком: запись микрофона до Enter, распознавание Parakeet,
    чистка через DeepSeek, вывод текста. --raw печатает текст без чистки.

nohands meeting process <папка встречи>
    Прогоняет папку из ~/Meetings/.queue заново и перезаписывает markdown.

nohands meeting levels <папка встречи>
    Печатает реплики дорожки микрофона с их уровнем в dBFS. Крестик слева — реплика
    не проходит текущий порог micThresholdDBFS. Инструмент подбора порога.
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

/// `nil` at or above 32 kHz. Below that, macOS is most often reporting a Bluetooth headset's
/// mic (AirPods included) — DESIGN.md calls that the worst input the app can have, since the
/// same negotiation also narrows the system audio track and diarization degrades on it.
/// Recording is still allowed at any rate; this only makes the tradeoff explicit instead of a
/// generic "качество будет заниженным" line that named neither the rate nor the likely cause.
func narrowbandWarning(sampleRate: Double) -> String? {
    guard sampleRate < AudioInputDevice.narrowbandThreshold else { return nil }
    return """
    ВНИМАНИЕ: вход \(Int(sampleRate)) Гц — узкополосный режим, такая запись не годится для \
    оценки качества распознавания. Типичная причина — подключённая Bluetooth-гарнитура \
    (например, AirPods): проверьте вход в системных настройках звука
    """
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
            case "dictate":
                try await runDictate(arguments)
            case "meeting":
                let parsed: MeetingArguments
                do {
                    parsed = try MeetingArguments.parse(arguments)
                } catch MeetingArguments.ParseError.message(let message) {
                    fail(message)
                }
                switch parsed.subcommand {
                case .process:
                    try await runMeetingProcess(parsed.folder)
                case .levels:
                    try await runMeetingLevels(parsed.folder)
                }
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
        case "scribe":
            transcriber = try ScribeTranscriber.fromKeychain(language: parsed.language, keyterms: parsed.keyterms)
        case "parakeet":
            transcriber = try await ParakeetTranscriber.load(language: parsed.language)
        default:
            fail("Неизвестный движок: \(parsed.engine). Поддерживаются scribe и parakeet")
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
        if let warning = narrowbandWarning(sampleRate: device.sampleRate) {
            print(warning)
        }
        print("пишу \(seconds) с…")

        try await MicrophoneRecorder().record(seconds: seconds, to: output)
        print("готово: \(output.path)")
    }

    static func runDictate(_ arguments: [String]) async throws {
        let parsed: DictateArguments
        do {
            parsed = try DictateArguments.parse(arguments)
        } catch DictateArguments.ParseError.message(let message) {
            fail(message)
        }

        let config = try DictationConfig.loadOrCreate()

        // Checked before recording starts, not after: this command records first and cleans
        // afterwards, so a missing key discovered only at cleanup time would cost the owner a
        // spoken sentence they cannot get back. `--raw` never cleans, so it never needs a key.
        let client: DeepSeekClient? = try parsed.raw ? nil : DeepSeekClient.fromKeychain(
            model: config.model, prompt: config.prompt, timeout: config.timeoutSeconds
        )

        guard let device = AudioInputDevice.current() else {
            fail("Устройство ввода не найдено. У Mac mini нет встроенного микрофона — подключите внешний")
        }
        print("устройство: \(device.name)")
        if let warning = narrowbandWarning(sampleRate: device.sampleRate) {
            print(warning)
        }

        // The model is loaded before recording starts, the way the application will hold it
        // resident — otherwise the load time would land inside the measured latency and make
        // dictation look slower than it is.
        let loadStarted = Date()
        let transcriber = try await ParakeetTranscriber.load(language: config.language)
        note("модель готова за \(String(format: "%.1f", Date().timeIntervalSince(loadStarted))) с")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nohands-dictate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = MicrophoneRecorder()
        try await recorder.start(to: url)
        print("пишу… Enter — стоп")
        _ = readLine()
        let file = try await recorder.stop()

        let recognitionStarted = Date()
        let rawText = try await transcriber.transcribe(audio: file)
        let recognized = Date()
        note("распознавание \(String(format: "%.2f", recognized.timeIntervalSince(recognitionStarted))) с")

        guard let client else {
            print(rawText)
            return
        }

        let cleaned = try await client.clean(rawText)
        note("чистка \(String(format: "%.2f", Date().timeIntervalSince(recognized))) с")
        print(cleaned)
    }
}
