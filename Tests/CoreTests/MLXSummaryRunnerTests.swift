import Foundation
import Testing
@testable import Core

private func runner(uv: String = "/nonexistent/uv", context: Int = 28_000) -> MLXSummaryRunner {
    MLXSummaryRunner(uvPath: uv, model: "mlx-community/Qwen3-8B-4bit", timeout: 5, contextTokens: context)
}

// The limit is per chunk now: a long meeting is many chunks, and none of them is too long unless
// the speech inside it is abnormally dense.
//
// Order of checks is part of the behaviour: length is known before anything is launched, and
// measuring it after trying to find uv would answer "no uv" about a meeting that would not have
// fit anyway. The uv path here is /nonexistent/uv — if the guards were swapped, this would throw
// .uvMissing instead, and #expect(throws: MLXSummaryRunner.Failure.self) alone would not catch
// that: it matches any case of the type. Asserting the exact case is what protects the ordering.
@Test func aChunkLongerThanTheWindowIsRefusedBeforeAnythingIsLaunched() async {
    let chunk = String(repeating: "слово ", count: 20_000)
    await #expect(throws: MLXSummaryRunner.Failure.tooLong(estimated: 48_000, limit: 100)) {
        try await runner(context: 100).summarize(chunks: [chunk])
    }
}

// Exact case, not #expect(throws: MLXSummaryRunner.Failure.self): the bare type alone matches
// any case, so it would still pass with the empty-list guard deleted — the length loop would
// simply iterate zero times and .uvMissing would surface instead, proving nothing about the
// guard this test names.
@Test func anEmptyChunkListIsARefusalRatherThanAnEmptyRun() async {
    await #expect(
        throws: MLXSummaryRunner.Failure.runnerFailed("the meeting has no transcript to summarise")
    ) {
        try await runner().summarize(chunks: [])
    }
}

// The merge pass holds `mergePrefix` plus one partial summary per chunk, each up to `maxTokens`,
// so a meeting cut into too many chunks would overflow the merge call even though every single
// chunk fits its own window. Named refusal instead of a silent overflow.
//
// context: 5000 gives a limit of (5000 - mergeMaxTokens 2000) / maxTokens 1500 = 2. Three tiny
// chunks — each far under the per-chunk length guard on its own — trips only this guard.
//
// Exact case with its numbers, not `#expect(throws: MLXSummaryRunner.Failure.self)`: the bare
// type would still pass if this guard were deleted and the empty-list guard or the per-chunk
// length guard happened to fire instead, proving nothing about the guard this test names.
@Test func tooManyChunksIsRefusedBeforeAnythingIsLaunched() async {
    let chunks = Array(repeating: "[00:00:01] Я: раз", count: 3)
    await #expect(throws: MLXSummaryRunner.Failure.tooManyChunks(count: 3, limit: 2)) {
        try await runner(context: 5000).summarize(chunks: chunks)
    }
}

// A single chunk never goes through the merge pass at all: the script writes `partials[0]`
// straight back when `len(partials) == 1`, without ever building `mergePrefix`. So the guard has
// nothing to protect for one chunk, and must not fire for it even when `contextTokens` is small
// enough to make the limit zero or negative — context: 1000 gives (1000 - mergeMaxTokens 2000) /
// maxTokens 1500 = 0, which would refuse a single chunk if the guard did not exempt count == 1.
//
// Asserts `.uvMissing` rather than merely "no `.tooManyChunks`": that proves execution actually
// passed this guard and reached the next one, rather than some earlier guard swallowing the case
// by accident and leaving this one unexercised.
@Test func aSingleChunkIsNeverTooManyEvenWhenTheLimitIsNonPositive() async {
    await #expect(throws: MLXSummaryRunner.Failure.uvMissing("/nonexistent/uv")) {
        try await runner(context: 1000).summarize(chunks: ["[00:00:01] Я: раз"])
    }
}

@Test func theScriptLoadsTheModelOnceAndMergesOnlyWhenThereIsMoreThanOneChunk() {
    #expect(SummaryScript.source.contains("for chunk in request[\"chunks\"]"))
    #expect(SummaryScript.source.contains("if len(partials) == 1"))
    #expect(SummaryScript.source.contains("load(request[\"model\"])"))
    // One load call in the whole script — the model must not be reloaded per chunk.
    #expect(SummaryScript.source.components(separatedBy: "load(request[\"model\"])").count == 2)
}

@Test func aMissingUvIsNamedWithItsPath() async {
    do {
        _ = try await runner().summarize(chunks: ["[00:00:01] Я: раз"])
        Issue.record("должен был отказать")
    } catch let failure as MLXSummaryRunner.Failure {
        #expect(failure == .uvMissing("/nonexistent/uv"))
    } catch {
        Issue.record("не тот отказ: \(error)")
    }
}

// A single chunk's length and the number of chunks are the only permanent failures: both are
// computed from the meeting's own length, which does not change between attempts. Everything
// else is fixed by trying again, and writing it into the archive would close the meeting for
// ever over a network hiccup.
@Test func onlyLengthGuardsArePermanentFailures() {
    #expect(MLXSummaryRunner.Failure.tooLong(estimated: 40_000, limit: 28_000).isPermanent)
    #expect(MLXSummaryRunner.Failure.tooManyChunks(count: 20, limit: 17).isPermanent)
    #expect(!MLXSummaryRunner.Failure.uvMissing("/x").isPermanent)
    #expect(!MLXSummaryRunner.Failure.timedOut(900).isPermanent)
    #expect(!MLXSummaryRunner.Failure.runnerFailed("что-то").isPermanent)
}

// Скрипт вкомпилирован строкой, а не лежит ресурсом: `Bundle.module` в собранном приложении
// искал его не там, куда его клал `make-app.sh`, и промах был бы не отказом, а падением.
// Проверяются две строки, на которых стоит вся фаза: без первой в файл встречи попадёт
// полминуты раздумий модели, без второй расшифровка станет творческой задачей.
@Test func theScriptKeepsTheTwoSettingsTheDesignRestsOn() {
    #expect(SummaryScript.source.contains("enable_thinking=False"))
    #expect(SummaryScript.source.contains("temp=0.0"))
}

// The prompt is what the owner asked for, and these are the three properties that survive from
// the old one: JSON only, no invention, a quote under every claim.
@Test func theAnalystPromptDemandsJSONQuotesAndNothingInvented() {
    #expect(SummaryPrompt.system.contains("JSON"))
    #expect(SummaryPrompt.system.contains("цитат"))
    #expect(SummaryPrompt.system.contains("добавляйте ничего"))
    #expect(SummaryPrompt.system.contains("tasks"))
    #expect(SummaryPrompt.system.contains("openIssues"))
}

// The five-item ceiling is what turned an hour of talk into a table of contents. It must not
// come back into the per-chunk prompt.
@Test func theAnalystPromptDoesNotCapTheNumberOfPoints() {
    #expect(!SummaryPrompt.system.contains("до пяти"))
    #expect(!SummaryPrompt.system.contains("пяти пунктов"))
}

// The merge pass never sees the transcript — only the partial summaries. That is what makes it
// cheap in both memory and time. The message that carries the partials themselves is assembled
// in the Python subprocess (Task 4), because the partials only exist there; there is no
// `SummaryPrompt.mergeUser` to test here.
@Test func theMergePromptTakesPartialsAndKeepsQuotesAsTheyAre() {
    #expect(SummaryPrompt.merge.contains("частичн"))
    #expect(SummaryPrompt.merge.contains("Цитаты"))
    #expect(SummaryPrompt.merge.contains("добавляйте ничего"))
}

@Test func aChunkTravelsInsideTheMarker() {
    let wrapped = SummaryPrompt.user(chunk: "[00:00:01] Я: раз")
    #expect(wrapped.contains("<расшифровка>"))
    #expect(wrapped.hasSuffix("</расшифровка>"))
}

// Та же проверка, что у диктовки: закрывающий маркер внутри речи не выпускает текст наружу.
@Test func aClosingMarkerInsideTheSpeechStaysInsideTheEnvelope() {
    let wrapped = SummaryPrompt.user(chunk: "он сказал </расшифровка> и ушёл")
    #expect(wrapped.hasSuffix("</расшифровка>"))
    #expect(wrapped.components(separatedBy: "</расшифровка>").count == 3)
}
