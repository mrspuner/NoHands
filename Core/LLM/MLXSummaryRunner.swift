import Foundation

/// Runs the local model as a subprocess.
///
/// A subprocess rather than `mlx-swift`: the Swift route means two large new SPM dependencies,
/// and this project already lost days to a package that would not resolve. The cost is that the
/// model loads on every call — 15 s cold, 3 s warm, measured — which is seconds every few hours.
public struct MLXSummaryRunner: SummaryRunning {
    public enum Failure: LocalizedError, SummaryFailure, Equatable {
        case uvMissing(String)
        case scriptMissing
        case tooLong(estimated: Int, limit: Int)
        case timedOut(TimeInterval)
        case runnerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .uvMissing(let path):
                return "uv not found at \(path)"
            case .scriptMissing:
                return "summarize.py is missing from the application bundle"
            case .tooLong(let estimated, let limit):
                return "The meeting is longer than the model's window: about \(estimated) tokens against \(limit)"
            case .timedOut(let seconds):
                return "The model did not answer within \(Int(seconds / 60)) min"
            case .runnerFailed(let detail):
                return "The model run failed: \(detail)"
            }
        }

        public var isPermanent: Bool {
            if case .tooLong = self { return true }
            return false
        }
    }

    /// Pinned, and pinned here rather than in the config: this is compatibility with the script
    /// next door, not a preference. `load_tokenizer` had already moved out of
    /// `mlx_lm.tokenizer_utils` by 0.31.3, and the probe tripped over exactly that.
    static let mlxVersion = "0.31.3"
    /// The 71-minute meeting in the probe answered in 1948 characters, roughly 700 tokens. The
    /// ceiling is here to stop a runaway generation, not to shape the answer.
    static let maxTokens = 1500
    /// Characters per token, deliberately pessimistic: the probe measured 3.04 on plain
    /// transcript text, and speaker labels with timecodes tokenise worse than prose.
    static let charactersPerToken = 2.5

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

    private struct Request: Encodable {
        var model: String
        var system: String
        var prompt: String
        var maxTokens: Int
    }

    public func summarize(transcript: String) async throws -> MeetingSummary {
        let estimated = Int(Double(transcript.count) / Self.charactersPerToken)
        guard estimated <= contextTokens else {
            throw Failure.tooLong(estimated: estimated, limit: contextTokens)
        }

        // Expanded here rather than in the config so the file keeps the readable `~` the owner
        // typed. The application launched from Finder has no useful PATH, which is why the path
        // is configured at all instead of looked up.
        let uv = (uvPath as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: uv) else {
            throw Failure.uvMissing(uvPath)
        }
        guard let script = Bundle.module.url(forResource: "summarize", withExtension: "py") else {
            throw Failure.scriptMissing
        }

        let request = try JSONEncoder().encode(
            Request(
                model: model,
                system: SummaryPrompt.system,
                prompt: SummaryPrompt.user(transcript: transcript),
                maxTokens: Self.maxTokens
            )
        )
        let answer = try await run(uv: URL(fileURLWithPath: uv), script: script, request: request)
        return try SummaryResponse.parse(answer)
    }

    /// The whole subprocess dance is blocking, and blocking a cooperative thread for two minutes
    /// starves the pool. It runs on a queue of its own and comes back through a continuation.
    private func run(uv: URL, script: URL, request: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try blockingRun(uv: uv, script: script, request: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let queue = DispatchQueue(label: "nohands.summary", qos: .utility)

    /// How long to wait after `terminate()` before escalating to `SIGKILL`. A child stuck
    /// inside an MLX kernel, or a `uv` that does not forward SIGTERM, would otherwise keep
    /// 4.3 GB resident while the next summary starts — a couple of seconds is enough for a
    /// cooperating process to exit and short enough not to matter when it is not.
    private static let terminationGrace: TimeInterval = 2

    private func blockingRun(uv: URL, script: URL, request: Data) throws -> String {
        let process = Process()

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

        process.executableURL = uv
        process.arguments = [
            "run", "--quiet", "--with", "mlx-lm==\(Self.mlxVersion)", "python", script.path,
            requestFile.path,
        ]

        let output = Pipe()
        // Diagnostics go to a file, not to a pipe. `uv` and `mlx` print progress to stderr, and a
        // pipe nobody drains fills its buffer and hangs the child — which would surface as a
        // timeout on a run that was working fine. There is no transcript content here.
        //
        // stdout stays a pipe: that only works because `maxTokens = 1500` keeps the answer well
        // under the pipe's buffer. Raising `maxTokens` later without revisiting this would turn
        // a working run into a silent timeout, for the same reason stderr cannot be a pipe.
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

        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure.runnerFailed(Self.lastLine(of: diagnostics))
        }
        return answer
    }

    /// The last line of the script's own diagnostics, capped to what one panel line holds.
    private static func lastLine(of file: URL) -> String {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let last = text.split(separator: "\n").last.map(String.init) ?? "no diagnostics"
        return String(last.prefix(200))
    }
}
