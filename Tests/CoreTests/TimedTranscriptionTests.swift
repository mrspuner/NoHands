import AVFoundation
import Foundation
import Testing
@testable import Core

private var fixtureURL: URL? {
    guard let path = ProcessInfo.processInfo.environment["NOHANDS_TIMED_FIXTURE"] else { return nil }
    return URL(fileURLWithPath: path)
}

// Единственная проверка в проекте, которой нужны и модель, и настоящий длинный файл. Пропускается,
// когда записи нет: она про то, чего не видно в чистых тестах — что таймкоды у длинного файла
// сквозные, а не отсчитываются заново в каждом куске по тридцать секунд.
@Test(.enabled(if: fixtureURL != nil))
func timedTranscriptionOfALongFileHasGlobalTimestamps() async throws {
    let url = try #require(fixtureURL)
    let transcriber = try await ParakeetTranscriber.load(language: "ru")
    let words = try await transcriber.transcribeTimed(audio: url)

    #expect(!words.isEmpty, "в записи не нашлось ни одного слова")

    // Куски у FluidAudio по тридцать секунд. Слово, начинающееся позже, доказывает, что времена
    // не сбрасываются на границе куска.
    let latest = words.map(\.start).max() ?? 0
    #expect(latest > 30, "все слова уместились в первые 30 с — таймкоды похожи на локальные")

    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    #expect(latest <= duration + 1, "слово начинается позже конца файла")

    for (previous, next) in zip(words, words.dropFirst()) {
        #expect(previous.start <= next.start, "слова пришли не по порядку")
    }
}
