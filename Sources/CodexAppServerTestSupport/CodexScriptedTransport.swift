import Foundation
import CodexAppServerKit

/// A suspension point a test can open on demand.
///
/// Used to hold a transport inside `start()` or inside a chosen request so the test can act
/// while the client is mid-flight.
public actor CodexTestGate {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    public init() {}

    /// True once something is parked on this gate.
    public func isWaiting() -> Bool { waiting }

    public func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    public func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Hands out a prepared transport per connection attempt, so reconnect paths can be driven
/// deterministically. Throws once the list is exhausted, which models a host that stays down.
public actor CodexTransportSequence {
    private var transports: [CodexScriptedTransport]

    public init(_ transports: [CodexScriptedTransport]) { self.transports = transports }

    public func next() throws -> CodexScriptedTransport {
        guard !transports.isEmpty else { throw CodexError.transportClosed("exhausted") }
        return transports.removeFirst()
    }

    /// A factory that draws from this sequence, for tests that exercise reconnects.
    public nonisolated var factory: CodexTransportFactory {
        .init { try await self.next() }
    }
}

/// An in-process ``CodexTransport`` that answers requests from a table instead of a real
/// app-server.
///
/// Requests are matched by JSON-RPC method: `results[method]` is returned as the result, or an
/// empty object when the method is absent. `defaultResults` supplies a small scripted server
/// covering the common handshake and thread operations.
///
/// The fault-injection knobs each model a failure the SDK has to survive: a slow responder, a
/// server request replayed during recovery, an ambiguous send failure, and a transport that
/// stalls before it is usable.
public actor CodexScriptedTransport: CodexTransport {
    public nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    public nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>

    private let frames: AsyncThrowingStream<Data, Error>.Continuation
    private let diagnostic: AsyncStream<CodexTransportDiagnostic>.Continuation

    private var sent: [JSONValue] = []
    private var results: [String: JSONValue]
    private var closedFlag = false

    private var delayResponses: Bool
    private var replayOnResume: Bool
    private var replayOnInitialized = false
    private var rejectResponses = false
    private var startGate: CodexTestGate?
    private var methodGate: (method: String, gate: CodexTestGate)?

    /// A scripted server covering the handshake plus the thread and turn operations most tests
    /// need. `thread/resume` and `thread/read` echo the requested thread ID.
    public static let defaultResults: [String: JSONValue] = [
        "initialize": ["serverInfo": ["name": "fake", "version": "0.146.0"]],
        "thread/list": ["data": [["id": "thread-1", "name": "One"]], "nextCursor": nil],
        "thread/start": ["thread": ["id": "thread-new"]],
        "turn/steer": ["turnId": "turn-1"],
        "turn/start": ["turn": ["id": "turn-1", "status": "inProgress"]],
    ]

    /// - Parameters:
    ///   - results: per-method results. Methods not present answer with an empty object.
    ///   - delayResponses: sleep 50 ms before answering a client *response* frame.
    ///   - replayOnResume: inject a server request during `thread/resume`, as an app-server
    ///     does when it replays an unanswered approval after a reconnect.
    public init(results: [String: JSONValue] = [:], delayResponses: Bool = false, replayOnResume: Bool = false) {
        self.results = results
        self.delayResponses = delayResponses
        self.replayOnResume = replayOnResume
        let f = AsyncThrowingStream<Data, Error>.makeStream()
        incomingFrames = f.stream; frames = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream()
        diagnostics = d.stream; diagnostic = d.continuation
    }

    /// A transport preloaded with ``defaultResults``, merged with `overrides`.
    public static func scripted(overrides: [String: JSONValue] = [:]) -> CodexScriptedTransport {
        CodexScriptedTransport(results: defaultResults.merging(overrides) { _, override in override })
    }

    // MARK: - CodexTransport

    public func start() async { await startGate?.wait() }

    public func send(frame: Data) async throws {
        let message = try JSONValue.decode(frame)
        sent.append(message)
        if message["method"]?.stringValue == "initialized", replayOnInitialized {
            try inject(["id": 56, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
            try await Task.sleep(for: .milliseconds(50))
        }
        if message["result"] != nil, rejectResponses { throw CodexError.transportClosed("ambiguous send failure") }
        if message["result"] != nil, delayResponses { try await Task.sleep(for: .milliseconds(50)) }
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        if let methodGate, methodGate.method == method { await methodGate.gate.wait() }
        if method == "thread/resume", replayOnResume {
            try inject(["id": 55, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
            try await Task.sleep(for: .milliseconds(100))
        }
        try inject(["id": id, "result": results[method] ?? .object([:])])
    }

    public func close() {
        closedFlag = true
        frames.finish()
        diagnostic.finish()
    }

    // MARK: - Test control

    /// Pushes a server-to-client frame.
    public func inject(_ value: JSONValue) throws { frames.yield(try value.encoded()) }

    /// Pushes an unparseable frame, to exercise the malformed-message diagnostic.
    public func injectMalformed() { frames.yield(Data("{".utf8)) }

    /// Ends the frame stream, optionally with an error, to exercise reconnect.
    public func finish(_ error: Error? = nil) {
        if let error { frames.finish(throwing: error) } else { frames.finish() }
    }

    /// Replaces the result table after construction.
    public func setResults(_ value: [String: JSONValue]) { results = value }

    /// Holds `start()` until the gate is released.
    public func holdStart(at gate: CodexTestGate) { startGate = gate }

    /// Holds the named request until the gate is released, before any response is written.
    public func hold(method: String, at gate: CodexTestGate) { methodGate = (method, gate) }

    /// Makes outbound *responses* fail, modelling a send whose delivery is unknowable.
    public func failResponses() { rejectResponses = true }

    /// Injects a server request while the `initialized` notification is still in flight.
    public func replayWhenInitialized() { replayOnInitialized = true }

    // MARK: - Assertions

    public func messages() -> [JSONValue] { sent }
    public func isClosed() -> Bool { closedFlag }

    /// The JSON-RPC id the client used for the first request with this method.
    public func requestID(method: String) -> JSONValue? {
        sent.first { $0["method"]?.stringValue == method }?["id"]
    }

    /// A factory that always returns this transport.
    public nonisolated var factory: CodexTransportFactory { .init { self } }
}

public extension CodexClient {
    /// A client wired to `transport`, with timeouts short and reconnects off so failures surface
    /// as test failures rather than as hangs.
    static func testClient(
        _ transport: CodexScriptedTransport,
        configuration: CodexClientConfiguration = .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 0))
    ) -> CodexClient {
        CodexClient(transportFactory: transport.factory, configuration: configuration)
    }

    /// A connected client wired to `transport`.
    static func connectedTestClient(
        _ transport: CodexScriptedTransport,
        configuration: CodexClientConfiguration = .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 0))
    ) async throws -> CodexClient {
        let client = testClient(transport, configuration: configuration)
        _ = try await client.connect()
        return client
    }

    /// Configuration for tests that need one reconnect to happen immediately and deterministically.
    static var immediateReconnectConfiguration: CodexClientConfiguration {
        .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero, jitter: false))
    }
}
