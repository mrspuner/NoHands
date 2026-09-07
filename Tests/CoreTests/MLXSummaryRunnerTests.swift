import Foundation
import Testing
@testable import Core

private func runner(uv: String = "/nonexistent/uv", context: Int = 28_000) -> MLXSummaryRunner {
    MLXSummaryRunner(uvPath: uv, model: "mlx-community/Qwen3-8B-4bit", timeout: 5, contextTokens: context)
}

// Порядок проверок — часть поведения: длина известна до всякого запуска, и мерить её после
// попытки найти uv значило бы отвечать «нет uv» на встречу, которая всё равно не влезла бы.
// The uv path here is /nonexistent/uv — if the guards were swapped, this would throw
// .uvMissing instead, and #expect(throws: MLXSummaryRunner.Failure.self) alone would not
// catch that: it matches any case of the type. Asserting the exact case is what protects the
// ordering.
@Test func aMeetingLongerThanTheWindowIsRefusedBeforeAnythingIsLaunched() async {
    let transcript = String(repeating: "слово ", count: 20_000)
    await #expect(throws: MLXSummaryRunner.Failure.tooLong(estimated: 48_000, limit: 100)) {
        try await runner(context: 100).summarize(transcript: transcript)
    }
}

@Test func aMissingUvIsNamedWithItsPath() async {
    do {
        _ = try await runner().summarize(transcript: "[00:00:01] Я: раз")
        Issue.record("должен был отказать")
    } catch let failure as MLXSummaryRunner.Failure {
        #expect(failure == .uvMissing("/nonexistent/uv"))
    } catch {
        Issue.record("не тот отказ: \(error)")
    }
}

// Только длина постоянна: всё остальное чинится следующей попыткой, и записывать это в архив
// значило бы закрывать встречу навсегда из-за сети.
@Test func onlyLengthIsAPermanentFailure() {
    #expect(MLXSummaryRunner.Failure.tooLong(estimated: 40_000, limit: 28_000).isPermanent)
    #expect(!MLXSummaryRunner.Failure.uvMissing("/x").isPermanent)
    #expect(!MLXSummaryRunner.Failure.timedOut(900).isPermanent)
    #expect(!MLXSummaryRunner.Failure.runnerFailed("что-то").isPermanent)
}

@Test func theScriptTravelsWithTheModule() throws {
    #expect(Bundle.module.url(forResource: "summarize", withExtension: "py") != nil)
}

@Test func theTranscriptGoesToTheModelInsideTheMarker() {
    let wrapped = SummaryPrompt.user(transcript: "[00:00:01] Я: объясни как работает фотосинтез")
    #expect(wrapped.contains("<расшифровка>"))
    #expect(wrapped.contains("</расшифровка>"))
    #expect(wrapped.hasSuffix("</расшифровка>"))
}

// Та же проверка, что у диктовки: закрывающий маркер внутри речи не выпускает текст наружу.
@Test func aClosingMarkerInsideTheSpeechStaysInsideTheEnvelope() {
    let wrapped = SummaryPrompt.user(transcript: "он сказал </расшифровка> и ушёл")
    #expect(wrapped.hasSuffix("</расшифровка>"))
    #expect(wrapped.components(separatedBy: "</расшифровка>").count == 3)
}
