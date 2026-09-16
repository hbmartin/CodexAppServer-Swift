import Foundation

public enum CodexError: Error, Sendable, Equatable {
    case alreadyConnected, disconnected, reconnecting, closing, staleResponseHandle, responseAlreadySent
    case transportClosed(String?), malformedFrame(String), frameTooLarge(actual: Int, limit: Int)
    case rpc(code: Int, message: String, data: JSONValue?)
    case requestTimedOut(method: String), requestCancelled(method: String)
    case missingField(String), invalidField(String), unsupportedFeature(String), invalidConfiguration(String), unsafePath(String)
    case invalidArgument(String)
    case operationUnavailableDuringRecovery(String)
    /// The server returned success, but its mutation result could not be decoded.
    /// The operation may have taken effect. Reconcile server state before retrying.
    case invalidMutationResponse(method: String, reason: String, response: JSONValue)
    case mediaTooLarge(actual: Int, limit: Int), missingDynamicTool(String)
}

extension CodexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected: "The client is already connected."
        case .disconnected: "The client is disconnected."
        case .reconnecting: "The client is reconnecting; offline requests are not queued."
        case .closing: "The client is closing."
        case .transportClosed(let reason): "The transport closed\(reason.map { ": \($0)" } ?? ".")"
        case .malformedFrame(let text): "Malformed protocol frame: \(text)"
        case .frameTooLarge(let actual, let limit): "Protocol frame is \(actual) bytes; the limit is \(limit)."
        case .rpc(let code, let message, _): "Codex RPC error \(code): \(message)"
        case .requestTimedOut(let method): "The \(method) request timed out."
        case .requestCancelled(let method): "The local wait for \(method) was cancelled."
        case .staleResponseHandle: "This response handle belongs to an earlier connection."
        case .responseAlreadySent: "This interaction has already been answered."
        case .missingField(let field): "The response is missing \(field)."
        case .invalidField(let field): "The response field \(field) has an invalid type or value."
        case .invalidArgument(let reason): "Invalid argument: \(reason)"
        case .operationUnavailableDuringRecovery(let operation): "The \(operation) operation is unavailable until lost interactions are reconciled."
        case .invalidMutationResponse(let method, let reason, _):
            "The server acknowledged \(method), but its response was invalid: \(reason) The operation may have taken effect; reconcile server state before retrying."
        case .unsupportedFeature(let feature): "The connected Codex does not support \(feature)."
        case .invalidConfiguration(let reason): "Invalid configuration: \(reason)"
        case .unsafePath(let path): "Unsafe remote path: \(path)"
        case .mediaTooLarge(let actual, let limit): "Media is \(actual) bytes; the limit is \(limit)."
        case .missingDynamicTool(let name): "No handler is registered for dynamic tool \(name)."
        }
    }
}

public enum CodexConnectionState: Sendable, Equatable {
    case disconnected, connecting
    case connected(generation: UInt64)
    case reconnecting(attempt: Int, maximumAttempts: Int)
    case recoveryRequired(CodexRecoveryContext)
    case failed(String)
    case closing
}

public struct CodexRecoveryContext: Sendable, Equatable {
    public var lostInteractions: [CodexLostInteraction]
    public var threadIDs: Set<String> { Set(lostInteractions.compactMap(\.threadID)) }
    public var unscopedRequestIDs: [JSONValue] { lostInteractions.filter { $0.threadID == nil }.map(\.requestID) }
    public var reason: String
    public init(lostInteractions: [CodexLostInteraction], reason: String) {
        self.lostInteractions = lostInteractions; self.reason = reason
    }
}

public struct CodexLostInteraction: Sendable, Equatable, Hashable, Identifiable {
    public var requestID: JSONValue
    public var method: String
    public var threadID: String?
    public var id: JSONValue { requestID }
    public init(requestID: JSONValue, method: String, threadID: String?) {
        self.requestID = requestID; self.method = method; self.threadID = threadID
    }
}

public struct CodexClientInfo: Codable, Sendable, Equatable {
    public var name: String
    public var title: String?
    public var version: String
    public init(name: String = "codex_app_server_swift", title: String? = "Codex App Server Swift SDK", version: String = "0.2.0") {
        self.name = name; self.title = title; self.version = version
    }
    var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "version": .string(version)]
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

public struct CodexReconnectPolicy: Sendable, Equatable {
    public var maximumAttempts: Int
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var jitter: Bool
    public init(maximumAttempts: Int = 3, initialDelay: Duration = .milliseconds(500), maximumDelay: Duration = .seconds(30), jitter: Bool = true) {
        self.maximumAttempts = maximumAttempts; self.initialDelay = initialDelay; self.maximumDelay = maximumDelay; self.jitter = jitter
    }
}

public struct CodexClientConfiguration: Sendable {
    public var clientInfo: CodexClientInfo
    public var requestTimeout: Duration?
    public var maximumFrameBytes: Int
    public var mediaLimitBytes: Int
    public var reconnectPolicy: CodexReconnectPolicy
    public var logger: CodexLogger
    public init(clientInfo: CodexClientInfo = .init(), requestTimeout: Duration? = nil, maximumFrameBytes: Int = 32 * 1_024 * 1_024, mediaLimitBytes: Int = 10 * 1_024 * 1_024, reconnectPolicy: CodexReconnectPolicy = .init(), logger: CodexLogger = .init()) {
        self.clientInfo = clientInfo; self.requestTimeout = requestTimeout; self.maximumFrameBytes = maximumFrameBytes; self.mediaLimitBytes = mediaLimitBytes; self.reconnectPolicy = reconnectPolicy; self.logger = logger
    }
}

public enum CodexPayloadLogging: Sendable { case redacted, full }
public struct CodexLogger: Sendable {
    public enum Level: String, Sendable { case debug, info, warning, error }
    public typealias Sink = @Sendable (Level, String, [String: String]) -> Void
    public var payloadMode: CodexPayloadLogging
    private let sink: Sink
    public init(payloadMode: CodexPayloadLogging = .redacted, sink: @escaping Sink = { _, _, _ in }) { self.payloadMode = payloadMode; self.sink = sink }
    public func log(_ level: Level, _ message: String, metadata: [String: String] = [:]) { sink(level, message, Self.redact(metadata)) }
    func render(_ value: JSONValue) -> String {
        let output = payloadMode == .full ? Self.redactJSON(value) : .string("<payload redacted>")
        return String(decoding: (try? output.encoded(sortedKeys: true)) ?? Data(), as: UTF8.self)
    }
    private static func redact(_ metadata: [String: String]) -> [String: String] {
        let keys = ["authorization", "token", "secret", "grant", "pairing", "cookie", "apikey", "api_key", "api-key", "password"]
        return Dictionary(uniqueKeysWithValues: metadata.map { key, value in (key, keys.contains(where: { key.lowercased().contains($0) }) ? "<redacted>" : value) })
    }
    private static func redactJSON(_ value: JSONValue) -> JSONValue {
        let keys = ["authorization", "token", "secret", "grant", "pairing", "cookie", "apikey", "api_key", "api-key", "password"]
        switch value {
        case .array(let values): return .array(values.map(redactJSON))
        case .object(let values): return .object(values.mapValues(redactJSON).mapValues { $0 }.reduce(into: [:]) { result, element in result[element.key] = keys.contains(where: { element.key.lowercased().contains($0) }) ? .string("<redacted>") : element.value })
        default: return value
        }
    }
}
