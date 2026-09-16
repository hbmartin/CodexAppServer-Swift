import Foundation

public extension CodexClient {
    func listThreads(_ query: CodexThreadQuery = .init()) async throws -> CodexPage<CodexThread> {
        try validatePageLimit(query.limit)
        let result = try await rawRequest(method: "thread/list", params: query.json)
        let items = decodeList(result["data"]?.arrayValue ?? result["threads"]?.arrayValue ?? [], method: "thread/list", using: CodexThread.init)
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, backwardsCursor: result["backwardsCursor"]?.stringValue, raw: result)
    }

    func listArchivedThreads(cursor: String? = nil, limit: Int? = nil) async throws -> CodexPage<CodexThread> {
        try await listThreads(.init(cursor: cursor, limit: limit, archived: true))
    }

    func readThread(id: String, includeTurns: Bool = false) async throws -> CodexThread {
        try validateID(id, name: "threadID")
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
        try validateID(id, name: "threadID")
        _ = try await resumeThread(id: id)
        let thread = try await readThread(id: id, includeTurns: true)
        explicitSubscriptionIntents.insert(id)
        if restorationThreadIDs.count == 9 { emit(.diagnostic(.highThreadSubscriptionCount(restorationThreadIDs.count))) }
        return thread
    }

    func unsubscribeThread(id: String) async throws {
        try validateID(id, name: "threadID")
        _ = try await rawRequest(method: "thread/unsubscribe", params: ["threadId": .string(id)])
        explicitSubscriptionIntents.remove(id)
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
        return try decodeMutationResponse(result, method: "thread/start") {
            guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
            return try CodexThread(raw: raw)
        }
    }

    @discardableResult
    func resumeThread(id: String) async throws -> CodexThread {
        try validateID(id, name: "threadID")
        let result = try await rawRequest(method: "thread/resume", params: ["threadId": .string(id)])
        guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
        return try CodexThread(raw: raw)
    }

    @discardableResult
    func forkThread(id: String, mode: CodexForkMode = .fullHistory) async throws -> CodexThread {
        try validateID(id, name: "threadID")
        var params: [String: JSONValue] = ["threadId": .string(id)]
        if mode == .lastTurn, let last = try await listTurns(threadID: id, limit: 1, itemView: .omitted).items.first { params["lastTurnId"] = .string(last.id) }
        let result = try await rawRequest(method: "thread/fork", params: .object(params))
        return try decodeMutationResponse(result, method: "thread/fork") {
            guard let raw = result["thread"] else { throw CodexError.missingField("thread") }
            return try CodexThread(raw: raw)
        }
    }

    func listTurns(threadID: String, cursor: String? = nil, limit: Int? = nil, itemView: CodexHistoryItemView = .summarized, sortDirection: CodexSortDirection? = nil) async throws -> CodexPage<CodexTurn> {
        try validateID(threadID, name: "threadID")
        try validatePageLimit(limit)
        var params: [String: JSONValue] = ["threadId": .string(threadID), "itemsView": .string(itemView.rawValue)]
        if let cursor { params["cursor"] = .string(cursor) }; if let limit { params["limit"] = .number(Decimal(limit)) }
        if let sortDirection { params["sortDirection"] = .string(sortDirection.rawValue) }
        let result = try await rawRequest(method: "thread/turns/list", params: .object(params))
        let items = decodeList(result["data"]?.arrayValue ?? result["turns"]?.arrayValue ?? [], method: "thread/turns/list", threadID: threadID) { try CodexTurn(threadID: threadID, raw: $0) }
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, backwardsCursor: result["backwardsCursor"]?.stringValue, raw: result)
    }

    func listItems(threadID: String, turnID: String? = nil, cursor: String? = nil, limit: Int? = nil, sortDirection: CodexSortDirection? = nil) async throws -> CodexPage<CodexItem> {
        try validateID(threadID, name: "threadID"); if let turnID { try validateID(turnID, name: "turnID") }
        try validatePageLimit(limit)
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        if let turnID { params["turnId"] = .string(turnID) }; if let cursor { params["cursor"] = .string(cursor) }; if let limit { params["limit"] = .number(Decimal(limit)) }
        if let sortDirection { params["sortDirection"] = .string(sortDirection.rawValue) }
        let result = try await rawRequest(method: "thread/items/list", params: .object(params))
        let items = decodeList(result["data"]?.arrayValue ?? [], method: "thread/items/list", threadID: threadID) { entry -> CodexItem in
            guard let raw = entry["item"] else { throw CodexError.missingField("item") }
            return try CodexItem(raw: raw, turnID: entry["turnId"]?.stringValue)
        }
        return .init(items: items, nextCursor: result["nextCursor"]?.stringValue, backwardsCursor: result["backwardsCursor"]?.stringValue, raw: result)
    }

    func renameThread(id: String, name: String) async throws { try validateID(id, name: "threadID"); _ = try await rawRequest(method: "thread/name/set", params: ["threadId": .string(id), "name": .string(name)]) }
    func setThreadPinned(id: String, pinned: Bool) async throws { try validateID(id, name: "threadID"); _ = try await rawRequest(method: "thread/metadata/update", params: ["threadId": .string(id), "isPinned": .bool(pinned)]) }
    func archiveThread(id: String) async throws { try validateID(id, name: "threadID"); _ = try await rawRequest(method: "thread/archive", params: ["threadId": .string(id)]) }
    func unarchiveThread(id: String) async throws { try validateID(id, name: "threadID"); _ = try await rawRequest(method: "thread/unarchive", params: ["threadId": .string(id)]) }
    func compactThread(id: String) async throws { try validateID(id, name: "threadID"); _ = try await rawRequest(method: "thread/compact/start", params: ["threadId": .string(id)]) }

    @discardableResult
    func startTurn(threadID: String, inputs: [CodexInput], options: CodexTurnOptions = .init()) async throws -> CodexTurn {
        try validateID(threadID, name: "threadID")
        var params: [String: JSONValue] = ["threadId": .string(threadID), "input": .array(inputs.map(\.json))]
        if let value = options.model { params["model"] = .string(value) }; if let value = options.workingDirectory { params["cwd"] = .string(value.path) }
        if let value = options.effort { params["effort"] = .string(value) }; if let value = options.approvalPolicy { params["approvalPolicy"] = .string(value.rawValue) }
        if let value = options.sandboxPolicy { params["sandboxPolicy"] = value }; if let value = options.outputSchema { params["outputSchema"] = value }; if let value = options.collaborationMode { params["collaborationMode"] = value }
        let result = try await rawRequest(method: "turn/start", params: .object(params))
        let turn = try decodeMutationResponse(result, method: "turn/start") {
            guard let raw = result["turn"] else { throw CodexError.missingField("turn") }
            return try CodexTurn(threadID: threadID, raw: raw)
        }
        reduceTurn(turn, completed: false); return turn
    }

    func startTurn(threadID: String, prompt: String, options: CodexTurnOptions = .init()) async throws -> CodexTurn { try validateID(threadID, name: "threadID"); return try await startTurn(threadID: threadID, inputs: [.text(prompt)], options: options) }

    @discardableResult
    /// Returns an acknowledgement with the server's turn ID; status and items are not returned by steering.
    func steerTurn(threadID: String, expectedTurnID: String, inputs: [CodexInput]) async throws -> CodexTurn {
        try validateID(threadID, name: "threadID"); try validateID(expectedTurnID, name: "expectedTurnID")
        let result = try await rawRequest(method: "turn/steer", params: ["threadId": .string(threadID), "expectedTurnId": .string(expectedTurnID), "input": .array(inputs.map(\.json))])
        return try decodeMutationResponse(result, method: "turn/steer") {
            let id = try result.requireString("turnId", context: "turn/steer")
            // Steering acknowledges an ID; it does not return a new turn snapshot.
            var raw = result.objectValue ?? [:]; raw["id"] = .string(id)
            return try CodexTurn(threadID: threadID, raw: .object(raw))
        }
    }

    func interruptTurn(threadID: String, turnID: String) async throws { try validateID(threadID, name: "threadID"); try validateID(turnID, name: "turnID"); _ = try await rawRequest(method: "turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(turnID)]) }
    func turnStatus(threadID: String, turnID: String) -> CodexTurnStatus? { threadStates[threadID]?.turns[turnID]?.statusValue }
    func rawTurnStatus(threadID: String, turnID: String) -> String? { threadStates[threadID]?.turns[turnID]?.status }
    func plan(threadID: String, turnID: String) -> CodexItem? {
        guard let state = threadStates[threadID] else { return nil }
        return state.itemOrder.compactMap { state.items[$0] }.first { $0.turnID == turnID && $0.kind == .plan }
    }
    func fileChanges(threadID: String, turnID: String) -> [CodexItem] {
        guard let state = threadStates[threadID] else { return [] }
        return state.itemOrder.compactMap { state.items[$0] }.filter { $0.turnID == turnID && $0.kind == .fileChange }
    }
    /// Latest usage payload containing cumulative `total` and most recent turn `last` counters.
    func turnUsage(threadID: String) -> JSONValue? { threadStates[threadID]?.tokenUsage }

    func startReview(threadID: String, target: CodexReviewTarget, detached: Bool = false) async throws -> JSONValue { try validateID(threadID, name: "threadID"); return try await rawRequest(method: "review/start", params: ["threadId": .string(threadID), "target": target.json, "delivery": .string(detached ? "detached" : "inline")]) }
    func listModels() async throws -> [CodexModel] { let result = try await rawRequest(method: "model/list"); return decodeList(result["data"]?.arrayValue ?? result["models"]?.arrayValue ?? [], method: "model/list", using: CodexModel.init) }
    func listSkills() async throws -> [CodexSkill] {
        let result = try await rawRequest(method: "skills/list")
        return decodeList((result["data"]?.arrayValue ?? []).flatMap { $0["skills"]?.arrayValue ?? [] }, method: "skills/list", using: CodexSkill.init)
    }
    func listCollaborationModes() async throws -> [CodexCollaborationMode] { let result = try await rawRequest(method: "collaborationMode/list"); return decodeList(result["data"]?.arrayValue ?? [], method: "collaborationMode/list", using: CodexCollaborationMode.init) }
    func listPermissionProfiles() async throws -> [CodexPermissionProfile] { let result = try await rawRequest(method: "permissionProfile/list"); return decodeList(result["data"]?.arrayValue ?? [], method: "permissionProfile/list", using: CodexPermissionProfile.init) }

    func searchFiles(query: String, roots: [String]) async throws -> JSONValue { try await rawRequest(method: "fuzzyFileSearch", params: ["query": .string(query), "roots": .array(roots.map(JSONValue.string))]) }
    func startFileSearch(sessionID: String, roots: [String], query: String = "") async throws -> JSONValue {
        try validateID(sessionID, name: "sessionID")
        let started = try await rawRequest(method: "fuzzyFileSearch/sessionStart", params: ["sessionId": .string(sessionID), "roots": .array(roots.map(JSONValue.string))])
        return query.isEmpty ? started : try await updateFileSearch(sessionID: sessionID, query: query)
    }
    func updateFileSearch(sessionID: String, query: String) async throws -> JSONValue { try validateID(sessionID, name: "sessionID"); return try await rawRequest(method: "fuzzyFileSearch/sessionUpdate", params: ["sessionId": .string(sessionID), "query": .string(query)]) }
    func stopFileSearch(sessionID: String) async throws { try validateID(sessionID, name: "sessionID"); _ = try await rawRequest(method: "fuzzyFileSearch/sessionStop", params: ["sessionId": .string(sessionID)]) }

    func executeCommand(command: [String], workingDirectory: String, timeout: Duration? = nil) async throws -> JSONValue { try await rawRequest(method: "command/exec", params: ["command": .array(command.map(JSONValue.string)), "cwd": .string(workingDirectory)], timeout: timeout) }
    func executeStreamingCommand(command: [String], workingDirectory: String, processID: String = UUID().uuidString, timeout: Duration? = nil) async throws -> JSONValue { try validateID(processID, name: "processID"); return try await rawRequest(method: "command/exec", params: ["command": .array(command.map(JSONValue.string)), "cwd": .string(workingDirectory), "processId": .string(processID), "streamStdoutStderr": true, "streamStdin": false, "tty": false], timeout: timeout) }
    func terminateCommand(processID: String) async throws { try validateID(processID, name: "processID"); _ = try await rawRequest(method: "command/exec/terminate", params: ["processId": .string(processID)]) }
    func runThreadShellCommand(threadID: String, command: String) async throws -> JSONValue { try validateID(threadID, name: "threadID"); return try await rawRequest(method: "thread/shellCommand", params: ["threadId": .string(threadID), "command": .string(command)]) }
    func listBackgroundTerminals(threadID: String) async throws -> JSONValue { try validateID(threadID, name: "threadID"); return try await rawRequest(method: "thread/backgroundTerminals/list", params: ["threadId": .string(threadID)]) }
    func cleanBackgroundTerminals(threadID: String) async throws { try validateID(threadID, name: "threadID"); _ = try await rawRequest(method: "thread/backgroundTerminals/clean", params: ["threadId": .string(threadID)]) }
    func terminateBackgroundTerminal(threadID: String, processID: String) async throws { try validateID(threadID, name: "threadID"); try validateID(processID, name: "processID"); _ = try await rawRequest(method: "thread/backgroundTerminals/terminate", params: ["threadId": .string(threadID), "processId": .string(processID)]) }

    func fileMetadata(path: String, roots: CodexWorkspaceRoots) async throws -> CodexFileMetadata {
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let value = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(path)])
        return try .init(path: path, raw: value)
    }
    func listDirectory(path: String, roots: CodexWorkspaceRoots, detail: CodexDirectoryListingDetail = .basic) async throws -> CodexDirectoryListing {
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let result = try await rawRequest(method: "fs/readDirectory", params: ["path": .string(path)])
        guard let rawEntries = result["entries"]?.arrayValue else { throw CodexError.invalidField("directory.entries") }
        let children = try rawEntries.map { raw -> CodexDirectoryEntry in
            let name = try raw.requireString("fileName", context: "directoryEntry")
            guard name != ".", name != "..", !name.contains("/") else { throw CodexError.unsafePath(name) }
            let childPath = try roots.validateAbsolutePath(URL(fileURLWithPath: path).appendingPathComponent(name).path)
            let isDirectory = try raw.requireBool("isDirectory", context: "directoryEntry")
            let isFile = try raw.requireBool("isFile", context: "directoryEntry")
            return .init(path: childPath, name: name, isDirectory: isDirectory, isFile: isFile, symlinkStatus: .unknown, createdAtMilliseconds: nil, modifiedAtMilliseconds: nil, raw: raw, metadataRaw: nil)
        }
        guard case .metadata(let maximumConcurrentMetadataRequests) = detail else {
            return .init(entries: children, raw: result)
        }
        guard (1...64).contains(maximumConcurrentMetadataRequests) else {
            throw CodexError.invalidArgument("maximumConcurrentRequests must be from 1 through 64")
        }
        var enriched = children
        var diagnostics: [CodexDirectoryDiagnostic] = []
        await withTaskGroup(of: (Int, Result<CodexFileMetadata, any Error>).self) { group in
            var nextIndex = 0
            func addNext() {
                let index = nextIndex
                nextIndex += 1
                let childPath = children[index].path
                group.addTask {
                    do {
                        let metadata = try await self.rawRequest(method: "fs/getMetadata", params: ["path": .string(childPath)])
                        return (index, .success(try CodexFileMetadata(path: childPath, raw: metadata)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for _ in 0..<min(maximumConcurrentMetadataRequests, children.count) { addNext() }
            while let (index, outcome) = await group.next() {
                switch outcome {
                case .success(let metadata):
                    enriched[index].isDirectory = metadata.isDirectory
                    enriched[index].isFile = metadata.isFile
                    enriched[index].symlinkStatus = metadata.symlinkStatus
                    enriched[index].createdAtMilliseconds = metadata.createdAtMilliseconds
                    enriched[index].modifiedAtMilliseconds = metadata.modifiedAtMilliseconds
                    enriched[index].metadataRaw = metadata.raw
                case .failure(let error):
                    diagnostics.append(.init(path: children[index].path, message: error.localizedDescription))
                }
                if nextIndex < children.count { addNext() }
            }
        }
        diagnostics.sort { $0.path < $1.path }
        return .init(entries: enriched, diagnostics: diagnostics, raw: result)
    }
    func readFile(path: String, roots: CodexWorkspaceRoots, maximumBytes: Int = 32 * 1_024 * 1_024) async throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= Int.max - 2 else { throw CodexError.invalidArgument("maximumBytes is out of range") }
        let path = try roots.validateAbsolutePath(path); try await rejectSymlinkComponents(path: path, roots: roots)
        let result = try await rawRequest(method: "fs/readFile", params: ["path": .string(path)])
        guard let encoded = result["dataBase64"]?.stringValue else { throw CodexError.invalidField("file.dataBase64") }
        let encodedLimit = ((maximumBytes + 2) / 3).multipliedReportingOverflow(by: 4)
        guard !encodedLimit.overflow, encoded.utf8.count <= encodedLimit.partialValue else { throw CodexError.frameTooLarge(actual: encoded.utf8.count, limit: encodedLimit.partialValue) }
        guard let data = Data(base64Encoded: encoded) else { throw CodexError.invalidField("file.dataBase64") }
        guard data.count <= maximumBytes else { throw CodexError.frameTooLarge(actual: data.count, limit: maximumBytes) }
        return data
    }

    private func validateID(_ value: String, name: String) throws {
        guard !value.isEmpty else { throw CodexError.invalidArgument("\(name) must not be empty") }
    }

    private func validatePageLimit(_ limit: Int?) throws {
        if let limit, UInt32(exactly: limit) == nil { throw CodexError.invalidArgument("limit must fit an unsigned 32-bit integer") }
    }

    private func decodeList<T>(_ values: [JSONValue], method: String, threadID: String? = nil, using decode: (JSONValue) throws -> T) -> [T] {
        var items: [T] = []
        var skipped = 0
        for value in values {
            do { items.append(try decode(value)) }
            catch { skipped += 1 }
        }
        if skipped > 0 { emit(malformed(method, "skipped \(skipped) malformed entries", threadID: threadID)) }
        return items
    }

    private func decodeMutationResponse<T>(_ response: JSONValue, method: String, using decode: () throws -> T) throws -> T {
        do { return try decode() }
        catch { throw CodexError.invalidMutationResponse(method: method, reason: error.localizedDescription, response: response) }
    }

    private func rejectSymlinkComponents(path: String, roots: CodexWorkspaceRoots) async throws {
        guard let root = roots.containingRoot(for: path) else { throw CodexError.unsafePath(path) }
        let rootMetadata = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(root)])
        if try CodexFileMetadata(path: root, raw: rootMetadata).symlinkStatus == .symlink { throw CodexError.unsafePath(path) }
        let suffix = String(path.dropFirst(root.count)); var current = root
        for component in NSString(string: suffix).pathComponents where component != "/" {
            current = URL(fileURLWithPath: current).appendingPathComponent(component).path
            let metadata = try await rawRequest(method: "fs/getMetadata", params: ["path": .string(current)])
            if try CodexFileMetadata(path: current, raw: metadata).symlinkStatus == .symlink { throw CodexError.unsafePath(path) }
        }
    }
}
