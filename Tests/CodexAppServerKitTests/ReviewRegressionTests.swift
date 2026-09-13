import Foundation
import Testing
@testable import CodexAppServerKit

private actor ReviewTransport: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    let frames: AsyncThrowingStream<Data, Error>.Continuation
    let diagnostic: AsyncStream<CodexTransportDiagnostic>.Continuation
    var sent: [JSONValue] = []
    var closed = false
    var results: [String: JSONValue]
    var delayResponses: Bool
    var replayOnResume: Bool
    var startGate: ReviewFactoryGate?
    var rejectResponses = false
    var replayOnInitialized = false
    init(results: [String: JSONValue] = [:], delayResponses: Bool = false, replayOnResume: Bool = false) {
        self.replayOnResume = replayOnResume
        self.results = results; self.delayResponses = delayResponses
        let f = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = f.stream; frames = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream(); diagnostics = d.stream; diagnostic = d.continuation
    }
    func start() async { await startGate?.wait() }
    func holdStart(at gate: ReviewFactoryGate) { startGate = gate }
    func failResponses() { rejectResponses = true }
    func replayWhenInitialized() { replayOnInitialized = true }
    func send(frame: Data) async throws {
        let message = try JSONValue.decode(frame); sent.append(message)
        if message["method"]?.stringValue == "initialized", replayOnInitialized {
            try inject(["id": 56, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
            try await Task.sleep(for: .milliseconds(50))
        }
        if message["result"] != nil, rejectResponses { throw CodexError.transportClosed("ambiguous send failure") }
        if message["result"] != nil, delayResponses { try await Task.sleep(for: .milliseconds(50)) }
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        if method == "thread/resume", replayOnResume {
            try inject(["id": 55, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
            try await Task.sleep(for: .milliseconds(100))
        }
        try inject(["id": id, "result": results[method] ?? .object([:])])
    }
    func inject(_ value: JSONValue) throws { frames.yield(try value.encoded()) }
    func close() { closed = true; frames.finish(); diagnostic.finish() }
    func messages() -> [JSONValue] { sent }
}

private func reviewClient(_ transport: ReviewTransport) async throws -> CodexClient {
    let client = CodexClient(transportFactory: .init { transport }, configuration: .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 0)))
    _ = try await client.connect(); return client
}

@Test func reviewCommandOutputDecodesProtocolBytes() {
    let output = CodexCommandOutput(raw: ["processId": "p", "stream": "stdout", "deltaBase64": "aGVsbG8=", "capReached": false])
    #expect(String(decoding: output.data, as: UTF8.self) == "hello")
}

@Test func reviewHistoryUnwrapsItemEntries() async throws {
    let transport = ReviewTransport(results: ["thread/items/list": ["data": [["turnId": "u", "item": ["id": "i", "type": "agentMessage", "text": "hello"]]]]])
    let client = try await reviewClient(transport)
    let page = try await client.listItems(threadID: "t")
    #expect(page.items.first?.id == "i")
    #expect(page.items.first?.kind == .agentMessage)
    #expect(page.items.first?.turnID == "u")
    await client.close()
}

@Test func reviewSteerReturnsServerTurnID() async throws {
    let transport = ReviewTransport(results: ["turn/steer": ["turnId": "u"]])
    let client = try await reviewClient(transport)
    let turn = try await client.steerTurn(threadID: "t", expectedTurnID: "u", inputs: [.text("more")])
    #expect(turn.id == "u")
    await client.close()
}

@Test func reviewReviewTargetsUseRequiredSchemaKeys() {
    #expect(CodexReviewTarget(.commit("abc")).json["sha"]?.stringValue == "abc")
    #expect(CodexReviewTarget(.custom("inspect this")).json["instructions"]?.stringValue == "inspect this")
}

@Test func reviewDiscoveryUnwrapsSkillsAndPreservesProfileIDs() async throws {
    let transport = ReviewTransport(results: ["skills/list": ["data": [["cwd": "/work", "skills": [["name": "example", "path": "/work/SKILL.md"]], "errors": []]]], "permissionProfile/list": ["data": [["id": "read-only", "allowed": true]]]])
    let client = try await reviewClient(transport)
    #expect(try await client.listSkills().first?.id == "example")
    #expect(try await client.listPermissionProfiles().first?.id == "read-only")
    await client.close()
}

@Test func reviewResponseIsOneShotUnderConcurrentCallers() async throws {
    let transport = ReviewTransport(delayResponses: true), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
    var iterator = subscription.events.makeAsyncIterator()
    guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("request missing"); return }
    async let first: Void? = try? interaction.response.respond(.answers([:]))
    async let second: Void? = try? interaction.response.respond(.answers([:]))
    _ = await (first, second)
    #expect(await transport.messages().filter { $0["id"]?.intValue == 44 && $0["result"] != nil }.count == 1)
    await client.close()
}

@Test func reviewResolvedNumericIDInvalidatesHandle() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
    var iterator = subscription.events.makeAsyncIterator()
    guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("request missing"); return }
    try await transport.inject(["method": "serverRequest/resolved", "params": ["threadId": "t", "requestId": 44]])
    _ = try await iterator.next()
    do { try await interaction.response.respond(.answers([:])); Issue.record("Resolved numeric request was still answerable") }
    catch { #expect(error as? CodexError == .staleResponseHandle) }
    await client.close()
}

private actor ReviewFactoryGate {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Test func reviewClosePreventsInflightConnectFromReopening() async throws {
    let gate = ReviewFactoryGate(), transport = ReviewTransport()
    let client = CodexClient(transportFactory: .init { await gate.wait(); return transport }, configuration: .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 0)))
    let connection = Task { try? await client.connect() }
    while !(await gate.waiting) { await Task.yield() }
    await client.close()
    await gate.release()
    _ = await connection.value
    #expect(await client.connectionState() == .disconnected)
    #expect(await transport.closed)
    await client.close()
}

@Test func reviewHistoryHydratesStateAndClearsStaleActiveTurns() async throws {
    let transport = ReviewTransport(results: ["thread/read": ["thread": ["id": "t", "status": ["type": "idle"], "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"]]]]]]])
    let client = try await reviewClient(transport)
    await client.reduceTurn(.init(threadID: "t", raw: ["id": "u", "status": "inProgress"]), completed: false)
    _ = try await client.readThread(id: "t", includeTurns: true)
    #expect(await client.turnStatus(threadID: "t", turnID: "u") == "completed")
    #expect(await client.state(for: "t")?.activeTurnIDs.isEmpty == true)
    #expect(await client.state(for: "t")?.items["i"]?.turnID == "u")
    await client.close()
}

@Test func reviewDeltaCoalescingPreservesAppendedText() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1))
    await client.emit(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "hello "]))
    await client.emit(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "world"]))
    var iterator = subscription.events.makeAsyncIterator()
    if case .itemDelta(_, _, _, let raw) = try await iterator.next() { #expect(raw["delta"]?.stringValue == "hello world") }
    else { Issue.record("Missing coalesced delta") }
    await client.close()
}

@Test func reviewCommandAndReasoningDeltasRouteAsTypedEvents() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": "item/reasoning/textDelta", "params": ["threadId": "t", "turnId": "u", "itemId": "i", "delta": "reasoning", "contentIndex": 0]])
    var iterator = subscription.events.makeAsyncIterator()
    if case .itemDelta = try await iterator.next() {} else { Issue.record("Reasoning delta routed as generic notification") }
    await client.close()
}

@Test func reviewUsageUpdatesAreAvailableThroughTypedAccessor() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": "thread/tokenUsage/updated", "params": ["threadId": "t", "turnId": "u", "tokenUsage": ["total": ["totalTokens": 123]]]])
    var iterator = subscription.events.makeAsyncIterator(); _ = try await iterator.next()
    #expect(await client.turnUsage(threadID: "t") != nil)
    await client.close()
}

@Test func reviewNullNetworkContextIsCommandApproval() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/commandExecution/requestApproval", "params": ["threadId": "t", "networkApprovalContext": .null]])
    var iterator = subscription.events.makeAsyncIterator()
    if case .serverRequest(let interaction) = try await iterator.next() { #expect(interaction.kind == .commandApproval) }
    else { Issue.record("request missing") }
    await client.close()
}

private actor ReviewTransportSequence {
    var transports: [ReviewTransport]
    init(_ transports: [ReviewTransport]) { self.transports = transports }
    func next() throws -> ReviewTransport {
        guard !transports.isEmpty else { throw CodexError.transportClosed("exhausted") }
        return transports.removeFirst()
    }
}

@Test func reviewReplayedInteractionHandlerCanRespondDuringRecovery() async throws {
    let history: JSONValue = ["thread": ["id": "t", "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]], "turns": []]]
    let first = ReviewTransport(results: ["thread/resume": history, "thread/read": history])
    let second = ReviewTransport(results: ["thread/resume": history, "thread/read": history], replayOnResume: true)
    let sequence = ReviewTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero, jitter: false)))
    _ = try await client.connect(); _ = try await client.subscribeThread(id: "t")
    await client.setInteractionHandler { _ in .answers([:]) }
    await first.close()
    for _ in 0..<1000 {
        if await client.connectionState() == .connected(generation: 2) { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await client.connectionState() == .connected(generation: 2))
    #expect(await second.messages().contains { $0["id"]?.intValue == 55 && $0["result"] != nil })
    await client.close()
}

@Test func reviewFullLoggerStillRedactsAPIKeys() {
    let logger = CodexLogger(payloadMode: .full)
    let rendered = logger.render(["method": "account/login/start", "params": ["type": "apiKey", "apiKey": "sk-review-test-only"]])
    #expect(!rendered.contains("sk-review-test-only"))
}

@Test func closeDuringTransportStartClosesLateTransport() async throws {
    let gate = ReviewFactoryGate(), transport = ReviewTransport()
    await transport.holdStart(at: gate)
    let client = CodexClient(transportFactory: .init { transport })
    let connection = Task { try? await client.connect() }
    while !(await gate.waiting) { await Task.yield() }
    await client.close(); await gate.release(); _ = await connection.value
    #expect(await client.connectionState() == .disconnected)
    #expect(await transport.closed)
}

@Test func closeCancelsReconnectBackoffBeforeCreatingTransport() async throws {
    let first = ReviewTransport(), second = ReviewTransport()
    let sequence = ReviewTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: .init(reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .seconds(10), jitter: false)))
    _ = try await client.connect()
    let events = await client.subscribe(policy: .unbounded)
    await first.close()
    for try await event in events.events {
        if case .connection(.reconnecting) = event { break }
    }
    await client.close()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await sequence.transports.count == 1)
    #expect(await client.connectionState() == .disconnected)
}

@Test func supersededConnectCannotTearDownNewConnection() async throws {
    let gate = ReviewFactoryGate(), first = ReviewTransport(), second = ReviewTransport()
    await first.holdStart(at: gate)
    let sequence = ReviewTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() })
    let initial = Task { try? await client.connect() }
    while !(await gate.waiting) { await Task.yield() }
    _ = try await client.reconnect()
    await gate.release(); _ = await initial.value
    #expect(await client.connectionState() == .connected(generation: 1))
    #expect(await first.closed)
    #expect(!(await second.closed))
    await client.close()
}

@Test func directResponsesAreReservedBeforeTransportSend() async throws {
    let transport = ReviewTransport(delayResponses: true), client = try await reviewClient(transport)
    let events = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
    var iterator = events.events.makeAsyncIterator(); _ = try await iterator.next()
    let generation = await client.currentGeneration()
    async let first: Void? = try? client.respondToServerRequest(id: 44, response: .answers([:]), generation: generation)
    async let second: Void? = try? client.respondToServerRequest(id: 44, response: .answers([:]), generation: generation)
    _ = await (first, second)
    #expect(await transport.messages().filter { $0["id"] == 44 && $0["result"] != nil }.count == 1)
    await client.close()
}

@Test func ambiguousResponseFailureCannotBeRetried() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    await transport.failResponses()
    let events = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
    var iterator = events.events.makeAsyncIterator()
    guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("missing request"); return }
    _ = try? await interaction.response.respond(.answers([:]))
    do { try await interaction.response.respond(.answers([:])); Issue.record("retried ambiguous response") }
    catch { #expect(error as? CodexError == .responseAlreadySent) }
    #expect(await transport.messages().filter { $0["id"] == 44 && $0["result"] != nil }.count == 1)
    await client.close()
}

@Test(arguments: ["differentItem", "differentSegment", "lifecycle", "oversized"])
func coalescingFailsInsteadOfLosingIncompatibleEvents(scenario: String) async throws {
    let buffer = CodexEventBuffer(policy: .boundedCoalescingDeltas(1), maximumCoalescedBytes: 5, onTermination: {})
    let first: CodexEvent = .itemDelta(threadID: "t", itemID: "i", method: "item/reasoning/textDelta", delta: ["delta": "abc", "contentIndex": 0])
    let next: CodexEvent
    switch scenario {
    case "differentItem": next = .itemDelta(threadID: "t", itemID: "j", method: "item/reasoning/textDelta", delta: ["delta": "d", "contentIndex": 0])
    case "differentSegment": next = .itemDelta(threadID: "t", itemID: "i", method: "item/reasoning/textDelta", delta: ["delta": "d", "contentIndex": 1])
    case "lifecycle": next = .itemCompleted(threadID: "t", item: .init(raw: ["id": "i", "type": "reasoning"]))
    default: next = .itemDelta(threadID: "t", itemID: "i", method: "item/reasoning/textDelta", delta: ["delta": "def", "contentIndex": 0])
    }
    #expect(buffer.yield(first))
    #expect(!buffer.yield(next))
    #expect(try await buffer.next() == first)
    do { _ = try await buffer.next(); Issue.record("overflow was hidden") }
    catch { #expect(error as? CodexSubscriptionError == .bufferOverflow) }
}

@Test func cancellingIdleEventIteratorFinishesIt() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1))
    let reader = Task {
        var iterator = subscription.events.makeAsyncIterator()
        return try await iterator.next()
    }
    reader.cancel()
    // AsyncThrowingStream may terminate with nil before calling the unfolding closure.
    do { #expect(try await reader.value == nil) }
    catch { #expect(error is CancellationError) }
    await client.close()
}

@Test func replayBeforeInitializedSendReturnsCanBeAnswered() async throws {
    let transport = ReviewTransport()
    await transport.replayWhenInitialized()
    let client = CodexClient(transportFactory: .init { transport }, configuration: .init(requestTimeout: .seconds(2)))
    await client.setInteractionHandler { _ in .answers([:]) }
    _ = try await client.connect()
    #expect(await transport.messages().contains { $0["id"] == 56 && $0["result"] != nil })
    await client.close()
}

@Test func reviewItemLifecycleRetainsOwningTurn() async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let subscription = await client.events(for: "t", policy: .unbounded)
    var iterator = subscription.events.makeAsyncIterator()
    for method in ["item/started", "item/completed"] {
        try await transport.inject(["method": .string(method), "params": ["threadId": "t", "turnId": "u", "item": ["id": "i", "type": "agentMessage"]]])
        let event = try await iterator.next()
        switch event {
        case .itemStarted(let threadID, let item) where method == "item/started",
             .itemCompleted(let threadID, let item) where method == "item/completed":
            #expect(threadID == "t")
            #expect(item.turnID == "u")
        default: Issue.record("Missing lifecycle event: \(String(describing: event))")
        }
        #expect(await client.state(for: "t")?.items["i"]?.turnID == "u")
    }
    subscription.cancel(); await client.close()
}

@Test(arguments: ["apiKey", "API_KEY", "api-key", "Password"])
func reviewLoggerRedactsSensitiveMetadataInSink(fragment: String) {
    let key = "prefix-" + fragment + "-suffix"
    let secret = "review-only-sensitive-value"
    let logger = CodexLogger(payloadMode: .full) { _, message, metadata in
        let rendered = CodexLogger(payloadMode: .full).render(.object(metadata.mapValues(JSONValue.string)))
        #expect(message == "metadata regression")
        #expect(metadata[key] == "<redacted>")
        #expect(metadata["safe"] == "visible")
        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains(secret))
    }
    logger.log(.info, "metadata regression", metadata: [key: secret, "safe": "visible"])
}

@Test(arguments: [CodexBufferingPolicy.boundedFailing(1), .boundedCoalescingDeltas(1)])
func reviewSubscriberOverflowDoesNotCloseClient(policy: CodexBufferingPolicy) async throws {
    let transport = ReviewTransport(), client = try await reviewClient(transport)
    let slow = await client.subscribe(policy: policy)
    let healthy = await client.subscribe(policy: .unbounded)
    let event = CodexEvent.itemCompleted(threadID: "t", item: .init(raw: ["id": "i"]))
    await client.emit(event); await client.emit(event)
    var slowIterator = slow.events.makeAsyncIterator()
    #expect(try await slowIterator.next() == event)
    do { _ = try await slowIterator.next(); Issue.record("Expected subscription overflow") }
    catch {
        #expect(error as? CodexSubscriptionError == .bufferOverflow)
        #expect(error.localizedDescription == "subscriber buffer overflow")
    }
    var healthyIterator = healthy.events.makeAsyncIterator()
    #expect(try await healthyIterator.next() == event)
    #expect(try await healthyIterator.next() == event)
    #expect(await client.connectionState() == .connected(generation: 1))
    healthy.cancel(); await client.close()
}
