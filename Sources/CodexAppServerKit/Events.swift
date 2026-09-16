import Foundation

public enum CodexDiagnostic: Sendable, Equatable {
    case transport(CodexTransportDiagnostic), malformedMessage(String), unmatchedResponse(JSONValue)
    case slowSubscriber(UUID), highThreadSubscriptionCount(Int), reconnectFailed(attempt: Int, message: String)
    case threadMalformedMessage(threadID: String, message: String)
    case raw(String, JSONValue)
}
public enum CodexEvent: Sendable, Equatable {
    case connection(CodexConnectionState)
    /// Original inbound JSON-RPC server request or notification before typed routing.
    case protocolMessage(JSONValue)
    case threadStateUpdated(threadID: String, state: CodexThreadState)
    case notification(method: String, params: JSONValue)
    case serverRequest(CodexPendingInteraction), serverRequestResolved(JSONValue)
    case itemStarted(threadID: String?, item: CodexItem)
    case itemDelta(threadID: String?, itemID: String?, method: String, delta: JSONValue)
    case itemCompleted(threadID: String?, item: CodexItem)
    case turnStarted(threadID: String?, turn: CodexTurn), turnCompleted(threadID: String?, turn: CodexTurn)
    case dynamicToolStarted(name: String, callID: String?), dynamicToolCompleted(name: String, callID: String?, success: Bool)
    case commandOutput(CodexCommandOutput)
    case fileSearchUpdated(JSONValue), fileSearchCompleted(JSONValue)
    case diagnostic(CodexDiagnostic)

    public var threadID: String? {
        switch self {
        case .itemStarted(let id, _), .itemDelta(let id, _, _, _), .itemCompleted(let id, _), .turnStarted(let id, _), .turnCompleted(let id, _): id
        case .serverRequest(let request): request.threadID
        case .threadStateUpdated(let id, _): id
        case .diagnostic(.threadMalformedMessage(let id, _)): id
        case .serverRequestResolved(let params): params["threadId"]?.stringValue
        case .notification(_, let params): params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
        case .protocolMessage(let message): message["params"]?["threadId"]?.stringValue ?? message["params"]?["thread"]?["id"]?.stringValue
        default: nil
        }
    }
    var isDelta: Bool { if case .itemDelta = self { true } else { false } }
    var isProtocolMessage: Bool { if case .protocolMessage = self { true } else { false } }
}

public struct CodexCommandOutput: Sendable, Equatable {
    public enum Stream: Sendable, Equatable {
        case stdout, stderr, unknown(String)
        public var rawValue: String {
            switch self { case .stdout: "stdout"; case .stderr: "stderr"; case .unknown(let value): value }
        }
    }
    public var processID: String
    public var stream: Stream
    public var data: Data
    public var capReached: Bool
    public var raw: JSONValue
    /// - Throws: `CodexError.missingField` when `raw` carries no usable `processId`.
    ///   `processID` demultiplexes streamed output, so an empty one would merge the
    ///   output of unrelated processes.
    public init(raw: JSONValue) throws {
        processID = try raw.requireString("processId", context: "commandOutput")
        self.raw = raw
        guard let streamValue = raw["stream"]?.stringValue, !streamValue.isEmpty else { throw CodexError.invalidField("commandOutput.stream") }
        switch streamValue { case "stdout": stream = .stdout; case "stderr": stream = .stderr; default: stream = .unknown(streamValue) }
        guard let encoded = raw["deltaBase64"]?.stringValue else { throw CodexError.invalidField("commandOutput.deltaBase64") }
        guard let decoded = Data(base64Encoded: encoded) else { throw CodexError.invalidField("commandOutput.deltaBase64") }
        data = decoded
        capReached = try raw.requireBool("capReached", context: "commandOutput")
    }
}

public struct CodexThreadState: Sendable, Equatable {
    public var thread: CodexThread?
    public var turns: [String: CodexTurn]
    public var items: [String: CodexItem]
    public var activeTurnIDs: Set<String>
    /// Latest thread/tokenUsage/updated payload: cumulative `total` and latest-turn `last` usage.
    public var tokenUsage: JSONValue?
    public var turnOrder: [String]
    public var itemOrder: [String]
    public init(thread: CodexThread? = nil, turns: [String: CodexTurn] = [:], items: [String: CodexItem] = [:], activeTurnIDs: Set<String> = [], tokenUsage: JSONValue? = nil, turnOrder: [String] = [], itemOrder: [String] = []) {
        self.thread = thread; self.turns = turns; self.items = items; self.activeTurnIDs = activeTurnIDs
        self.tokenUsage = tokenUsage; self.turnOrder = turnOrder; self.itemOrder = itemOrder
    }
}
