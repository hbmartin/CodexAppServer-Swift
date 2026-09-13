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
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }
    private struct Subscriber {
        let threadID: String?
        let policy: CodexBufferingPolicy
        let continuation: AsyncThrowingStream<CodexEvent, Error>.Continuation
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
    private var state: CodexConnectionState = .disconnected
    private var intentionallyClosing = false
    var threadStates: [String: CodexThreadState] = [:]
    var subscriptionIntents: Set<String> = []
    private var pendingInteractionIDs: Set<String> = []
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
        case .connecting, .connected, .reconnecting: throw CodexError.alreadyConnected
        case .closing: throw CodexError.closing
        default: break
        }
        intentionallyClosing = false
        setState(.connecting)
        do {
            let result = try await establishConnection()
            setState(.connected(generation: generation))
            return result
        } catch {
            await tearDownTransport()
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    @discardableResult
    public func reconnect() async throws -> JSONValue {
        reconnectTask?.cancel(); reconnectTask = nil
        intentionallyClosing = false
        failAllPending(with: CodexError.transportClosed("manual reconnect"))
        await tearDownTransport()
        setState(.connecting)
        do {
            let result = try await establishConnection()
            let recovery = try await restoreSubscriptionIntents()
            setState(recovery.map(CodexConnectionState.recoveryRequired) ?? .connected(generation: generation))
            return result
        } catch {
            setState(.failed(error.localizedDescription)); throw error
        }
    }

    public func close() async {
        intentionallyClosing = true
        reconnectTask?.cancel(); reconnectTask = nil
        setState(.closing)
        failAllPending(with: CodexError.closing)
        invalidateInteractions()
        await tearDownTransport()
        setState(.disconnected)
    }

    public func subscribe(policy: CodexBufferingPolicy = .default) -> CodexSubscription { makeSubscription(threadID: nil, policy: policy) }
    public func events(for threadID: String, policy: CodexBufferingPolicy = .default) -> CodexSubscription { makeSubscription(threadID: threadID, policy: policy) }

    private func makeSubscription(threadID: String?, policy: CodexBufferingPolicy) -> CodexSubscription {
        let id = UUID()
        let buffering: AsyncThrowingStream<CodexEvent, Error>.Continuation.BufferingPolicy
        switch policy {
        case .boundedFailing(let count), .boundedCoalescingDeltas(let count): buffering = .bufferingNewest(max(1, count))
        case .unbounded: buffering = .unbounded
        }
        let pair = AsyncThrowingStream<CodexEvent, Error>.makeStream(bufferingPolicy: buffering)
        subscribers[id] = Subscriber(threadID: threadID, policy: policy, continuation: pair.continuation)
        if let threadID {
            subscriptionIntents.insert(threadID)
            if subscriptionIntents.count == 9 { emit(.diagnostic(.highThreadSubscriptionCount(subscriptionIntents.count))) }
        }
        let client = self
        pair.continuation.onTermination = { _ in Task { await client.removeSubscriber(id) } }
        return CodexSubscription(id: id, events: pair.stream) { Task { await client.removeSubscriber(id) } }
    }

    private func removeSubscriber(_ id: UUID) {
        guard let removed = subscribers.removeValue(forKey: id) else { return }
        if let threadID = removed.threadID, !subscribers.values.contains(where: { $0.threadID == threadID }) { subscriptionIntents.remove(threadID) }
        removed.continuation.finish()
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
        case .connected: return
        case .reconnecting: throw CodexError.reconnecting
        case .closing: throw CodexError.closing
        default: throw CodexError.disconnected
        }
    }

    private func establishConnection() async throws -> JSONValue {
        let newTransport = try await factory.makeTransport()
        try await newTransport.start()
        transport = newTransport
        generation &+= 1
        let thisGeneration = generation
        let frames = newTransport.incomingFrames
        let diagnostics = newTransport.diagnostics
        readTask = Task { [weak self] in
            do {
                for try await frame in frames { await self?.receive(frame: frame, generation: thisGeneration) }
                await self?.transportEnded(generation: thisGeneration, error: CodexError.transportClosed(nil))
            } catch { await self?.transportEnded(generation: thisGeneration, error: error) }
        }
        diagnosticTasks.append(Task { [weak self] in
            for await diagnostic in diagnostics { await self?.emit(.diagnostic(.transport(diagnostic))) }
        })
        let result = try await performRequest(method: "initialize", params: [
            "clientInfo": configuration.clientInfo.json,
            "capabilities": ["experimentalApi": true, "mcpServerOpenaiFormElicitation": true],
        ], timeout: configuration.requestTimeout)
        try await sendEnvelope(notification: "initialized", params: nil)
        initializationResult = result
        return result
    }

    private func performRequest(method: String, params: JSONValue, timeout: Duration?) async throws -> JSONValue {
        guard transport != nil else { throw CodexError.disconnected }
        try Task.checkCancellation()
        requestCounter &+= 1
        let id = requestCounter
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var entry = Pending(method: method, continuation: continuation, timeoutTask: nil)
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
                        try await self?.sendEnvelope(["id": .number(Decimal(id)), "method": .string(method), "params": params])
                    } catch { await self?.failRequest(id: id, error: error) }
                }
            }
        }, onCancel: { [weak self] in Task { await self?.cancelLocalWait(id: id) } })
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
        guard incomingGeneration == generation else { return }
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
            } else { entry.continuation.resume(returning: message["result"] ?? .null) }
            return
        }
        guard let method = message["method"]?.stringValue else { emit(.diagnostic(.malformedMessage("message has no method or response id"))); return }
        let params = message["params"] ?? .object([:])
        if let requestID = message["id"] { await routeServerRequest(id: requestID, method: method, params: params) }
        else { routeNotification(method: method, params: params) }
    }

    private func routeNotification(method: String, params: JSONValue) {
        let threadID = params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue
        if method == "serverRequest/resolved" { pendingInteractionIDs.remove(params["requestId"]?.stringValue ?? ""); emit(.serverRequestResolved(params)); return }
        if method == "command/exec/outputDelta" { emit(.commandOutput(.init(raw: params))); return }
        if method == "fuzzyFileSearch/sessionUpdated" { emit(.fileSearchUpdated(params)); return }
        if method == "fuzzyFileSearch/sessionCompleted" { emit(.fileSearchCompleted(params)); return }
        if method == "item/started", let raw = params["item"] {
            let item = CodexItem(raw: raw); reduceItem(item, threadID: threadID, authoritative: false); emit(.itemStarted(threadID: threadID, item: item)); return
        }
        if method == "item/completed", let raw = params["item"] {
            let item = CodexItem(raw: raw); reduceItem(item, threadID: threadID, authoritative: true); emit(.itemCompleted(threadID: threadID, item: item)); return
        }
        if method == "turn/started", let raw = params["turn"] {
            let turn = CodexTurn(threadID: threadID ?? "", raw: raw); reduceTurn(turn, completed: false); emit(.turnStarted(threadID: threadID, turn: turn)); return
        }
        if method == "turn/completed", let raw = params["turn"] {
            let turn = CodexTurn(threadID: threadID ?? "", raw: raw); reduceTurn(turn, completed: true); emit(.turnCompleted(threadID: threadID, turn: turn)); return
        }
        if method.contains("/delta") { emit(.itemDelta(threadID: threadID, itemID: params["itemId"]?.stringValue, method: method, delta: params)); return }
        emit(.notification(method: method, params: params))
    }

    private func routeServerRequest(id: JSONValue, method: String, params: JSONValue) async {
        if let threadID = params["threadId"]?.stringValue { lostInteractionThreadIDs.remove(threadID) }
        pendingInteractionIDs.insert(id.stringValue ?? String(id.intValue ?? 0))
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
        if method.contains("commandExecution") { kind = params["networkApprovalContext"] == nil ? .commandApproval : .networkApproval }
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
        let requestKey = id.stringValue ?? String(id.intValue ?? 0)
        guard pendingInteractionIDs.contains(requestKey) else { throw CodexError.staleResponseHandle }
        try requireConnected()
        switch response {
        case .error(let code, let message, let data):
            var error: [String: JSONValue] = ["code": .number(Decimal(code)), "message": .string(message)]
            if let data { error["data"] = data }
            try await sendEnvelope(["id": id, "error": .object(error)])
        default: try await sendEnvelope(["id": id, "result": response.json])
        }
        pendingInteractionIDs.remove(requestKey)
    }

    private func reduceItem(_ item: CodexItem, threadID: String?, authoritative: Bool) {
        guard let threadID, !item.id.isEmpty else { return }
        var state = threadStates[threadID] ?? .init()
        if authoritative || state.items[item.id] == nil { state.items[item.id] = item }
        threadStates[threadID] = state
    }
    func reduceTurn(_ turn: CodexTurn, completed: Bool) {
        guard !turn.threadID.isEmpty, !turn.id.isEmpty else { return }
        var state = threadStates[turn.threadID] ?? .init(); state.turns[turn.id] = turn
        if completed { state.activeTurnIDs.remove(turn.id) } else { state.activeTurnIDs.insert(turn.id) }
        threadStates[turn.threadID] = state
    }

    func emit(_ event: CodexEvent) {
        for (id, subscriber) in subscribers where subscriber.threadID == nil || subscriber.threadID == event.threadID {
            let result = subscriber.continuation.yield(event)
            if case .dropped(let dropped) = result {
                switch subscriber.policy {
                case .boundedCoalescingDeltas where dropped.isDelta: break
                case .unbounded: break
                default: subscriber.continuation.finish(throwing: CodexError.transportClosed("subscriber buffer overflow")); subscribers[id] = nil
                }
            }
        }
    }
    private func setState(_ newState: CodexConnectionState) { state = newState; emit(.connection(newState)) }
    private func invalidateInteractions() { pendingInteractionIDs.removeAll(); for task in dynamicToolTasks.values { task.cancel() }; dynamicToolTasks.removeAll() }

    private func transportEnded(generation endedGeneration: UInt64, error: Error) async {
        guard endedGeneration == generation, !intentionallyClosing else { return }
        if !pendingInteractionIDs.isEmpty { lostInteractionThreadIDs.formUnion(subscriptionIntents) }
        failAllPending(with: error); invalidateInteractions(); await tearDownTransport()
        startAutomaticReconnect()
    }
    private func startAutomaticReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.automaticReconnectLoop() }
    }
    private func automaticReconnectLoop() async {
        let policy = configuration.reconnectPolicy
        guard policy.maximumAttempts > 0 else { reconnectTask = nil; setState(.failed("Automatic reconnect is disabled; call reconnect().")); return }
        var delay = policy.initialDelay
        for attempt in 1...max(0, policy.maximumAttempts) {
            guard !Task.isCancelled, !intentionallyClosing else { return }
            setState(.reconnecting(attempt: attempt, maximumAttempts: policy.maximumAttempts))
            var sleepFor = delay
            if policy.jitter { sleepFor += .milliseconds(Int.random(in: 0...250)) }
            try? await Task.sleep(for: sleepFor)
            do {
                _ = try await establishConnection(); let recovery = try await restoreSubscriptionIntents()
                reconnectTask = nil; setState(recovery.map(CodexConnectionState.recoveryRequired) ?? .connected(generation: generation)); return
            } catch {
                emit(.diagnostic(.reconnectFailed(attempt: attempt, message: error.localizedDescription)))
                await tearDownTransport(); delay = min(delay * 2, policy.maximumDelay)
            }
        }
        reconnectTask = nil; setState(.failed("Automatic reconnect attempts exhausted; call reconnect()."))
    }
    private func restoreSubscriptionIntents() async throws -> CodexRecoveryContext? {
        var recoveryThreadIDs: Set<String> = []
        for threadID in subscriptionIntents {
            _ = try await performRequest(method: "thread/resume", params: ["threadId": .string(threadID), "excludeTurns": true], timeout: configuration.requestTimeout)
            let result = try await performRequest(method: "thread/read", params: ["threadId": .string(threadID), "includeTurns": true], timeout: configuration.requestTimeout)
            if let raw = result["thread"] { var item = threadStates[threadID] ?? .init(); item.thread = .init(raw: raw); threadStates[threadID] = item }
            let flags = result["thread"]?["status"]?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if lostInteractionThreadIDs.contains(threadID), (flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")) { recoveryThreadIDs.insert(threadID) }
            else { lostInteractionThreadIDs.remove(threadID) }
        }
        guard !recoveryThreadIDs.isEmpty else { return nil }
        let context = CodexRecoveryContext(threadIDs: recoveryThreadIDs, reason: "The resumed task is waiting for an interaction that the server did not replay.")
        lostInteractionThreadIDs.subtract(recoveryThreadIDs); return context
    }
    private func tearDownTransport() async {
        readTask?.cancel(); readTask = nil
        for task in diagnosticTasks { task.cancel() }; diagnosticTasks.removeAll()
        let old = transport; transport = nil; await old?.close()
    }
}
