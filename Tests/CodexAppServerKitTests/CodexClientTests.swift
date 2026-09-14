import Foundation
import Testing
@testable import CodexAppServerKit
import CodexAppServerTestSupport

private func makeTransport() -> CodexScriptedTransport {
    CodexScriptedTransport(results: CodexScriptedTransport.defaultResults, ignoredMethods: ["slow"], requestHandler: { request in
        guard let method = request["method"]?.stringValue, method.hasPrefix("method-") else { return nil }
        return ["method": .string(method)]
    })
}

private actor ScriptedFactory {
    enum Step: Sendable { case transport(CodexScriptedTransport), failure(CodexError) }
    var steps: [Step]
    init(_ steps: [Step]) { self.steps = steps }
    func next() throws -> CodexScriptedTransport {
        guard !steps.isEmpty else { throw CodexError.transportClosed("script exhausted") }
        switch steps.removeFirst() { case .transport(let value): return value; case .failure(let error): throw error }
    }
}

private func makeClient(_ transport: CodexScriptedTransport, configuration: CodexClientConfiguration = .init()) -> CodexClient {
    CodexClient(transportFactory: .init { transport }, configuration: configuration)
}

@Test func jsonRoundTripPreservesUnknownValues() throws {
    let value: JSONValue = ["unknown": [1, true, nil], "text": "ok"]
    #expect(try JSONValue.decode(value.encoded(sortedKeys: true)) == value)
    #expect(value["unknown"]?[0]?.intValue == 1)
}

@Test func reviewedSchemaFixturesCoverCuratedAndUnknownProtocolSurfaces() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let schema = repository.appendingPathComponent("Schemas/0.146.0")
    let fixtures = [
        "codex_app_server_protocol.v2.schemas.json", "v2/ThreadStartParams.json", "v2/TurnStartParams.json",
        "v2/ThreadItemsListResponse.json", "CommandExecutionRequestApprovalResponse.json",
        "PermissionsRequestApprovalResponse.json", "ToolRequestUserInputResponse.json", "McpServerElicitationRequestResponse.json",
    ]
    for fixture in fixtures { #expect(try JSONValue.decode(Data(contentsOf: schema.appendingPathComponent(fixture))).objectValue != nil) }
    #expect(try CodexItem(raw: ["id": "future", "type": "futureItem", "newField": 1]).kind == .unknown("futureItem"))
}

@Test func initializeAlwaysEnablesExperimentalAndFormElicitation() async throws {
    let transport = makeTransport(), client = makeClient(transport)
    _ = try await client.connect()
    let request = await transport.messages().first { $0["method"]?.stringValue == "initialize" }
    #expect(request?["params"]?["capabilities"]?["experimentalApi"]?.boolValue == true)
    #expect(request?["params"]?["capabilities"]?["mcpServerOpenaiFormElicitation"]?.boolValue == true)
    #expect(request?["params"]?["capabilities"]?["requestAttestation"] == nil)
    await client.close()
}

@Test func concurrentRequestsAreCorrelated() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let values = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<50 { group.addTask { try await client.raw.request(method: "method-\(index)")["method"]?.stringValue ?? "" } }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(values).count == 50); await client.close()
}

@Test func cancellationOnlyCancelsLocalWaitAndLateResponseIsReported() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let subscription = await client.subscribe(policy: .unbounded)
    let task = Task { try await client.raw.request(method: "slow") }
    while await transport.requestID(method: "slow") == nil { await Task.yield() }
    let id = await transport.requestID(method: "slow")!; task.cancel()
    do { _ = try await task.value; Issue.record("expected cancellation") } catch { #expect(error as? CodexError == .requestCancelled(method: "slow")) }
    try await transport.inject(["id": id, "result": ["late": true]])
    var iterator = subscription.events.makeAsyncIterator()
    let event = try await iterator.next()
    if case .diagnostic(.unmatchedResponse(let raw)) = event { #expect(raw["result"]?["late"]?.boolValue == true) } else { Issue.record("expected unmatched response") }
    await client.close()
}

@Test func typedDiscoveryAndExplicitTurnOperations() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    #expect(try await client.listThreads().items.first?.id == "thread-1")
    let thread = try await client.startThread(options: .init(model: "gpt-5.6-luna")); #expect(thread.id == "thread-new")
    let turn = try await client.startTurn(threadID: thread.id, prompt: "hello", options: .init(model: "gpt-5.6-luna")); #expect(turn.id == "turn-1")
    _ = try await client.steerTurn(threadID: thread.id, expectedTurnID: turn.id, inputs: [.text("more")])
    let steer = await transport.messages().last { $0["method"]?.stringValue == "turn/steer" }
    #expect(steer?["params"]?["expectedTurnId"]?.stringValue == turn.id)
    await client.close()
}

@Test func completedItemIsAuthoritative() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    try await transport.inject(["method": "item/started", "params": ["threadId": "t", "item": ["id": "i", "type": "agentMessage", "text": "partial"]]])
    try await transport.inject(["method": "item/completed", "params": ["threadId": "t", "item": ["id": "i", "type": "agentMessage", "text": "final"]]])
    while await client.state(for: "t")?.items["i"]?.raw["text"]?.stringValue != "final" { await Task.yield() }
    #expect(await client.state(for: "t")?.items["i"]?.raw["text"]?.stringValue == "final")
    await client.close()
}

@Test func responseHandlesAreOneShotAndInvalidatedOnDisconnect() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 91, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "turnId": "u", "itemId": "i", "questions": [["id": "q", "question": "Choose", "options": [["label": "A"]]]]]])
    var iterator = subscription.events.makeAsyncIterator(); guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("missing request"); return }
    await client.close()
    do { try await interaction.response.respond(.answers(["q": ["A"]])); Issue.record("expected stale handle") } catch { #expect(error as? CodexError == .staleResponseHandle) }
}

@Test func dynamicToolsRouteAutomatically() async throws {
    let transport = makeTransport()
    let registry = CodexDynamicToolRegistry(tools: [.init(name: "echo", description: "", inputSchema: [:]) { .text($0["value"]?.stringValue ?? "") }])
    let client = CodexClient(transportFactory: .init { transport }, dynamicTools: registry); _ = try await client.connect()
    try await transport.inject(["id": 19, "method": "item/tool/call", "params": ["tool": "echo", "callId": "c", "arguments": ["value": "yes"]]])
    while !(await transport.messages().contains { $0["id"]?.intValue == 19 && $0["result"] != nil }) { await Task.yield() }
    #expect(await transport.messages().contains { $0["result"]?["success"]?.boolValue == true })
    await client.close()
}

@Test func boundedCoalescingPreservesAllText() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1))
    for index in 0..<20 { try await transport.inject(["method": "item/agentMessage/delta", "params": ["threadId": "t", "itemId": "i", "delta": .string("\(index),")]]) }
    // The response is queued after all injected frames, so every delta has reached the buffer.
    _ = try await client.raw.request(method: "test/barrier")
    var iterator = subscription.events.makeAsyncIterator(); let event = try await iterator.next()
    if case .itemDelta(_, _, _, let raw) = event { #expect(raw["delta"]?.stringValue == (0..<20).map { "\($0)," }.joined()) } else { Issue.record("expected delta") }
    await client.close()
}

@Test func manualRecoveryWorksAfterAutomaticReconnect() async throws {
    let first = makeTransport(), second = makeTransport(), sequence = CodexTransportSequence([first, second])
    let config = CodexClientConfiguration(reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero, jitter: false))
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: config); _ = try await client.connect()
    await first.finish(CodexError.transportClosed("test"))
    while await client.connectionState() != .connected(generation: 2) { await Task.yield() }
    #expect(await client.connectionState() == .connected(generation: 2)); await client.close()
}

@Test func mediaAndWorkspaceValidation() throws {
    let data = Data([0, 1, 2]); #expect(try CodexMedia.dataURL(data: data, mimeType: "image/png") == "data:image/png;base64,AAEC")
    #expect(throws: CodexError.self) { try CodexMedia.dataURL(data: data, mimeType: "image/png", limit: 2) }
    let roots = CodexWorkspaceRoots([URL(fileURLWithPath: "/work")]); #expect(try roots.validateAbsolutePath("/work/a.swift") == "/work/a.swift")
    #expect(throws: CodexError.self) { try roots.validateAbsolutePath("/etc/passwd") }
}

@Test func requestTimeoutIsOptInAndDoesNotCancelProtocolWork() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    do { _ = try await client.raw.request(method: "slow", timeout: .milliseconds(2)); Issue.record("expected timeout") }
    catch { #expect(error as? CodexError == .requestTimedOut(method: "slow")) }
    #expect(await transport.requestID(method: "slow") != nil)
    await client.close()
}

@Test func answeredInteractionUsesSchemaShapeAndIsOneShot() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 92, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "turnId": "u", "itemId": "i", "questions": [["id": "q", "question": "Choose"]]]])
    var iterator = subscription.events.makeAsyncIterator(); guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("missing request"); return }
    try await interaction.response.respond(.answers(["q": ["A", "B"]]))
    let response = await transport.messages().last { $0["id"]?.intValue == 92 }
    #expect(response?["result"]?["answers"]?["q"]?["answers"]?.arrayValue?.count == 2)
    do { try await interaction.response.respond(.answers([:])); Issue.record("expected one-shot failure") } catch { #expect(error as? CodexError == .responseAlreadySent) }
    await client.close()
}

@Test func malformedFrameIsPublishedWithoutCrashingOtherSubscribers() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let subscription = await client.subscribe(policy: .unbounded); await transport.injectMalformed()
    var iterator = subscription.events.makeAsyncIterator(); let event = try await iterator.next()
    if case .diagnostic(.malformedMessage) = event {} else { Issue.record("expected malformed diagnostic") }
    #expect(try await client.listThreads().items.count == 1); await client.close()
}

@Test func ninthSubscribedThreadProducesAdvisoryWithoutEnforcingLimit() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let global = await client.subscribe(policy: .unbounded)
    var subscriptions: [CodexSubscription] = []
    for index in 0..<9 { subscriptions.append(await client.events(for: "thread-\(index)")) }
    var iterator = global.events.makeAsyncIterator(); let event = try await iterator.next()
    if case .diagnostic(.highThreadSubscriptionCount(let count)) = event { #expect(count == 9) } else { Issue.record("expected advisory") }
    #expect(subscriptions.count == 9); await client.close()
}

@Test func boundedFailingEndsOnlySlowSubscriber() async throws {
    let transport = makeTransport(), client = makeClient(transport); _ = try await client.connect()
    let slow = await client.subscribe(policy: .boundedFailing(1)), healthy = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": "item/started", "params": ["threadId": "t", "item": ["id": "one", "type": "agentMessage"]]])
    try await transport.inject(["method": "item/completed", "params": ["threadId": "t", "item": ["id": "one", "type": "agentMessage"]]])
    try await Task.sleep(for: .milliseconds(5))
    var slowIterator = slow.events.makeAsyncIterator(); _ = try? await slowIterator.next()
    do { _ = try await slowIterator.next(); Issue.record("expected slow subscriber failure") } catch {}
    var healthyIterator = healthy.events.makeAsyncIterator(); #expect(try await healthyIterator.next() != nil)
    await client.close()
}

@Test func threeFailedReconnectsRetainIntentForManualRecoveryWithoutDuplicateTurnInput() async throws {
    let first = makeTransport(), recovered = makeTransport()
    let script = ScriptedFactory([.transport(first), .failure(.transportClosed("one")), .failure(.transportClosed("two")), .failure(.transportClosed("three")), .transport(recovered)])
    let configuration = CodexClientConfiguration(reconnectPolicy: .init(maximumAttempts: 3, initialDelay: .zero, maximumDelay: .zero, jitter: false))
    let client = CodexClient(transportFactory: .init { try await script.next() }, configuration: configuration)
    _ = try await client.connect(); _ = try await client.subscribeThread(id: "persisted")
    _ = try await client.startTurn(threadID: "persisted", prompt: "one input only", options: .init(model: "gpt-5.6-luna"))
    await first.finish(CodexError.transportClosed("drop"))
    while true { if case .failed = await client.connectionState() { break }; await Task.yield() }
    _ = try await client.reconnect()
    let methods = await recovered.messages().compactMap { $0["method"]?.stringValue }
    #expect(methods.contains("thread/resume")); #expect(methods.contains("thread/read")); #expect(!methods.contains("turn/start"))
    await client.close()
}
