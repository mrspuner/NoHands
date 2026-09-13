import Foundation

/// Runs the local model as a subprocess.
///
/// A subprocess rather than `mlx-swift`: the Swift route means two large new SPM dependencies,
/// and this project already lost days to a package that would not resolve. The cost is that the
/// model loads twice per meeting now — once for the per-chunk pass, once for the merge — at
/// 15 s cold, 3 s warm, measured; still seconds every few hours.
public struct MLXSummaryRunner: SummaryRunning {
    public enum Failure: LocalizedError, SummaryFailure, Equatable {
        case uvMissing(String)
        case tooLong(estimated: Int, limit: Int)
        /// The assembled merge message does not fit the window. Permanent for the same reason
        /// `tooLong` is: the meeting's length fixes how many chunks it has, so a retry produces
        /// the same message.
        case mergeTooLong(estimated: Int, limit: Int)
        case timedOut(TimeInterval)
        case runnerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .uvMissing(let path):
                return "uv not found at \(path)"
            case .tooLong(let estimated, let limit):
                return "The meeting is longer than the model's window: about \(estimated) tokens against \(limit)"
            case .mergeTooLong(let estimated, let limit):
                return "The merge of \(estimated) tokens does not fit the \(limit) the window leaves for it"
            case .timedOut(let seconds):
                return "The model did not answer within \(Int(seconds / 60)) min"
            case .runnerFailed(let detail):
                return "The model run failed: \(detail)"
            }
        }

        public var isPermanent: Bool {
            switch self {
            case .tooLong, .mergeTooLong: return true
            case .uvMissing, .timedOut, .runnerFailed: return false
            }
        }
    }

    /// Pinned, and pinned here rather than in the config: this is compatibility with the script
    /// next door, not a preference. `load_tokenizer` had already moved out of
    /// `mlx_lm.tokenizer_utils` by 0.31.3, and the probe tripped over exactly that.
    static let mlxVersion = "0.31.3"
    /// Ceiling on one chunk's partial summary. It is here to stop a runaway generation, not to
    /// shape the answer — but it has to be past where an honest answer ends, and 1500 no longer
    /// was.
    ///
    /// That number came from a probe under the prompt this branch replaced: a five-point cap,
    /// three fields, a 1948-character answer, roughly 700 tokens. This prompt caps nothing — the
    /// cap is what turned an hour of talk into a table of contents — and carries two more fields,
    /// `tasks` with four of its own (one a 5-15 word quote) and `openIssues`.
    ///
    /// Getting it wrong is not a shorter answer, it is a broken one: a truncated answer is not
    /// valid JSON. Swift parses each partial on its own in the loop in `summarize(chunks:)` and
    /// names the failure by chunk number rather than failing the meeting, so a truncated answer
    /// costs one chunk, not the whole meeting.
    ///
    /// Moving it used to cost merge headroom directly, back when the merge call carried whole
    /// partial summaries. It no longer does: the merge sees only each partial's `summary` array,
    /// a few lines each, so this number bounds one chunk's answer and nothing past it — see
    /// `checkMergeFits` for what actually limits the merge now.
    static let maxTokens = 2500
    /// The merge answers with a title and at most ten summary lines — `SummaryPrompt.merge` caps
    /// the count itself — strictly less than a chunk's decisions, tasks and open issues, quotes
    /// included. It needs less room than `maxTokens`, not more, now that it no longer re-emits
    /// the chunks' own points. `checkMergeFits` subtracts this from the input budget, so leaving
    /// it oversized would spend headroom on an answer shape that cannot use it.
    static let mergeMaxTokens = 800
    /// Characters per token, deliberately pessimistic: the probe measured 3.04 on plain
    /// transcript text, and speaker labels with timecodes tokenise worse than prose.
    ///
    /// `public`: `Meetings` cuts the transcript before calling the runner and needs the same
    /// character budget to turn `MeetingsConfig.summaryContextTokens` into a character count.
    public static let charactersPerToken = 2.5

    private let uvPath: String
    private let model: String
    private let timeout: TimeInterval
    private let contextTokens: Int

    public init(uvPath: String, model: String, timeout: TimeInterval, contextTokens: Int) {
        self.uvPath = uvPath
        self.model = model
        self.timeout = timeout
        self.contextTokens = contextTokens
    }

    struct Request: Encodable {
        struct Prompt: Encodable {
            var system: String
            var user: String
            var maxTokens: Int
        }

        var model: String
        /// Where the child writes its answers. A file rather than stdout: one pass returns every
        /// chunk's partial summary at once, which on a long meeting is hundreds of kilobytes —
        /// far past Darwin's 64 KB pipe buffer, where the child would block on the write and the
        /// run would surface as a timeout. The request already travels this road.
        var answersPath: String
        var prompts: [Prompt]
    }

    /// Everything the subprocess is told, built apart from running it so a test can read it back.
    func encodedRequest(prompts: [Request.Prompt], answersPath: String) throws -> Data {
        try JSONEncoder().encode(
            Request(model: model, answersPath: answersPath, prompts: prompts)
        )
    }

    public func summarize(chunks: [String]) async throws -> MeetingSummary {
        guard !chunks.isEmpty else {
            throw Failure.runnerFailed("the meeting has no transcript to summarise")
        }
        // Per chunk, not per meeting: the whole point of chunking is that a long meeting is many
        // ordinary requests rather than one impossible one.
        for chunk in chunks {
            let estimated = Int(Double(chunk.count) / Self.charactersPerToken)
            guard estimated <= contextTokens else {
                throw Failure.tooLong(estimated: estimated, limit: contextTokens)
            }
        }

        // Expanded here rather than in the config so the file keeps the readable `~` the owner
        // typed. The application launched from Finder has no useful PATH, which is why the path
        // is configured at all instead of looked up.
        let uv = (uvPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: uv) else {
            throw Failure.uvMissing(uvPath)
        }
        let executable = URL(fileURLWithPath: uv)

        // Pass A: one prompt per chunk.
        let answers = try await run(
            uv: executable,
            prompts: chunks.map {
                Request.Prompt(
                    system: SummaryPrompt.system, user: SummaryPrompt.user(chunk: $0), maxTokens: Self.maxTokens
                )
            }
        )
        guard answers.count == chunks.count else {
            throw Failure.runnerFailed(
                "the summary runner answered \(answers.count) of \(chunks.count) prompts"
            )
        }

        var partials: [MeetingSummary] = []
        var refusals: [String] = []
        var firstFailure: Error?
        for (number, raw) in answers.enumerated() {
            // `number` is trusted as the chunk's position — the answers file holds the results of
            // the script's list comprehension over `request["prompts"]`, so its JSON array
            // preserves prompt order and `enumerated()` here lines back up with `chunks`. Nothing
            // on the Swift side reorders or filters `answers` before this loop; if it ever did,
            // the chunk number printed into the owner's permanent file would name the wrong chunk.
            //
            // A chunk whose answer does not parse is skipped and named. Failing the whole meeting
            // would be worse and pointless: generation runs at temperature 0, so the retry
            // produces the same unreadable answer for ever.
            do {
                partials.append(try SummaryResponse.parse(raw))
            } catch {
                if firstFailure == nil { firstFailure = error }
                refusals.append(SummaryAssembly.chunkParseFailure(number: number + 1, of: chunks.count))
            }
        }
        // Nothing parsed at all: there is no summary to write, and the reason belongs in the file
        // as a permanent failure rather than as a file full of refusal lines. Rethrows the first
        // chunk's actual failure rather than assuming `.notJSON`: `SummaryResponse.parse` also
        // throws `.emptySummary` for well-formed JSON with nothing in `summary`, and that
        // sentence, not "something other than JSON", is what belongs in the archive.
        guard !partials.isEmpty else { throw firstFailure ?? SummaryResponse.Failure.notJSON }

        guard partials.count > 1 else {
            return SummaryAssembly.combine(partials: partials, refusals: refusals, merged: nil)
        }

        let mergeUser = SummaryPrompt.mergeUser(summaries: partials.map(\.summary))
        try checkMergeFits(mergeUser)

        // Pass B: one prompt, and it sees only the summaries.
        let mergeAnswer = try await run(
            uv: executable,
            prompts: [
                Request.Prompt(
                    system: SummaryPrompt.merge, user: mergeUser, maxTokens: Self.mergeMaxTokens
                )
            ]
        )
        guard let raw = mergeAnswer.first, let merged = try? SummaryResponse.parse(raw) else {
            // The title and the summary are lost; the points survive. Same shape as a refused
            // cleanup inserting the raw dictation with the reason named.
            return SummaryAssembly.combine(
                partials: partials,
                refusals: refusals + [SummaryAssembly.mergeParseFailure],
                merged: nil
            )
        }
        return SummaryAssembly.combine(partials: partials, refusals: refusals, merged: merged)
    }

    /// The merge call has to fit what the window leaves after the answer is reserved.
    ///
    /// This replaces the ten-chunk ceiling, which was arithmetic on the worst case: every partial
    /// summary could have filled `maxTokens`, so ten of them plus the prefix was as much as the
    /// window could hold. The merge no longer carries partial summaries — it carries their
    /// `summary` arrays, a few lines each — so the size is known exactly before the call, and
    /// bounding it by a count of chunks would refuse meetings that fit comfortably.
    ///
    /// The practical ceiling moves far out: at a couple of hundred tokens per chunk summary the
    /// window holds more than a hundred chunks, and a four-hour dense meeting yields around
    /// forty. What limits a long meeting now is time, not this.
    func checkMergeFits(_ message: String) throws {
        let estimated = Int(Double(message.count) / Self.charactersPerToken)
        let limit = contextTokens - Self.mergeMaxTokens
        guard estimated <= limit else {
            throw Failure.mergeTooLong(estimated: estimated, limit: limit)
        }
    }

    /// The whole subprocess dance is blocking, and blocking a cooperative thread for two minutes
    /// starves the pool. It runs on a queue of its own and comes back through a continuation.
    private func run(uv: URL, prompts: [Request.Prompt]) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try blockingRun(uv: uv, prompts: prompts))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Serial, and load-bearing rather than tidy: the child process holds the 4.3 GB model, and
    /// two of them at once do not fit beside the owner's work on a 16 GB machine. Every runner
    /// instance shares this one queue — hence `static` — because `MeetingSummarizer` and the CLI
    /// each build their own runner, and a per-instance queue would serialise nothing.
    private static let queue = DispatchQueue(label: "nohands.summary", qos: .utility)

    /// How long to wait after `terminate()` before escalating to `SIGKILL`. A child stuck
    /// inside an MLX kernel, or a `uv` that does not forward SIGTERM, would otherwise keep
    /// 4.3 GB resident while the next summary starts — a couple of seconds is enough for a
    /// cooperating process to exit and short enough not to matter when it is not.
    private static let terminationGrace: TimeInterval = 2

    private func blockingRun(uv: URL, prompts: [Request.Prompt]) throws -> [String] {
        let process = Process()

        // Where the child writes its answers, removed the same way the request file is: created
        // (by the child, not here) and torn down in the same breath as everything else this run
        // touches.
        let answersFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nohands-summary-answers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: answersFile) }

        let request = try encodedRequest(prompts: prompts, answersPath: answersFile.path)

        // The request travels as a file, not on stdin. A meeting transcript is 65-140 KB of
        // UTF-8 — past Darwin's 64 KB pipe capacity — so writing it to stdin blocks the parent
        // until the child drains it, which only happens after `uv` has resolved mlx-lm and
        // Python has imported it. That stretch would sit outside the timeout below, and a
        // child that never reads (a stalled cache lock, a hung download) would leave this
        // function never returning — wedging every summary queued behind it on the shared
        // serial queue. A file has no such blocking write.
        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nohands-summary-request-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: requestFile.path, contents: request)
        defer { try? FileManager.default.removeItem(at: requestFile) }

        // The script travels the same way the request does — written out beside it, removed in the
        // same breath. It is compiled into the binary as text rather than shipped as a bundle
        // resource; see `SummaryScript` for what that cost the built application. `defer` before
        // the `guard`, so a failure to create the file still cleans up after itself.
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nohands-summarize-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: scriptFile) }
        guard
            FileManager.default.createFile(
                atPath: scriptFile.path, contents: Data(SummaryScript.source.utf8)
            )
        else {
            throw Failure.runnerFailed("no temporary file for the summary script")
        }

        process.executableURL = uv
        process.arguments = [
            "run", "--quiet", "--with", "mlx-lm==\(Self.mlxVersion)", "python", scriptFile.path,
            requestFile.path,
        ]

        let output = Pipe()
        // Diagnostics go to a file, not to a pipe. `uv` and `mlx` print progress to stderr, and a
        // pipe nobody drains fills its buffer and hangs the child — which would surface as a
        // timeout on a run that was working fine. There is no transcript content here.
        //
        // stdout stays a pipe, but nothing meaningful travels on it any more: the answers go to
        // `answersFile` for the same reason the request goes to a file rather than stdin — one
        // pass can return hundreds of kilobytes of partial summaries, past Darwin's 64 KB pipe
        // buffer, where the child would block on the write and the run would surface as a
        // timeout. What (if anything) the script still writes to stdout is read and discarded
        // below, so a pipe nobody drains cannot hang it either.
        let diagnostics = FileManager.default.temporaryDirectory
            .appendingPathComponent("nohands-summary-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: diagnostics) }
        guard let errors = FileHandle(forWritingAtPath: diagnostics.path) else {
            throw Failure.runnerFailed("no temporary file for diagnostics")
        }

        process.standardOutput = output
        process.standardError = errors

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw Failure.runnerFailed(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // SIGTERM is a request, not a guarantee. If the child is stuck inside an MLX
            // kernel, or `uv` does not forward the signal, it would otherwise keep the model
            // resident in memory indefinitely while the next summary starts.
            if finished.wait(timeout: .now() + Self.terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw Failure.timedOut(timeout)
        }

        // Drained and discarded: nothing meaningful travels on stdout any more (see above), but
        // an unread pipe would still fill and block a child that happens to write to it.
        _ = output.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            throw Failure.runnerFailed(Self.lastLine(of: diagnostics))
        }

        return try Self.decodeAnswers(from: answersFile.path)
    }

    /// Reads and decodes the child's answers file. Split out of `blockingRun` because this part
    /// touches no subprocess at all — a missing file, an empty one, JSON of the wrong shape, and
    /// an empty array are all fixtures, not a real `uv` run — so it is tested directly rather
    /// than only through guards that never reach a process launch.
    static func decodeAnswers(from path: String) throws -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
            let answers = try? JSONDecoder().decode([String].self, from: data),
            !answers.isEmpty
        else {
            throw Failure.runnerFailed("the summary runner wrote no readable answers")
        }
        return answers
    }

    /// The last line of the script's own diagnostics, capped to what one panel line holds.
    private static func lastLine(of file: URL) -> String {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let last = text.split(separator: "\n").last.map(String.init) ?? "no diagnostics"
        return String(last.prefix(200))
    }
}
