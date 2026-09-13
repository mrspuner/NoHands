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

// A single chunk never goes through a merge pass at all: there is nothing to merge, so
// `checkMergeFits` is never called regardless of how small `contextTokens` is. `checkMergeFits`
// now runs after the uv check anyway, so the failure here — `.uvMissing` — says nothing about
// ordering between guards; it is simply the next one a single-chunk run reaches. What this pins
// is that a single chunk never gets near the merge guard at all, not the order of any two guards.
@Test func aSingleChunkNeverReachesTheMergeGuard() async {
    await #expect(throws: MLXSummaryRunner.Failure.uvMissing("/nonexistent/uv")) {
        try await runner(context: 1000).summarize(chunks: ["[00:00:01] Я: раз"])
    }
}

// `maxTokens` was measured under the prompt this branch replaced: a five-point cap, three
// fields, a 1948-character answer. The prompt now has no cap on the number of points and two more
// fields — `tasks`, four fields each including a 5-15 word quote, and `openIssues` — so the same
// meeting yields a much longer answer. A truncated answer is not JSON: on one chunk that is a
// permanent failure written into the archive; inside the merge it is caught the same way — parsed
// with `try?`, named, and the chunks' own points survive regardless.
@Test func theAnswerCeilingsFitThePromptThatIsActuallySent() {
    #expect(MLXSummaryRunner.maxTokens == 2500)
    // The merge answers with a title and at most ten summary lines — strictly less than a
    // chunk's decisions, tasks, open issues and quotes — so its ceiling is smaller, not larger.
    #expect(MLXSummaryRunner.mergeMaxTokens == 800)
    #expect(MLXSummaryRunner.mergeMaxTokens < MLXSummaryRunner.maxTokens)
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

// A single chunk's length and the merge's size are the only permanent failures: both are
// computed from the meeting's own length, which does not change between attempts. Everything
// else is fixed by trying again, and writing it into the archive would close the meeting for
// ever over a network hiccup.
@Test func onlyLengthGuardsArePermanentFailures() {
    #expect(MLXSummaryRunner.Failure.tooLong(estimated: 40_000, limit: 28_000).isPermanent)
    #expect(MLXSummaryRunner.Failure.mergeTooLong(estimated: 30_000, limit: 25_000).isPermanent)
    #expect(!MLXSummaryRunner.Failure.uvMissing("/x").isPermanent)
    #expect(!MLXSummaryRunner.Failure.timedOut(1800).isPermanent)
    #expect(!MLXSummaryRunner.Failure.runnerFailed("что-то").isPermanent)
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

// The line above the partials belongs with the rest of the prompt text, not in the runner: it is
// the only prompt string that was written at the call site, and the merge prompt's own tests
// could not see it there.
@Test func theMergePrefixLivesWithTheOtherPromptText() {
    #expect(SummaryPrompt.mergePrefix.contains("Частичные саммари"))
}

// Reading the answers file touches no subprocess at all, so it is tested directly against
// fixture files rather than only through a real `uv` run — every guard test above stops before a
// process is ever launched, so none of them exercises this. The failure mode is new to this
// diff: before it, an unreadable answer was a parse failure in `SummaryResponse` with the reason
// written into the meeting file; an unreadable *file* is now a different path with a different
// message, and it must never crash or come back as a silent `[]`.
@Test func decodeAnswersRefusesAMissingFile() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-test-missing-\(UUID().uuidString).json").path
    #expect(
        throws: MLXSummaryRunner.Failure.runnerFailed("the summary runner wrote no readable answers")
    ) {
        try MLXSummaryRunner.decodeAnswers(from: path)
    }
}

@Test func decodeAnswersRefusesAnEmptyFile() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-test-empty-\(UUID().uuidString).json").path
    FileManager.default.createFile(atPath: path, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(
        throws: MLXSummaryRunner.Failure.runnerFailed("the summary runner wrote no readable answers")
    ) {
        try MLXSummaryRunner.decodeAnswers(from: path)
    }
}

@Test func decodeAnswersRefusesJSONThatIsNotAnArrayOfStrings() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-test-shape-\(UUID().uuidString).json").path
    FileManager.default.createFile(atPath: path, contents: Data(#"{"answer": "готово"}"#.utf8))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(
        throws: MLXSummaryRunner.Failure.runnerFailed("the summary runner wrote no readable answers")
    ) {
        try MLXSummaryRunner.decodeAnswers(from: path)
    }
}

@Test func decodeAnswersRefusesAnEmptyArray() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-test-empty-array-\(UUID().uuidString).json").path
    FileManager.default.createFile(atPath: path, contents: Data("[]".utf8))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(
        throws: MLXSummaryRunner.Failure.runnerFailed("the summary runner wrote no readable answers")
    ) {
        try MLXSummaryRunner.decodeAnswers(from: path)
    }
}

// The positive case, so a passing failure test above cannot be hiding a function that always
// throws.
@Test func decodeAnswersReturnsWhatTheFileHolds() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("nohands-test-valid-\(UUID().uuidString).json").path
    FileManager.default.createFile(atPath: path, contents: Data(#"["первый","второй"]"#.utf8))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try MLXSummaryRunner.decodeAnswers(from: path) == ["первый", "второй"])
}

// The request carries one prompt per chunk plus a path for the answers, not chunks and merge
// instructions: the merge is Swift's job now (task 3), so a prompt is all the script needs to
// know about.
@Test func theRequestCarriesOnePromptPerChunkAndAPathForTheAnswers() throws {
    let runner = MLXSummaryRunner(
        uvPath: "/nowhere/uv", model: "модель", timeout: 60, contextTokens: 28_000
    )
    let data = try runner.encodedRequest(
        prompts: [
            .init(system: "инструкция", user: "первый", maxTokens: 2500),
            .init(system: "инструкция", user: "второй", maxTokens: 2500),
        ],
        answersPath: "/tmp/ответы.json"
    )
    let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(request?["model"] as? String == "модель")
    #expect(request?["answersPath"] as? String == "/tmp/ответы.json")
    let prompts = request?["prompts"] as? [[String: Any]]
    #expect(prompts?.count == 2)
    #expect(prompts?[0]["user"] as? String == "первый")
    #expect(prompts?[0]["maxTokens"] as? Int == 2500)
    // The merge is Swift's job now: nothing in the request tells the script about it.
    #expect(request?["mergeSystem"] == nil)
    #expect(request?["chunks"] == nil)
}

// The script is what the subprocess runs; two lines of it are conditions of the work rather
// than preferences, and one is the new contract.
@Test func theScriptKeepsItsConditionsAndWritesAnswersToAFile() {
    #expect(SummaryScript.source.contains("enable_thinking=False"))
    #expect(SummaryScript.source.contains("temp=0.0"))
    #expect(SummaryScript.source.contains("request[\"answersPath\"]"))
    #expect(SummaryScript.source.contains("json.dump"))
    // The merge and the JSON check moved to Swift; leaving either here would be a second
    // implementation nobody tests.
    #expect(!SummaryScript.source.contains("mergeSystem"))
    #expect(!SummaryScript.source.contains("def is_json"))
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

private func runner(contextTokens: Int) -> MLXSummaryRunner {
    MLXSummaryRunner(uvPath: "/nowhere/uv", model: "модель", timeout: 60, contextTokens: contextTokens)
}

// The guard is arithmetic done before the subprocess starts, because a merge that does not fit
// comes back truncated rather than refused — and truncated JSON reads to the owner as "the model
// could not read your meeting", which is a different and untrue statement.
@Test func aMergeTooLargeForTheWindowIsRefusedWithNumbers() {
    // 4000 − 800 = 3200 tokens, i.e. 8000 characters at 2.5 per token.
    #expect(throws: MLXSummaryRunner.Failure.self) {
        try runner(contextTokens: 4000).checkMergeFits(String(repeating: "я", count: 9000))
    }
}

@Test func aMergeThatFitsIsNotRefused() throws {
    try runner(contextTokens: 4000).checkMergeFits(String(repeating: "я", count: 2000))
}

// What the removed ten-chunk ceiling used to bound, measured against what the merge actually
// carries now: a chunk's summary is a few lines, so a hundred of them still fit. A four-hour
// dense meeting yields around forty.
@Test func aHundredChunkSummariesStillFitTheMerge() throws {
    let summaries = Array(
        repeating: ["первый пункт куска", "второй пункт куска", "третий пункт куска"],
        count: 100
    )
    try runner(contextTokens: 28_000).checkMergeFits(SummaryPrompt.mergeUser(summaries: summaries))
}

@Test func theMergeRefusalIsPermanent() {
    #expect(MLXSummaryRunner.Failure.mergeTooLong(estimated: 30_000, limit: 25_000).isPermanent)
}
