import Foundation
import os

/// What `claude --output-format json` prints on stdout when it finishes. Only the two fields the
/// app acts on are decoded; the answer text (`result`) is deliberately not part of the type, so
/// it cannot be logged or stored by accident.
public struct AgentResult: Equatable, Sendable, Decodable {
    public var isError: Bool
    public var terminalReason: String?

    public init(isError: Bool, terminalReason: String?) {
        self.isError = isError
        self.terminalReason = terminalReason
    }

    private enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case terminalReason = "terminal_reason"
    }

    /// `nil` when stdout is not a JSON object with `is_error` (plain text, truncated output).
    public static func parse(_ stdout: Data) -> AgentResult? {
        try? JSONDecoder().decode(AgentResult.self, from: stdout)
    }
}

public struct AgentRun: Equatable, Sendable {
    public var exitCode: Int32
    /// `nil` means stdout could not be parsed (or exceeded the capture limit).
    public var result: AgentResult?
    /// First non-empty stderr line, cut to 200 characters.
    public var stderrLine: String?

    public init(exitCode: Int32, result: AgentResult?, stderrLine: String?) {
        self.exitCode = exitCode
        self.result = result
        self.stderrLine = stderrLine
    }
}

public enum AgentLaunchError: Error, Equatable {
    /// A child that outlived the timeout was terminated.
    case timedOut
    case launchFailed(String)
}

public protocol ProcessRunning: Sendable {
    /// - Parameter pidFile: when set, holds the child's PID for exactly as long as it runs.
    /// - Returns: the exit code with whatever could be read from the child's output. Throws
    ///   `AgentLaunchError.timedOut` after terminating a child that outlived `timeout`,
    ///   `AgentLaunchError.launchFailed` when it could not start.
    func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
             pidFile: URL?) async throws -> AgentRun
}

public struct SystemProcessRunner: ProcessRunning {
    /// A final JSON result is a few kilobytes; anything beyond this is not one.
    static let stdoutLimit = 1_000_000
    static let stderrLineLimit = 200

    public init() {}

    public func run(executable: URL, arguments: [String], directory: URL, timeout: TimeInterval,
                    pidFile: URL?) async throws -> AgentRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                // Launch failed: the waiter below is never started, so this is the only resume.
                continuation.resume(throwing: AgentLaunchError.launchFailed(error.localizedDescription))
                return
            }
            // Without this the pipes never reach EOF: our own copies of the write ends stay open.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            if let pidFile {
                try? Data("\(process.processIdentifier)".utf8).write(to: pidFile, options: .atomic)
            }

            // Each pipe is drained to EOF on its own thread: a pipe nobody reads fills up at 64 KB
            // and hangs the child.
            let out = OutputCapture()
            let err = OutputCapture()
            let readers = DispatchGroup()
            for (handle, capture, limit) in [
                (stdout.fileHandleForReading, out, Self.stdoutLimit),
                (stderr.fileHandleForReading, err, Self.stderrLineLimit * 40),
            ] {
                readers.enter()
                DispatchQueue.global().async {
                    capture.drain(handle, limit: limit)
                    readers.leave()
                }
            }

            // Exactly one branch below runs, so the continuation resumes exactly once.
            DispatchQueue.global().async {
                // Removed before resuming, not in a `defer`: the caller must never see the file after return.
                func dropPIDFile() { if let pidFile { try? FileManager.default.removeItem(at: pidFile) } }
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        // Foundation reaps the child; wait for it so no zombie outlives the call.
                        _ = finished.wait(timeout: .now() + 2)
                    }
                    dropPIDFile()
                    continuation.resume(throwing: AgentLaunchError.timedOut)
                } else {
                    readers.wait()
                    let (data, overflowed) = out.snapshot()
                    dropPIDFile()
                    continuation.resume(returning: AgentRun(
                        exitCode: process.terminationStatus,
                        result: overflowed ? nil : AgentResult.parse(data),
                        stderrLine: Self.firstLine(err.snapshot().data)))
                }
            }
        }
    }

    static func firstLine(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return String(line.prefix(stderrLineLimit))
    }
}

/// Collects a pipe's output up to a limit; the rest is read and discarded so the child never blocks.
private final class OutputCapture: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (data: Data(), overflowed: false))

    func drain(_ handle: FileHandle, limit: Int) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            state.withLock { state in
                let room = limit - state.data.count
                if chunk.count <= room {
                    state.data.append(chunk)
                } else {
                    state.data.append(chunk.prefix(max(room, 0)))
                    state.overflowed = true
                }
            }
        }
    }

    func snapshot() -> (data: Data, overflowed: Bool) { state.withLock { $0 } }
}
