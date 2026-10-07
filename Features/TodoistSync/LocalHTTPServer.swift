import Foundation
import Network
import os

public enum TodoistSyncConfig {
    /// Fixed so BigHead's schema can name it. Loopback only — see `LocalHTTPServer`.
    public static let port: UInt16 = 41730
}

public enum LocalHTTPServerError: Error, Equatable, LocalizedError {
    case startTimedOut

    public var errorDescription: String? {
        switch self {
        case .startTimedOut: return "The local listener did not become ready in time"
        }
    }
}

/// The local door BigHead's agent knocks on with `curl`. Loopback interface only: nothing outside
/// this machine can reach it. One request per connection, then the connection is closed.
public final class LocalHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String, String, Data) async -> HTTPResponse

    /// A client that opens a connection and never finishes its request is dropped after this.
    /// It applies only while the request is being read, never while the handler runs.
    private let readDeadline: TimeInterval
    private static let logger = Logger(subsystem: "com.nohands.app", category: "todoist-sync")

    /// How long `start()` waits for the listener to become ready before giving up.
    private let startTimeout: TimeInterval

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.nohands.todoist-sync.server")
    private let state = OSAllocatedUnfairLock<NWListener?>(initialState: nil)

    public convenience init(port: UInt16, handler: @escaping Handler) {
        self.init(port: port, readDeadline: 10, startTimeout: 5, handler: handler)
    }

    init(port: UInt16, readDeadline: TimeInterval, startTimeout: TimeInterval = 5, handler: @escaping Handler) {
        self.port = port
        self.readDeadline = readDeadline
        self.startTimeout = startTimeout
        self.handler = handler
    }

    /// - Returns: the port actually bound — the requested one, or a free one when 0 was asked for.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: nwPort)
        state.withLock { $0 = listener }

        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            /// Returns whether this call was the one that resumed the continuation.
            let resolve: @Sendable (Result<UInt16, Error>) -> Bool = { result in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
                return first
            }
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in
                _ = resolve(result)
            }
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    listener.cancel()
                    finish(.failure(error))
                case .waiting(let error):
                    // A taken port shows up here rather than as `.failed`.
                    listener.cancel()
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(NWError.posix(.ECANCELED)))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            // Finish first, then cancel: the `.cancelled` state must not win the race.
            queue.asyncAfter(deadline: .now() + startTimeout) {
                // Only when the timeout itself decided the outcome; a listener that is already
                // ready (or already failed) must be left alone.
                if resolve(.failure(LocalHTTPServerError.startTimedOut)) { listener.cancel() }
            }
        }
    }

    public func stop() {
        state.withLock { listener in
            listener?.cancel()
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let requestRead = OSAllocatedUnfairLock(initialState: false)
        queue.asyncAfter(deadline: .now() + readDeadline) { [weak connection] in
            // Once the request is fully read the handler may legitimately take longer than this.
            if !requestRead.withLock({ $0 }) { connection?.cancel() }
        }
        receive(on: connection, buffer: Data(), requestRead: requestRead)
    }

    private func receive(on connection: NWConnection, buffer: Data, requestRead: OSAllocatedUnfairLock<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            switch HTTPRequestParser.parse(buffer) {
            case .complete(let method, let path, let body):
                requestRead.withLock { $0 = true }
                let handler = self.handler
                Task {
                    let response = await handler(method, path, body)
                    self.reply(response, on: connection)
                }
            case .invalid(let status):
                requestRead.withLock { $0 = true }
                self.reply(.json(status, ["error": HTTPResponse.reason(status)]), on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, requestRead: requestRead)
                }
            }
        }
    }

    private func reply(_ response: HTTPResponse, on connection: NWConnection) {
        Self.logger.info("local request answered \(response.status, privacy: .public)")
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
