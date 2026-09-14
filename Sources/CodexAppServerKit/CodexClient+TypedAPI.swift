import Foundation

public extension CodexClient {
    func listThreads(_ query: CodexThreadQuery = .init()) async throws -> CodexPage<CodexThread> {
        let result = try await rawRequest(method: "thread/list", params: query.json)
        let items = try (result["data"]?.arrayValue ?? result["threads"]?.arrayValue ?? []).map(CodexThread.init)
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, raw: result)
    }

    func listArchivedThreads(cursor: String? = nil, limit: Int? = nil) async throws -> CodexPage<CodexThread> {
        try await listThreads(.init(cursor: cursor, limit: limit, archived: true))
    }

    func readThread(id: String, includeTurns: Bool = false) async throws -> CodexThread {
        let result = try await rawRequest(method: "thread/read", params: ["threadId": .string(id), "includeTurns": .bool(includeTurns)])
        guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
        return try CodexThread(raw: raw)
    }

    func listLoadedThreads(cursor: String? = nil, limit: Int? = nil) async throws -> CodexPage<String> {
        var params: [String: JSONValue] = [:]; if let cursor { params["cursor"] = .string(cursor) }; if let limit { params["limit"] = .number(Decimal(limit)) }
        let result = try await rawRequest(method: "thread/loaded/list", params: .object(params))
        return .init(items: (result["data"]?.arrayValue ?? []).compactMap(\.stringValue), nextCursor: result["nextCursor"]?.stringValue, raw: result)
    }

    @discardableResult
    func subscribeThread(id: String) async throws -> CodexThread {
        guard !id.isEmpty else { throw CodexError.missingField("thread.id") }
        _ = try await resumeThread(id: id)
        subscriptionIntents.insert(id)
        if subscriptionIntents.count == 9 { emit(.diagnostic(.highThreadSubscriptionCount(subscriptionIntents.count))) }
        return try await readThread(id: id, includeTurns: true)
    }

    func unsubscribeThread(id: String) async throws {
        _ = try await rawRequest(method: "thread/unsubscribe", params: ["threadId": .string(id)])
        subscriptionIntents.remove(id)
    }

    @discardableResult
    func startThread(options: CodexThreadOptions = .init()) async throws -> CodexThread {
        if options.permissions != nil, options.sandbox != nil { throw CodexError.invalidConfiguration("permissions and sandbox are mutually exclusive") }
        var params: [String: JSONValue] = [:]
        if let model = options.model { params["model"] = .string(model) }; if let cwd = options.workingDirectory { params["cwd"] = .string(cwd.path) }
        if let approval = options.approvalPolicy { params["approvalPolicy"] = .string(approval.rawValue) }; if let sandbox = options.sandbox { params["sandbox"] = .string(sandbox.rawValue) }
        if let permissions = options.permissions { params["permissions"] = permissions }; if let value = options.developerInstructions { params["developerInstructions"] = .string(value) }
        if let value = options.baseInstructions { params["baseInstructions"] = .string(value) }; if let value = options.ephemeral { params["ephemeral"] = .bool(value) }
        if !options.configuration.isEmpty { params["config"] = .object(options.configuration) }
        let tools = await dynamicTools.specifications(); if !tools.isEmpty { params["dynamicTools"] = .array(tools) }
        let result = try await rawRequest(method: "thread/start", params: .object(params))
        guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
        return try CodexThread(raw: raw)
    }

    @discardableResult
    func resumeThread(id: String) async throws -> CodexThread {
        let result = try await rawRequest(method: "thread/resume", params: ["threadId": .string(id)])
        guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
        return try CodexThread(raw: raw)
    }

    @discardableResult
    func forkThread(id: String, mode: CodexForkMode = .fullHistory) async throws -> CodexThread {
        var params: [String: JSONValue] = ["threadId": .string(id)]
        if mode == .lastTurn, let last = try await listTurns(threadID: id, limit: 1, itemView: .omitted).items.first { params["lastTurnId"] = .string(last.id) }
        let result = try await rawRequest(method: "thread/fork", params: .object(params))
        guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
        return try .init(raw: raw)
    }

    func listTurns(threadID: String, cursor: String? = nil, limit: Int? = nil, itemView: CodexHistoryItemView = .summarized) async throws -> CodexPage<CodexTurn> {
        var params: [String: JSONValue] = ["threadId": .string(threadID), "itemsView": .string(itemView.rawValue)]
        if let cursor { params["cursor"] = .string(cursor) }; if let limit { params["limit"] = .number(Decimal(limit)) }
        let result = try await rawRequest(method: "thread/turns/list", params: .object(params))
        let items = try (result["data"]?.arrayValue ?? result["turns"]?.arrayValue ?? []).map { try CodexTurn(threadID: threadID, raw: $0) }
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, raw: result)
    }

    func listItems(threadID: String, turnID: String? = nil, cursor: String? = nil, limit: Int? = nil, view: CodexHistoryItemView = .full) async throws -> CodexPage<CodexItem> {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        if let turnID { params["turnId"] = .string(turnID) }; if let cursor { params["cursor"] = .string(cursor) }; if let limit { params["limit"] = .number(Decimal(limit)) }
        let result = try await rawRequest(method: "thread/items/list", params: .object(params))
        let items = try (result["data"]?.arrayValue ?? []).map { entry -> CodexItem in
            guard let raw = entry["item"] else { throw CodexError.missingField("item") }
            return try CodexItem(raw: raw, turnID: entry["turnId"]?.stringValue)
        }
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, raw: result)
    }

    func renameThread(id: String, name: String) async throws { _ = try await rawRequest(method: "thread/name/set", params: ["threadId": .string(id), "name": .string(name)]) }
    func setThreadPinned(id: String, pinned: Bool) async throws { _ = try await rawRequest(method: "thread/metadata/update", params: ["threadId": .string(id), "isPinned": .bool(pinned)]) }
    func archiveThread(id: String) async throws { _ = try await rawRequest(method: "thread/archive", params: ["threadId": .string(id)]) }
    func unarchiveThread(id: String) async throws { _ = try await rawRequest(method: "thread/unarchive", params: ["threadId": .string(id)]) }
    func compactThread(id: String) async throws { _ = try await rawRequest(method: "thread/compact/start", params: ["threadId": .string(id)]) }

    @discardableResult
    func startTurn(threadID: String, inputs: [CodexInput], options: CodexTurnOptions = .init()) async throws -> CodexTurn {
        var params: [String: JSONValue] = ["threadId": .string(threadID), "input": .array(inputs.map(\.json))]
        if let value = options.model { params["model"] = .string(value) }; if let value = options.workingDirectory { params["cwd"] = .string(value.path) }
        if let value = options.effort { params["effort"] = .string(value) }; if let value = options.approvalPolicy { params["approvalPolicy"] = .string(value.rawValue) }
        if let value = options.sandboxPolicy { params["sandboxPolicy"] = value }; if let value = options.outputSchema { params["outputSchema"] = value }; if let value = options.collaborationMode { params["collaborationMode"] = value }
        let result = try await rawRequest(method: "turn/start", params: .object(params))
        guard let raw = result["turn"] else { throw CodexError.missingField("turn") }
        let turn = try CodexTurn(threadID: threadID, raw: raw); reduceTurn(turn, completed: false); return turn
    }

    func startTurn(threadID: String, prompt: String, options: CodexTurnOptions = .init()) async throws -> CodexTurn { try await startTurn(threadID: threadID, inputs: [.text(prompt)], options: options) }

    @discardableResult
    /// Returns an acknowledgement with the server's turn ID; status and items are not returned by steering.
    func steerTurn(threadID: String, expectedTurnID: String, inputs: [CodexInput]) async throws -> CodexTurn {
        let result = try await rawRequest(method: "turn/steer", params: ["threadId": .string(threadID), "expectedTurnId": .string(expectedTurnID), "input": .array(inputs.map(\.json))])
        guard let id = result["turnId"]?.stringValue else { throw CodexError.missingField("turnId") }
        // Steering acknowledges an ID; it does not return a new turn snapshot.
        var raw = result.objectValue ?? [:]; raw["id"] = .string(id)
        return try .init(threadID: threadID, raw: .object(raw))
    }

    func interruptTurn(threadID: String, turnID: String) async throws { _ = try await rawRequest(method: "turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(turnID)]) }
    func turnStatus(threadID: String, turnID: String) -> String? { threadStates[threadID]?.turns[turnID]?.status }
    func turnPlan(threadID: String) -> CodexItem? { threadStates[threadID]?.items.values.first(where: { $0.kind == CodexItemKind.plan }) }
    func turnDiff(threadID: String) -> [CodexItem] { threadStates[threadID]?.items.values.filter { $0.kind == .fileChange } ?? [] }
    /// Latest usage payload containing cumulative `total` and most recent turn `last` counters.
    func turnUsage(threadID: String) -> JSONValue? { threadStates[threadID]?.tokenUsage }

    func startReview(threadID: String, target: CodexReviewTarget, detached: Bool = false) async throws -> JSONValue { try await rawRequest(method: "review/start", params: ["threadId": .string(threadID), "target": target.json, "delivery": .string(detached ? "detached" : "inline")]) }
    func listModels() async throws -> [CodexModel] { let result = try await rawRequest(method: "model/list"); return try (result["data"]?.arrayValue ?? result["models"]?.arrayValue ?? []).map(CodexModel.init) }
    func listSkills() async throws -> [CodexSkill] {
        let result = try await rawRequest(method: "skills/list")
        return try (result["data"]?.arrayValue ?? []).flatMap { try ($0["skills"]?.arrayValue ?? []).map(CodexSkill.init) }
    }
    func listCollaborationModes() async throws -> [CodexCollaborationMode] { let result = try await rawRequest(method: "collaborationMode/list"); return try (result["data"]?.arrayValue ?? []).map(CodexCollaborationMode.init) }
    func listPermissionProfiles() async throws -> [CodexPermissionProfile] { let result = try await rawRequest(method: "permissionProfile/list"); return try (result["data"]?.arrayValue ?? []).map(CodexPermissionProfile.init) }

    func searchFiles(query: String, roots: [String]) async throws -> JSONValue { try await rawRequest(method: "fuzzyFileSearch", params: ["query": .string(query), "roots": .array(roots.map(JSONValue.string))]) }
    func startFileSearch(sessionID: String, roots: [String], query: String = "") async throws -> JSONValue {
        let started = try await rawRequest(method: "fuzzyFileSearch/sessionStart", params: ["sessionId": .string(sessionID), "roots": .array(roots.map(JSONValue.string))])
        return query.isEmpty ? started : try await updateFileSearch(sessionID: sessionID, query: query)
    }
    func updateFileSearch(sessionID: String, query: String) async throws -> JSONValue { try await rawRequest(method: "fuzzyFileSearch/sessionUpdate", params: ["sessionId": .string(sessionID), "query": .string(query)]) }
    func stopFileSearch(sessionID: String) async throws { _ = try await rawRequest(method: "fuzzyFileSearch/sessionStop", params: ["sessionId": .string(sessionID)]) }

    func executeCommand(command: [String], workingDirectory: String, timeout: Duration? = nil) async throws -> JSONValue { try await rawRequest(method: "command/exec", params: ["command": .array(command.map(JSONValue.string)), "cwd": .string(workingDirectory)], timeout: timeout) }
    func executeStreamingCommand(command: [String], workingDirectory: String, processID: String = UUID().uuidString, timeout: Duration? = nil) async throws -> JSONValue { try await rawRequest(method: "command/exec", params: ["command": .array(command.map(JSONValue.string)), "cwd": .string(workingDirectory), "processId": .string(processID), "streamStdoutStderr": true, "streamStdin": false, "tty": false], timeout: timeout) }
    func terminateCommand(processID: String) async throws { _ = try await rawRequest(method: "command/exec/terminate", params: ["processId": .string(processID)]) }
    func runThreadShellCommand(threadID: String, command: String) async throws -> JSONValue { try await rawRequest(method: "thread/shellCommand", params: ["threadId": .string(threadID), "command": .string(command)]) }
    func listBackgroundTerminals(threadID: String) async throws -> JSONValue { try await rawRequest(method: "thread/backgroundTerminals/list", params: ["threadId": .string(threadID)]) }
    func cleanBackgroundTerminals(threadID: String) async throws { _ = try await rawRequest(method: "thread/backgroundTerminals/clean", params: ["threadId": .string(threadID)]) }
    func terminateBackgroundTerminal(threadID: String, processID: String) async throws { _ = try await rawRequest(method: "thread/backgroundTerminals/terminate", params: ["threadId": .string(threadID), "processId": .string(processID)]) }

    func fileMetadata(path: String, roots: CodexWorkspaceRoots) async throws -> CodexFileMetadata {
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let value = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(path)])
        return .init(path: path, isDirectory: value["isDirectory"]?.boolValue ?? false, isFile: value["isFile"]?.boolValue ?? false, isSymlink: value["isSymlink"]?.boolValue ?? false, raw: value)
    }
    func listDirectory(path: String, roots: CodexWorkspaceRoots) async throws -> [CodexDirectoryEntry] {
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let result = try await rawRequest(method: "fs/readDirectory", params: ["path": .string(path)])
        return try (result["entries"]?.arrayValue ?? []).map { raw in
            // `isSymlink` is a security-relevant signal; report what the server said rather than assuming false.
            let name = try raw.requireString("fileName", context: "directoryEntry")
            return .init(path: path + "/" + name, name: name, isDirectory: raw["isDirectory"]?.boolValue ?? false, isSymlink: raw["isSymlink"]?.boolValue ?? false, raw: raw)
        }
    }
    func readFile(path: String, roots: CodexWorkspaceRoots, maximumBytes: Int = 32 * 1_024 * 1_024) async throws -> Data {
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let result = try await rawRequest(method: "fs/readFile", params: ["path": .string(path)])
        guard let encoded = result["dataBase64"]?.stringValue, let data = Data(base64Encoded: encoded) else { throw CodexError.missingField("dataBase64") }
        guard data.count <= maximumBytes else { throw CodexError.frameTooLarge(actual: data.count, limit: maximumBytes) }
        return data
    }

    private func rejectSymlinkComponents(path: String, roots: CodexWorkspaceRoots) async throws {
        guard let root = roots.roots.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { throw CodexError.unsafePath(path) }
        let rootMetadata = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(root)])
        if rootMetadata["isSymlink"]?.boolValue == true { throw CodexError.unsafePath(path) }
        let suffix = String(path.dropFirst(root.count)); var current = root
        for component in NSString(string: suffix).pathComponents where component != "/" {
            current = URL(fileURLWithPath: current).appendingPathComponent(component).path
            let metadata = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(current)])
            if metadata["isSymlink"]?.boolValue == true { throw CodexError.unsafePath(path) }
        }
    }
}
