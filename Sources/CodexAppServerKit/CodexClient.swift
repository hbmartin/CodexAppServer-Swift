import Foundation

public struct CodexRawClient: Sendable {
    private let client: CodexClient
    init(client: CodexClient) { self.client = client }
    public func request(method: String, params: JSONValue = .object([:]), timeout: Duration? = nil) async throws -> JSONValue {
        try await client.rawRequest(method: method, params: params, timeout: timeout)
    }
    public func notify(method: String, params: JSONValue? = nil) async throws { try await client.rawNotify(method: method, params: params) }
}

/// Actor-based, bidirectional JSON-RPC engine for Codex app-server.
public actor CodexClient {
    private struct Pending {
        let method: String
        let includesHistory: Bool
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }
    private struct Subscriber {
        let threadID: String?
        let buffer: CodexEventBuffer
    }

    private let factory: CodexTransportFactory
    private let configuration: CodexClientConfiguration
    public let dynamicTools: CodexDynamicToolRegistry
    private var transport: (any CodexTransport)?
    private var readTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var diagnosticTasks: [Task<Void, Never>] = []
    private var dynamicToolTasks: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var pending: [Int: Pending] = [:]
    private var requestCounter = 0
    private var generation: UInt64 = 0
    private var lifecycleID = UUID()
    private var activeTransportID: UUID?
    private var transportInitialized = false
    private var transportCloseTasks: [UUID: Task<Void, Never>] = [:]
    private var state: CodexConnectionState = .disconnected
    private var intentionallyClosing = false
    var threadStates: [String: CodexThreadState] = [:]
    var subscriptionIntents: Set<String> = []
    private var pendingInteractionIDs: Set<JSONValue> = []
    private var lostInteractionThreadIDs: Set<String> = []
    private var interactionHandler: CodexInteractionHandler?
    private var initializationResult: JSONValue?

    public nonisolated var raw: CodexRawClient { CodexRawClient(client: self) }

    public init(transportFactory: CodexTransportFactory, configuration: CodexClientConfiguration = .init(), dynamicTools: CodexDynamicToolRegistry = .init()) {
        self.factory = transportFactory; self.configuration = configuration; self.dynamicTools = dynamicTools
    }

    public func connectionState() -> CodexConnectionState { state }
    public func currentGeneration() -> UInt64 { generation }
    public func state(for threadID: String) -> CodexThreadState? { threadStates[threadID] }
    public func allThreadStates() -> [String: CodexThreadState] { threadStates }
    public func setInteractionHandler(_ handler: CodexInteractionHandler?) { interactionHandler = handler }

    @discardableResult
    public func connect() async throws -> JSONValue {
        switch state {
        case .connecting, .connected, .reconnecting, .recoveryRequired: throw CodexError.alreadyConnected
        case .closing: throw CodexError.closing
        default: break
        }
        intentionallyClosing = false
        let operation = UUID(); lifecycleID = operation
        setState(.connecting)
        do {
            let result = try await establishConnection(operation: operation)
            try checkOperation(operation)
            setState(.connected(generation: generation))
            return result
        } catch {
            if lifecycleID == operation {
                failAllPending(with: error)
                await tearDownTransport()
                if lifecycleID == operation { setState(.failed(error.localizedDescription)) }
            }
            throw error
        }
    }

    @discardableResult
    public func reconnect() async throws -> JSONValue {
        guard state != .closing else { throw CodexError.closing }
        let operation = UUID(); lifecycleID = operation
        reconnectTask?.cancel(); reconnectTask = nil
        intentionallyClosing = false
        setState(.connecting)
        failAllPending(with: CodexError.transportClosed("manual reconnect"))
        if !pendingInteractionIDs.isEmpty { lostInteractionThreadIDs.formUnion(subscriptionIntents) }
        invalidateInteractions()
        do {
            await tearDownTransport()
            try checkOperation(operation)
            let result = try await establishConnection(operation: operation)
            let recovery = try await restoreSubscriptionIntents(operation: operation)
            try checkOperation(operation)
            setState(recovery.map(CodexConnectionState.recoveryRequired) ?? .connected(generation: generation))
            return result
        } catch {
            if lifecycleID == operation {
                failAllPending(with: error)
                await tearDownTransport()
                if lifecycleID == operation { setState(.failed(error.localizedDescription)) }
            }
            throw error
        }
    }

    public func close() async {
        let operation = UUID(); lifecycleID = operation
        intentionallyClosing = true
        reconnectTask?.cancel(); reconnectTask = nil
        setState(.closing)
        failAllPending(with: CodexError.closing)
        invalidateInteractions()
        await tearDownTransport()
        if lifecycleID == operation { setState(.disconnected) }
    }

    public func subscribe(policy: CodexBufferingPolicy = .default) -> CodexSubscription { makeSubscription(threadID: nil, policy: policy) }
    public func events(for threadID: String, policy: CodexBufferingPolicy = .default) -> CodexSubscription { makeSubscription(threadID: threadID, policy: policy) }

    private func makeSubscription(threadID: String?, policy: CodexBufferingPolicy) -> CodexSubscription {
        let id = UUID()
        let buffer = CodexEventBuffer(policy: policy, maximumCoalescedBytes: configuration.maximumFrameBytes) { [weak self] in
            Task { await self?.removeSubscriber(id) }
        }
        let lifetime = CodexEventStreamLifetime(buffer: buffer)
        let stream = AsyncThrowingStream<CodexEvent, Error>(unfolding: { try await lifetime.buffer.next() })
        subscribers[id] = Subscriber(threadID: threadID, buffer: buffer)
        // An empty thread ID is never a real subscription intent: resuming it on reconnect would
        // send `"threadId": ""`, and it would match every event whose thread ID is absent.
        if let threadID, !threadID.isEmpty {
            subscriptionIntents.insert(threadID)
            if subscriptionIntents.count == 9 { emit(.diagnostic(.highThreadSubscriptionCount(subscriptionIntents.count))) }
        }
        return CodexSubscription(id: id, events: stream) { buffer.finish() }
    }

    private func removeSubscriber(_ id: UUID) {
        guard let removed = subscribers.removeValue(forKey: id) else { return }
        if let threadID = removed.threadID, !subscribers.values.contains(where: { $0.threadID == threadID }) { subscriptionIntents.remove(threadID) }
        removed.buffer.finish()
    }

    public func rawRequest(method: String, params: JSONValue = .object([:]), timeout: Duration? = nil) async throws -> JSONValue {
        try requireConnected()
        return try await performRequest(method: method, params: params, timeout: timeout ?? configuration.requestTimeout)
    }

    public func rawNotify(method: String, params: JSONValue? = nil) async throws {
        try requireConnected()
        try await sendEnvelope(notification: method, params: params)
    }

    private func requireConnected() throws {
        switch state {
        case .connected, .recoveryRequired: return
        case .reconnecting: throw CodexError.reconnecting
        case .closing: throw CodexError.closing
        default: throw CodexError.disconnected
        }
    }

    private func checkOperation(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard lifecycleID == operation, !intentionallyClosing else { throw CodexError.closing }
    }

    private func establishConnection(operation: UUID) async throws -> JSONValue {
        try checkOperation(operation)
        let newTransport = try await factory.makeTransport()
        do {
            try checkOperation(operation)
            try await newTransport.start()
            try checkOperation(operation)
        } catch {
            await newTransport.close()
            throw error
        }
        transport = newTransport
        let transportID = UUID(); activeTransportID = transportID
        transportInitialized = false
        generation &+= 1
        let thisGeneration = generation
        let frames = newTransport.incomingFrames
        let diagnostics = newTransport.diagnostics
        readTask = Task { [weak self] in
            do {
                for try await frame in frames {
                    guard !Task.isCancelled else { return }
                    await self?.receive(frame: frame, generation: thisGeneration)
                }
                await self?.transportEnded(id: transportID, error: CodexError.transportClosed(nil))
            } catch { await self?.transportEnded(id: transportID, error: error) }
        }
        diagnosticTasks.append(Task { [weak self] in
            for await diagnostic in diagnostics { await self?.emit(.diagnostic(.transport(diagnostic))) }
        })
        let result = try await performRequest(method: "initialize", params: [
            "clientInfo": configuration.clientInfo.json,
            "capabilities": ["experimentalApi": true, "mcpServerOpenaiFormElicitation": true],
        ], timeout: configuration.requestTimeout)
        try checkOperation(operation)
        // The server can replay requests as soon as it sees initialized, before send returns.
        transportInitialized = true
        try await sendEnvelope(notification: "initialized", params: nil)
        try checkOperation(operation)
        guard activeTransportID == transportID else { throw CodexError.disconnected }
        initializationResult = result
        return result
    }

    private func performRequest(method: String, params: JSONValue, timeout: Duration?) async throws -> JSONValue {
        guard let requestTransport = transport else { throw CodexError.disconnected }
        let requestGeneration = generation
        try Task.checkCancellation()
        requestCounter &+= 1
        let id = requestCounter
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let includesHistory = method == "thread/read" ? params["includeTurns"]?.boolValue == true : params["excludeTurns"]?.boolValue != true
                var entry = Pending(method: method, includesHistory: includesHistory, continuation: continuation, timeoutTask: nil)
                if let timeout {
                    entry.timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        await self?.timeoutRequest(id: id)
                    }
                }
                pending[id] = entry
                Task { [weak self] in
                    do {
                        guard await self?.canSendRequest(id: id, generation: requestGeneration) == true else { return }
                        let envelope: JSONValue = ["id": .number(Decimal(id)), "method": .string(method), "params": params]
                        self?.configuration.logger.log(.debug, "Sending app-server frame", metadata: ["payload": self?.configuration.logger.render(envelope) ?? ""])
                        try await requestTransport.send(frame: envelope.encoded())
                    } catch { await self?.failRequest(id: id, error: error) }
                }
            }
        }, onCancel: { [weak self] in Task { await self?.cancelLocalWait(id: id) } })
    }

    private func canSendRequest(id: Int, generation expected: UInt64) -> Bool {
        generation == expected && pending[id] != nil && transport != nil
    }

    private func timeoutRequest(id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel(); entry.continuation.resume(throwing: CodexError.requestTimedOut(method: entry.method))
    }
    private func cancelLocalWait(id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel(); entry.continuation.resume(throwing: CodexError.requestCancelled(method: entry.method))
    }
    private func failRequest(id: Int, error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel(); entry.continuation.resume(throwing: error)
    }
    private func failAllPending(with error: Error) {
        let entries = pending.values; pending.removeAll()
        for entry in entries { entry.timeoutTask?.cancel(); entry.continuation.resume(throwing: error) }
    }

    private func sendEnvelope(_ envelope: JSONValue) async throws {
        guard let transport else { throw CodexError.disconnected }
        configuration.logger.log(.debug, "Sending app-server frame", metadata: ["payload": configuration.logger.render(envelope)])
        try await transport.send(frame: envelope.encoded())
    }
    private func sendEnvelope(notification method: String, params: JSONValue?) async throws {
        var envelope: [String: JSONValue] = ["method": .string(method)]
        if let params { envelope["params"] = params }
        try await sendEnvelope(.object(envelope))
    }

    private func receive(frame: Data, generation incomingGeneration: UInt64) async {
        guard incomingGeneration == generation, activeTransportID != nil else { return }
        guard frame.count <= configuration.maximumFrameBytes else {
            emit(.diagnostic(.malformedMessage("oversized frame"))); await transport?.close(); return
        }
        let message: JSONValue
        do { message = try .decode(frame); configuration.logger.log(.debug, "Received app-server frame", metadata: ["payload": configuration.logger.render(message)]) }
        catch { emit(.diagnostic(.malformedMessage(String(decoding: frame.prefix(512), as: UTF8.self)))); return }
        if let id = message["id"]?.intValue, message["result"] != nil || message["error"] != nil {
            guard let entry = pending.removeValue(forKey: id) else { emit(.diagnostic(.unmatchedResponse(message))); return }
            entry.timeoutTask?.cancel()
            if let error = message["error"] {
                entry.continuation.resume(throwing: CodexError.rpc(code: error["code"]?.intValue ?? -32603, message: error["message"]?.stringValue ?? "Unknown error", data: error["data"]))
            } else {
                let result = message["result"] ?? .null
                // Reduce in wire order, before waking the caller or reading later notifications.
                if ["thread/read", "thread/resume", "thread/start", "thread/fork"].contains(entry.method), let raw = result["thread"] {
                    // Reducer path: diagnose and skip. The caller separately learns about the same
                    // malformed object because its own CodexThread(raw:) throws.
                    if let thread = decodeOrReport(entry.method, { try CodexThread(raw: raw) }) {
                        applyThreadSnapshot(thread, includesTurns: entry.includesHistory)
                    }
                }
                entry.continuation.resume(returning: result)
            }
            return
        }
        guard let method = message["method"]?.stringValue else { emit(.diagnostic(.malformedMessage("message has no method or response id"))); return }
        let params = message["params"] ?? .object([:])
        if let requestID = message["id"] { await routeServerRequest(id: requestID, method: method, params: params) }
        else { routeNotification(method: method, params: params) }
    }

    /// Decodes on the reducer path, where a malformed frame must be reported and dropped rather
    /// than thrown: a bad notification cannot be allowed to fail an unrelated caller's in-flight
    /// request or tear down the connection.
    private func decodeOrReport<T>(_ method: String, _ make: () throws -> T) -> T? {
        do { return try make() }
        catch CodexError.missingField(let field) { emit(malformed(method, "missing \(field)")); return nil }
        catch { emit(malformed(method, error.localizedDescription)); return nil }
    }

    private func malformed(_ method: String, _ reason: String) -> CodexEvent {
        .diagnostic(.malformedMessage("\(method): \(reason)"))
    }

    private func routeNotification(method: String, params: JSONValue) {
        let threadID = params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
        if method == "serverRequest/resolved" {
            if let id = params["requestId"] { pendingInteractionIDs.remove(id) }
            emit(.serverRequestResolved(params)); return
        }
        if method == "thread/tokenUsage/updated", let threadID {
            var snapshot = threadStates[threadID] ?? .init()
            snapshot.tokenUsage = params["tokenUsage"]
            threadStates[threadID] = snapshot
        }
        if method == "command/exec/outputDelta" {
            guard let output = decodeOrReport(method, { try CodexCommandOutput(raw: params) }) else { return }
            emit(.commandOutput(output)); return
        }
        if method == "fuzzyFileSearch/sessionUpdated" { emit(.fileSearchUpdated(params)); return }
        if method == "fuzzyFileSearch/sessionCompleted" { emit(.fileSearchCompleted(params)); return }
        if method == "item/started", let raw = params["item"] {
            guard let item = decodeOrReport(method, { try CodexItem(raw: raw, turnID: params["turnId"]?.stringValue) }) else { return }
            reduceItem(item, threadID: threadID, authoritative: false); emit(.itemStarted(threadID: threadID, item: item)); return
        }
        if method == "item/completed", let raw = params["item"] {
            guard let item = decodeOrReport(method, { try CodexItem(raw: raw, turnID: params["turnId"]?.stringValue) }) else { return }
            reduceItem(item, threadID: threadID, authoritative: true); emit(.itemCompleted(threadID: threadID, item: item)); return
        }
        if method == "turn/started", let raw = params["turn"] {
            guard let threadID else { emit(malformed(method, "missing params.threadId")); return }
            guard let turn = decodeOrReport(method, { try CodexTurn(threadID: threadID, raw: raw) }) else { return }
            reduceTurn(turn, completed: false); emit(.turnStarted(threadID: threadID, turn: turn)); return
        }
        if method == "turn/completed", let raw = params["turn"] {
            guard let threadID else { emit(malformed(method, "missing params.threadId")); return }
            guard let turn = decodeOrReport(method, { try CodexTurn(threadID: threadID, raw: raw) }) else { return }
            reduceTurn(turn, completed: true); emit(.turnCompleted(threadID: threadID, turn: turn)); return
        }
        let itemDeltaMethods: Set<String> = [
            "item/agentMessage/delta", "item/plan/delta", "item/reasoning/textDelta",
            "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
        ]
        if itemDeltaMethods.contains(method) { emit(.itemDelta(threadID: threadID, itemID: params["itemId"]?.stringValue, method: method, delta: params)); return }
        emit(.notification(method: method, params: params))
    }

    private func routeServerRequest(id: JSONValue, method: String, params: JSONValue) async {
        if let threadID = params["threadId"]?.stringValue { lostInteractionThreadIDs.remove(threadID) }
        pendingInteractionIDs.insert(id)
        if method == "item/tool/call" { runDynamicTool(id: id, params: params); return }
        let interaction = makeInteraction(id: id, method: method, params: params)
        emit(.serverRequest(interaction))
        if let interactionHandler {
            Task { [weak self] in
                if let answer = await interactionHandler(interaction) { try? await interaction.response.respond(answer) }
                await self?.handlerFinished()
            }
        }
    }
    private func handlerFinished() {}

    private func makeInteraction(id: JSONValue, method: String, params: JSONValue) -> CodexPendingInteraction {
        let kind: CodexInteractionKind
        if method.contains("commandExecution") { kind = params["networkApprovalContext"]?.objectValue == nil ? .commandApproval : .networkApproval }
        else if method.contains("fileChange") { kind = .fileChangeApproval }
        else if method.contains("permissions") { kind = .permissionApproval }
        else if method.contains("requestUserInput") { kind = .userInput }
        else if method == "mcpServer/elicitation/request" {
            switch params["mode"]?.stringValue { case "url": kind = .urlElicitation; case "form": kind = .mcpForm; default: kind = .openAIForm }
        } else { kind = .unknown(method) }
        let rawChoices = params["availableDecisions"]?.arrayValue ?? params["decisionChoices"]?.arrayValue ?? params["options"]?.arrayValue ?? []
        let choices = rawChoices.enumerated().map { index, raw in CodexDecisionChoice(id: raw.stringValue ?? raw["id"]?.stringValue ?? raw["value"]?.stringValue ?? "\(index)", label: raw.stringValue ?? raw["label"]?.stringValue ?? raw["name"]?.stringValue ?? "\(index)", raw: raw) }
        let questions = (params["questions"]?.arrayValue ?? []).enumerated().map { index, raw -> CodexUserQuestion in
            let options = (raw["options"]?.arrayValue ?? []).enumerated().map { choiceIndex, choice in CodexDecisionChoice(id: choice["id"]?.stringValue ?? choice["label"]?.stringValue ?? "\(choiceIndex)", label: choice["label"]?.stringValue ?? "\(choiceIndex)", raw: choice) }
            return CodexUserQuestion(id: raw["id"]?.stringValue ?? "\(index)", header: raw["header"]?.stringValue, question: raw["question"]?.stringValue ?? "", choices: options, raw: raw)
        }
        let requestKey = id.stringValue ?? String(id.intValue ?? 0)
        return CodexPendingInteraction(id: requestKey, requestID: id, method: method, kind: kind, generation: generation, threadID: params["threadId"]?.stringValue, turnID: params["turnId"]?.stringValue, itemID: params["itemId"]?.stringValue, choices: choices, questions: questions, raw: params, response: .init(client: self, requestID: id, generation: generation))
    }

    private func runDynamicTool(id: JSONValue, params: JSONValue) {
        let token = UUID(), name = params["tool"]?.stringValue ?? params["name"]?.stringValue ?? "", callID = params["callId"]?.stringValue, toolGeneration = generation
        emit(.dynamicToolStarted(name: name, callID: callID))
        dynamicToolTasks[token] = Task { [weak self] in
            guard let self else { return }
            let result: CodexDynamicToolResult
            do {
                guard let tool = await dynamicTools.tool(named: name) else { throw CodexError.missingDynamicTool(name) }
                result = try await tool.handler(params["arguments"] ?? .object([:]))
            } catch { result = .text(error.localizedDescription, success: false) }
            try? await self.respondToServerRequest(id: id, response: .result(result.json), generation: toolGeneration)
            await self.dynamicToolFinished(token: token, name: name, callID: callID, success: result.success)
        }
    }
    private func dynamicToolFinished(token: UUID, name: String, callID: String?, success: Bool) { dynamicToolTasks[token] = nil; emit(.dynamicToolCompleted(name: name, callID: callID, success: success)) }

    public func respondToServerRequest(id: JSONValue, response: CodexInteractionResponse, generation expectedGeneration: UInt64) async throws {
        guard expectedGeneration == generation else { throw CodexError.staleResponseHandle }
        guard pendingInteractionIDs.contains(id) else { throw CodexError.staleResponseHandle }
        guard transportInitialized, transport != nil, !intentionallyClosing else { throw CodexError.disconnected }
        // A send error is ambiguous: reserve permanently rather than risk replying twice.
        pendingInteractionIDs.remove(id)
        switch response {
        case .error(let code, let message, let data):
            var error: [String: JSONValue] = ["code": .number(Decimal(code)), "message": .string(message)]
            if let data { error["data"] = data }
            try await sendEnvelope(["id": id, "error": .object(error)])
        default: try await sendEnvelope(["id": id, "result": response.json])
        }
    }

    private func reduceItem(_ item: CodexItem, threadID: String?, authoritative: Bool) {
        guard let threadID else { return }
        var state = threadStates[threadID] ?? .init()
        if state.items[item.id] == nil { state.itemOrder.append(item.id) }
        if authoritative || state.items[item.id] == nil { state.items[item.id] = item }
        threadStates[threadID] = state
    }
    func reduceTurn(_ turn: CodexTurn, completed: Bool) {
        var state = threadStates[turn.threadID] ?? .init()
        if state.turns[turn.id] == nil { state.turnOrder.append(turn.id) }
        state.turns[turn.id] = turn
        if completed { state.activeTurnIDs.remove(turn.id) } else { state.activeTurnIDs.insert(turn.id) }
        threadStates[turn.threadID] = state
    }

    func applyThreadSnapshot(_ thread: CodexThread, includesTurns: Bool) {
        var snapshot = threadStates[thread.id] ?? .init()
        snapshot.thread = thread
        // Replay can cover hundreds of elements, so malformed ones are counted and reported once
        // rather than emitted individually into a bounded subscriber queue.
        var skipped = 0
        if includesTurns, let history = thread.raw["turns"]?.arrayValue {
            snapshot.turns = [:]; snapshot.items = [:]; snapshot.activeTurnIDs = []
            snapshot.turnOrder = []; snapshot.itemOrder = []
            for rawTurn in history {
                guard let turn = try? CodexTurn(threadID: thread.id, raw: rawTurn) else { skipped += 1; continue }
                if snapshot.turns[turn.id] == nil { snapshot.turnOrder.append(turn.id) }
                snapshot.turns[turn.id] = turn
                if turn.status == "inProgress" { snapshot.activeTurnIDs.insert(turn.id) }
                for rawItem in rawTurn["items"]?.arrayValue ?? [] {
                    guard let item = try? CodexItem(raw: rawItem, turnID: turn.id) else { skipped += 1; continue }
                    if snapshot.items[item.id] == nil { snapshot.itemOrder.append(item.id) }
                    snapshot.items[item.id] = item
                }
            }
        }
        threadStates[thread.id] = snapshot
        // Report the caveat before the snapshot it qualifies.
        if skipped > 0 { emit(malformed("thread/history", "skipped \(skipped) malformed turns/items")) }
        emit(.threadStateUpdated(threadID: thread.id, state: snapshot))
    }

    func emit(_ event: CodexEvent) {
        for (id, subscriber) in subscribers where subscriber.threadID == nil || subscriber.threadID == event.threadID {
            if !subscriber.buffer.yield(event) { removeSubscriber(id) }
        }
    }
    private func setState(_ newState: CodexConnectionState) { state = newState; emit(.connection(newState)) }
    private func invalidateInteractions() { pendingInteractionIDs.removeAll(); for task in dynamicToolTasks.values { task.cancel() }; dynamicToolTasks.removeAll() }

    private func transportEnded(id: UUID, error: Error) async {
        guard activeTransportID == id, !intentionallyClosing else { return }
        let wasReady: Bool
        switch state { case .connected, .recoveryRequired: wasReady = true; default: wasReady = false }
        let operation = lifecycleID
        if !pendingInteractionIDs.isEmpty { lostInteractionThreadIDs.formUnion(subscriptionIntents) }
        failAllPending(with: error); invalidateInteractions()
        if wasReady { setState(.reconnecting(attempt: 1, maximumAttempts: configuration.reconnectPolicy.maximumAttempts)) }
        await tearDownTransport()
        if wasReady, lifecycleID == operation, !intentionallyClosing { startAutomaticReconnect() }
    }
    private func startAutomaticReconnect() {
        guard reconnectTask == nil else { return }
        let operation = UUID(); lifecycleID = operation
        reconnectTask = Task { [weak self] in await self?.automaticReconnectLoop(operation: operation) }
    }
    private func automaticReconnectLoop(operation: UUID) async {
        guard lifecycleID == operation, !Task.isCancelled, !intentionallyClosing else { return }
        let policy = configuration.reconnectPolicy
        guard policy.maximumAttempts > 0 else { reconnectTask = nil; setState(.failed("Automatic reconnect is disabled; call reconnect().")); return }
        var delay = policy.initialDelay
        for attempt in 1...max(0, policy.maximumAttempts) {
            guard lifecycleID == operation, !Task.isCancelled, !intentionallyClosing else { return }
            setState(.reconnecting(attempt: attempt, maximumAttempts: policy.maximumAttempts))
            var sleepFor = delay
            if policy.jitter { sleepFor += .milliseconds(Int.random(in: 0...250)) }
            do {
                try await Task.sleep(for: sleepFor)
                try checkOperation(operation)
                _ = try await establishConnection(operation: operation)
                let recovery = try await restoreSubscriptionIntents(operation: operation)
                try checkOperation(operation)
                reconnectTask = nil; setState(recovery.map(CodexConnectionState.recoveryRequired) ?? .connected(generation: generation)); return
            } catch {
                guard lifecycleID == operation, !Task.isCancelled, !intentionallyClosing else { return }
                emit(.diagnostic(.reconnectFailed(attempt: attempt, message: error.localizedDescription)))
                failAllPending(with: error)
                await tearDownTransport()
                guard lifecycleID == operation else { return }
                delay = min(delay * 2, policy.maximumDelay)
            }
        }
        reconnectTask = nil; setState(.failed("Automatic reconnect attempts exhausted; call reconnect()."))
    }
    private func restoreSubscriptionIntents(operation: UUID) async throws -> CodexRecoveryContext? {
        var recoveryThreadIDs: Set<String> = []
        for threadID in subscriptionIntents {
            try checkOperation(operation)
            _ = try await performRequest(method: "thread/resume", params: ["threadId": .string(threadID), "excludeTurns": true], timeout: configuration.requestTimeout)
            try checkOperation(operation)
            let result = try await performRequest(method: "thread/read", params: ["threadId": .string(threadID), "includeTurns": true], timeout: configuration.requestTimeout)
            try checkOperation(operation)
            let flags = result["thread"]?["status"]?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if lostInteractionThreadIDs.contains(threadID), (flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")) { recoveryThreadIDs.insert(threadID) }
            else { lostInteractionThreadIDs.remove(threadID) }
        }
        guard !recoveryThreadIDs.isEmpty else { return nil }
        let context = CodexRecoveryContext(threadIDs: recoveryThreadIDs, reason: "The resumed task is waiting for an interaction that the server did not replay.")
        lostInteractionThreadIDs.subtract(recoveryThreadIDs); return context
    }
    private func tearDownTransport() async {
        activeTransportID = nil
        transportInitialized = false
        readTask?.cancel(); readTask = nil
        for task in diagnosticTasks { task.cancel() }; diagnosticTasks.removeAll()
        let old = transport; transport = nil
        if let old {
            let id = UUID()
            transportCloseTasks[id] = Task { await old.close() }
        }
        // close() must also join cleanup already started by the reader's error path.
        for (id, task) in transportCloseTasks {
            await task.value
            transportCloseTasks[id] = nil
        }
    }
}
