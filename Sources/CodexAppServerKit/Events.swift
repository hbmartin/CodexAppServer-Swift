import Foundation

public enum CodexDiagnostic: Sendable, Equatable {
    case transport(CodexTransportDiagnostic), malformedMessage(String), unmatchedResponse(JSONValue)
    case slowSubscriber(UUID), highThreadSubscriptionCount(Int), reconnectFailed(attempt: Int, message: String)
    case raw(String, JSONValue)
}
public enum CodexEvent: Sendable, Equatable {
    case connection(CodexConnectionState)
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
        case .notification(_, let params): params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
        default: nil
        }
    }
    var isDelta: Bool { if case .itemDelta = self { true } else { false } }
}

public struct CodexCommandOutput: Sendable, Equatable {
    public enum Stream: String, Sendable { case stdout, stderr, unknown }
    public var processID: String
    public var stream: Stream
    public var data: Data
    public var raw: JSONValue
    public init(raw: JSONValue) {
        self.raw = raw; processID = raw["processId"]?.stringValue ?? ""
        stream = Stream(rawValue: raw["stream"]?.stringValue ?? "") ?? .unknown
        data = Data(base64Encoded: raw["delta"]?.stringValue ?? raw["dataBase64"]?.stringValue ?? "") ?? Data()
    }
}

public struct CodexThreadState: Sendable, Equatable {
    public var thread: CodexThread?
    public var turns: [String: CodexTurn]
    public var items: [String: CodexItem]
    public var activeTurnIDs: Set<String>
    public init(thread: CodexThread? = nil, turns: [String: CodexTurn] = [:], items: [String: CodexItem] = [:], activeTurnIDs: Set<String> = []) { self.thread = thread; self.turns = turns; self.items = items; self.activeTurnIDs = activeTurnIDs }
}
