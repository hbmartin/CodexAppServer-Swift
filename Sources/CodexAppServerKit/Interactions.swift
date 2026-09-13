import Foundation

public enum CodexInteractionKind: Sendable, Equatable { case commandApproval, networkApproval, fileChangeApproval, permissionApproval, userInput, mcpForm, openAIForm, urlElicitation, unknown(String) }
public struct CodexDecisionChoice: Sendable, Equatable, Identifiable { public var id: String, label: String; public var raw: JSONValue; public init(id: String, label: String, raw: JSONValue) { self.id = id; self.label = label; self.raw = raw } }
public struct CodexUserQuestion: Sendable, Equatable, Identifiable { public var id: String; public var header: String?; public var question: String; public var choices: [CodexDecisionChoice]; public var raw: JSONValue }

public enum CodexApprovalDecision: Sendable, Equatable {
    case accept, acceptForSession, decline, cancel
    case acceptWithExecPolicyAmendment([String])
    case applyNetworkPolicy(host: String, allow: Bool)
    case advertised(JSONValue)
    var json: JSONValue {
        switch self {
        case .accept: "accept"
        case .acceptForSession: "acceptForSession"
        case .decline: "decline"
        case .cancel: "cancel"
        case .acceptWithExecPolicyAmendment(let amendment): ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": .array(amendment.map(JSONValue.string))]]
        case .applyNetworkPolicy(let host, let allow): ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": .string(host), "action": .string(allow ? "allow" : "deny")]]]
        case .advertised(let value): value
        }
    }
}

public enum CodexPermissionGrantScope: String, Sendable { case turn, session }
public enum CodexElicitationAction: String, Sendable { case accept, decline, cancel }

public enum CodexInteractionResponse: Sendable, Equatable {
    case decision(String), approval(CodexApprovalDecision), answers([String: [String]]), form(JSONValue), result(JSONValue)
    case permissionGrant(permissions: JSONValue, scope: CodexPermissionGrantScope, strictAutoReview: Bool? = nil)
    case elicitation(action: CodexElicitationAction, content: JSONValue? = nil, metadata: JSONValue? = nil)
    case error(code: Int, message: String, data: JSONValue? = nil)
    var json: JSONValue {
        switch self {
        case .decision(let decision): ["decision": .string(decision)]
        case .approval(let decision): ["decision": decision.json]
        case .answers(let answers): ["answers": .object(answers.mapValues { ["answers": .array($0.map(JSONValue.string))] })]
        case .form(let value), .result(let value): value
        case .permissionGrant(let permissions, let scope, let strict):
            .object(["permissions": permissions, "scope": .string(scope.rawValue), "strictAutoReview": strict.map(JSONValue.bool) ?? .null])
        case .elicitation(let action, let content, let metadata):
            .object(["action": .string(action.rawValue), "content": content ?? .null, "_meta": metadata ?? .null])
        case .error: .null
        }
    }
}

public struct CodexPendingInteraction: Sendable, Equatable, Identifiable {
    public let id: String
    public let requestID: JSONValue
    public let method: String
    public let kind: CodexInteractionKind
    public let generation: UInt64
    public let threadID: String?, turnID: String?, itemID: String?
    public let choices: [CodexDecisionChoice]
    public let questions: [CodexUserQuestion]
    public let raw: JSONValue
    public let response: CodexInteractionResponseHandle
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.generation == rhs.generation && lhs.raw == rhs.raw }
}

public actor CodexInteractionResponseHandle {
    private let client: CodexClient
    private let requestID: JSONValue
    private let generation: UInt64
    private var used = false
    init(client: CodexClient, requestID: JSONValue, generation: UInt64) { self.client = client; self.requestID = requestID; self.generation = generation }
    public func respond(_ response: CodexInteractionResponse) async throws {
        guard !used else { throw CodexError.responseAlreadySent }
        try await client.respondToServerRequest(id: requestID, response: response, generation: generation)
        used = true
    }
}
public typealias CodexInteractionHandler = @Sendable (CodexPendingInteraction) async -> CodexInteractionResponse?
