import Foundation

public protocol CodexRawModel: Sendable, Equatable { var raw: JSONValue { get } }

public struct CodexThread: CodexRawModel, Identifiable {
    public let raw: JSONValue
    public var id: String { raw["id"]?.stringValue ?? "" }
    public var name: String? { raw["name"]?.stringValue }
    public var status: String? { raw["status"]?.stringValue ?? raw["status"]?["type"]?.stringValue }
    public var statusValue: CodexThreadStatus { .init(raw["status"] ?? .null) }
    public init(raw: JSONValue) { self.raw = raw }
}

public enum CodexThreadStatus: Sendable, Equatable {
    case notLoaded, idle, systemError, active(flags: Set<String>), unknown(JSONValue)
    public init(_ raw: JSONValue) {
        switch raw.stringValue ?? raw["type"]?.stringValue {
        case "notLoaded": self = .notLoaded
        case "idle": self = .idle
        case "systemError": self = .systemError
        case "active": self = .active(flags: Set(raw["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        default: self = .unknown(raw)
        }
    }
}
public struct CodexTurn: CodexRawModel, Identifiable {
    public let threadID: String
    public let raw: JSONValue
    public var id: String { raw["id"]?.stringValue ?? "" }
    public var status: String? { raw["status"]?.stringValue }
    public init(threadID: String, raw: JSONValue) { self.threadID = threadID; self.raw = raw }
}

public enum CodexItemKind: Sendable, Equatable {
    case userMessage, hookPrompt, agentMessage, plan, reasoning, commandExecution, fileChange, mcpToolCall
    case dynamicToolCall, collaborationAgentToolCall, subAgentActivity, webSearch, imageView, sleep, imageGeneration
    case enteredReviewMode, exitedReviewMode, contextCompaction
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "userMessage": self = .userMessage
        case "hookPrompt": self = .hookPrompt
        case "agentMessage": self = .agentMessage
        case "plan": self = .plan
        case "reasoning": self = .reasoning
        case "commandExecution": self = .commandExecution
        case "fileChange": self = .fileChange
        case "mcpToolCall": self = .mcpToolCall
        case "webSearch": self = .webSearch
        case "imageView": self = .imageView
        case "enteredReviewMode": self = .enteredReviewMode
        case "exitedReviewMode": self = .exitedReviewMode
        case "contextCompaction": self = .contextCompaction
        case "dynamicToolCall": self = .dynamicToolCall
        case "collabAgentToolCall": self = .collaborationAgentToolCall
        case "subAgentActivity": self = .subAgentActivity
        case "sleep": self = .sleep
        case "imageGeneration": self = .imageGeneration
        default: self = .unknown(value)
        }
    }
}
public struct CodexItem: CodexRawModel, Identifiable {
    public let raw: JSONValue
    public var id: String { raw["id"]?.stringValue ?? "" }
    public var kind: CodexItemKind { .init(raw["type"]?.stringValue ?? "unknown") }
    public init(raw: JSONValue) { self.raw = raw }
}

public struct CodexPage<Element: Sendable & Equatable>: Sendable, Equatable {
    public var items: [Element]
    public var nextCursor: String?
    public var raw: JSONValue
    public init(items: [Element], nextCursor: String?, raw: JSONValue) { self.items = items; self.nextCursor = nextCursor; self.raw = raw }
}

public enum CodexHistoryItemView: String, Sendable { case omitted = "notLoaded", summarized = "summary", full }
public enum CodexForkMode: String, Sendable { case fullHistory = "full", lastTurn = "lastTurn" }
public enum CodexApprovalPolicy: String, Sendable { case untrusted, onFailure = "on-failure", onRequest = "on-request", never }
public enum CodexSandboxMode: String, Sendable { case readOnly = "read-only", workspaceWrite = "workspace-write", dangerFullAccess = "danger-full-access" }

public struct CodexThreadQuery: Sendable {
    public var cursor: String?, search: String?
    public var limit: Int?
    public var archived: Bool?
    public var sourceKinds: [String]
    public var workingDirectories: [String]
    public var pinned: Bool?
    public var modelProviders: [String]
    public var parentThreadID: String?, ancestorThreadID: String?
    public var sortKey: String?, sortDirection: String?
    public var useStateDatabaseOnly: Bool
    public init(cursor: String? = nil, limit: Int? = nil, archived: Bool? = nil, sourceKinds: [String] = [], search: String? = nil, workingDirectories: [String] = [], pinned: Bool? = nil, modelProviders: [String] = [], parentThreadID: String? = nil, ancestorThreadID: String? = nil, sortKey: String? = nil, sortDirection: String? = nil, useStateDatabaseOnly: Bool = false) {
        self.cursor = cursor; self.limit = limit; self.archived = archived; self.sourceKinds = sourceKinds; self.search = search; self.workingDirectories = workingDirectories; self.pinned = pinned; self.modelProviders = modelProviders; self.parentThreadID = parentThreadID; self.ancestorThreadID = ancestorThreadID; self.sortKey = sortKey; self.sortDirection = sortDirection; self.useStateDatabaseOnly = useStateDatabaseOnly
    }
    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        if let cursor { value["cursor"] = .string(cursor) }; if let limit { value["limit"] = .number(Decimal(limit)) }
        if let archived { value["archived"] = .bool(archived) }; if !sourceKinds.isEmpty { value["sourceKinds"] = .array(sourceKinds.map(JSONValue.string)) }
        if let search { value["searchTerm"] = .string(search) }
        if !workingDirectories.isEmpty { value["cwd"] = .array(workingDirectories.map(JSONValue.string)) }
        if let pinned { value["isPinned"] = .bool(pinned) }; if !modelProviders.isEmpty { value["modelProviders"] = .array(modelProviders.map(JSONValue.string)) }
        if let parentThreadID { value["parentThreadId"] = .string(parentThreadID) }; if let ancestorThreadID { value["ancestorThreadId"] = .string(ancestorThreadID) }
        if let sortKey { value["sortKey"] = .string(sortKey) }; if let sortDirection { value["sortDirection"] = .string(sortDirection) }
        if useStateDatabaseOnly { value["useStateDbOnly"] = true }
        return .object(value)
    }
}

public struct CodexThreadOptions: Sendable {
    public var model: String?, developerInstructions: String?, baseInstructions: String?
    public var workingDirectory: URL?
    public var approvalPolicy: CodexApprovalPolicy?
    public var sandbox: CodexSandboxMode?
    public var permissions: JSONValue?
    public var ephemeral: Bool?
    public var configuration: [String: JSONValue]
    public init(model: String? = nil, workingDirectory: URL? = nil, approvalPolicy: CodexApprovalPolicy? = nil, sandbox: CodexSandboxMode? = nil, permissions: JSONValue? = nil, developerInstructions: String? = nil, baseInstructions: String? = nil, ephemeral: Bool? = nil, configuration: [String: JSONValue] = [:]) {
        self.model = model; self.workingDirectory = workingDirectory; self.approvalPolicy = approvalPolicy; self.sandbox = sandbox; self.permissions = permissions; self.developerInstructions = developerInstructions; self.baseInstructions = baseInstructions; self.ephemeral = ephemeral; self.configuration = configuration
    }
}
public struct CodexTurnOptions: Sendable {
    public var model: String?, effort: String?
    public var workingDirectory: URL?
    public var approvalPolicy: CodexApprovalPolicy?
    public var sandboxPolicy: JSONValue?, outputSchema: JSONValue?, collaborationMode: JSONValue?
    public init(model: String? = nil, workingDirectory: URL? = nil, effort: String? = nil, approvalPolicy: CodexApprovalPolicy? = nil, sandboxPolicy: JSONValue? = nil, outputSchema: JSONValue? = nil, collaborationMode: JSONValue? = nil) { self.model = model; self.workingDirectory = workingDirectory; self.effort = effort; self.approvalPolicy = approvalPolicy; self.sandboxPolicy = sandboxPolicy; self.outputSchema = outputSchema; self.collaborationMode = collaborationMode }
}

public enum CodexInput: Sendable, Equatable {
    case text(String), imageURL(String, detail: String? = nil), localImage(URL, detail: String? = nil)
    case audioURL(String), localAudio(URL), skill(name: String, path: String), mention(name: String, path: String)
    var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .imageURL(let url, let detail): .object(["type": "image", "url": .string(url), "detail": detail.map(JSONValue.string) ?? .null])
        case .localImage(let url, let detail): .object(["type": "localImage", "path": .string(url.path), "detail": detail.map(JSONValue.string) ?? .null])
        case .audioURL(let url): ["type": "audio", "url": .string(url)]
        case .localAudio(let url): ["type": "localAudio", "path": .string(url.path)]
        case .skill(let name, let path): ["type": "skill", "name": .string(name), "path": .string(path)]
        case .mention(let name, let path): ["type": "mention", "name": .string(name), "path": .string(path)]
        }
    }
}

public struct CodexModel: CodexRawModel, Identifiable { public let raw: JSONValue; public var id: String { raw["id"]?.stringValue ?? raw["model"]?.stringValue ?? "" }; public init(raw: JSONValue) { self.raw = raw } }
public struct CodexSkill: CodexRawModel, Identifiable { public let raw: JSONValue; public var id: String { raw["name"]?.stringValue ?? "" }; public init(raw: JSONValue) { self.raw = raw } }
public struct CodexCollaborationMode: CodexRawModel, Identifiable { public let raw: JSONValue; public var id: String { raw["name"]?.stringValue ?? raw["mode"]?.stringValue ?? "" }; public init(raw: JSONValue) { self.raw = raw } }
public struct CodexPermissionProfile: CodexRawModel, Identifiable { public let raw: JSONValue; public var id: String { raw["name"]?.stringValue ?? "" }; public init(raw: JSONValue) { self.raw = raw } }

public struct CodexReviewTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case uncommitted, baseBranch(String), commit(String), custom(String) }
    public var kind: Kind
    public var instructions: String?
    public init(_ kind: Kind, instructions: String? = nil) { self.kind = kind; self.instructions = instructions }
    var json: JSONValue {
        var value: [String: JSONValue]
        switch kind {
        case .uncommitted: value = ["type": "uncommittedChanges"]
        case .baseBranch(let branch): value = ["type": "baseBranch", "branch": .string(branch)]
        case .commit(let commit): value = ["type": "commit", "commit": .string(commit)]
        case .custom(let prompt): value = ["type": "custom", "prompt": .string(prompt)]
        }
        if let instructions { value["instructions"] = .string(instructions) }
        return .object(value)
    }
}
