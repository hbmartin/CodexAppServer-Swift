import Foundation
import Testing
import CodexAppServerTestSupport
@testable import CodexAppServerKit

private struct ReviewEventWaitTimedOut: Error {}

private func boundedValue<Value: Sendable>(
    of task: Task<Value, Error>,
    before deadline: ContinuousClock.Instant
) async throws -> Value {
    do {
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                task.cancel()
                throw ReviewEventWaitTimedOut()
            }
            guard let value = try await group.next() else { throw ReviewEventWaitTimedOut() }
            group.cancelAll()
            return value
        }
    } catch {
        task.cancel()
        _ = await task.result
        throw error
    }
}

@Test func boundedReviewEventWaitCancelsAtDeadline() async {
    let waiting = Task<Void, Error> { try await Task.sleep(for: .seconds(10)) }
    await #expect(throws: ReviewEventWaitTimedOut.self) {
        try await boundedValue(of: waiting, before: ContinuousClock.now + .milliseconds(10))
    }
    #expect(waiting.isCancelled)
}

@Test func reviewCommandOutputDecodesProtocolBytes() throws {
    let output = try CodexCommandOutput(raw: ["processId": "p", "stream": "stdout", "deltaBase64": "aGVsbG8=", "capReached": false])
    #expect(String(decoding: output.data, as: UTF8.self) == "hello")
}

@Test func reviewHistoryUnwrapsItemEntries() async throws {
    let transport = CodexScriptedTransport(results: ["thread/items/list": ["data": [["turnId": "u", "item": ["id": "i", "type": "agentMessage", "text": "hello"]]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    let page = try await client.listItems(threadID: "t")
    #expect(page.items.first?.id == "i")
    #expect(page.items.first?.kind == .agentMessage)
    #expect(page.items.first?.turnID == "u")
    await client.close()
}

@Test func reviewSteerReturnsServerTurnID() async throws {
    let transport = CodexScriptedTransport(results: ["turn/steer": ["turnId": "u"]])
    let client = try await CodexClient.connectedTestClient(transport)
    let turn = try await client.steerTurn(threadID: "t", expectedTurnID: "u", inputs: [.text("more")])
    #expect(turn.id == "u")
    await client.close()
}

@Test func reviewReviewTargetsUseRequiredSchemaKeys() {
    #expect(CodexReviewTarget(.commit("abc")).json["sha"]?.stringValue == "abc")
    #expect(CodexReviewTarget(.custom("inspect this")).json["instructions"]?.stringValue == "inspect this")
}

@Test func reviewDiscoveryUnwrapsSkillsAndPreservesProfileIDs() async throws {
    let transport = CodexScriptedTransport(results: ["skills/list": ["data": [["cwd": "/work", "skills": [["name": "example", "path": "/work/SKILL.md"]], "errors": []]]], "permissionProfile/list": ["data": [["id": "read-only", "allowed": true]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    #expect(try await client.listSkills().first?.id == "example")
    #expect(try await client.listPermissionProfiles().first?.id == "read-only")
    await client.close()
}

@Test func reviewResponseIsOneShotUnderConcurrentCallers() async throws {
    let transport = CodexScriptedTransport(delayResponses: true), client = try await CodexClient.connectedTestClient(transport)
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
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
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


@Test func reviewClosePreventsInflightConnectFromReopening() async throws {
    let gate = CodexTestGate(), transport = CodexScriptedTransport()
    let client = CodexClient(transportFactory: .init { await gate.wait(); return transport }, configuration: .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 0)))
    let connection = Task { try? await client.connect() }
    while !(await gate.isWaiting()) { await Task.yield() }
    await client.close()
    await gate.release()
    _ = await connection.value
    #expect(await client.connectionState() == .disconnected)
    #expect(await transport.isClosed())
    await client.close()
}

@Test func reviewHistoryHydratesStateAndClearsStaleActiveTurns() async throws {
    let transport = CodexScriptedTransport(results: ["thread/read": ["thread": ["id": "t", "status": ["type": "idle"], "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"]]]]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    await client.reduceTurn(try .init(threadID: "t", raw: ["id": "u", "status": "inProgress"]), completed: false)
    _ = try await client.readThread(id: "t", includeTurns: true)
    #expect(await client.turnStatus(threadID: "t", turnID: "u") == .completed)
    #expect(await client.state(for: "t")?.activeTurnIDs.isEmpty == true)
    #expect(await client.state(for: "t")?.items["i"]?.turnID == "u")
    await client.close()
}

@Test func terminalTurnNotificationWinsOverLateStartAcknowledgement() async throws {
    let transport = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults, ignoredMethods: ["turn/start"])
    let client = try await CodexClient.connectedTestClient(transport)
    let request = Task { try await client.startTurn(threadID: "t", prompt: "hello") }
    while await transport.requestID(method: "turn/start") == nil { await Task.yield() }
    let requestID = try #require(await transport.requestID(method: "turn/start"))
    try await transport.inject(["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "u", "status": "completed"]]])
    try await transport.inject(["id": requestID, "result": ["turn": ["id": "u", "status": "inProgress"]]])
    _ = try await request.value
    #expect(await client.turnStatus(threadID: "t", turnID: "u") == .completed)
    #expect(await client.state(for: "t")?.activeTurnIDs.contains("u") == false)
    await client.close()
}

@Test func rawProtocolEventsAreOptInAndPreserveTheOriginalEnvelope() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let typed = await client.subscribe(policy: .unbounded)
    let raw = await client.subscribe(policy: .unbounded, includesProtocolMessages: true)
    let envelope: JSONValue = ["method": "future/event", "params": ["threadId": "t", "future": 7]]
    try await transport.inject(envelope)
    var typedIterator = typed.events.makeAsyncIterator(), rawIterator = raw.events.makeAsyncIterator()
    #expect(try await typedIterator.next() == .notification(method: "future/event", params: envelope["params"]!))
    #expect(try await rawIterator.next() == .protocolMessage(envelope))
    #expect(try await rawIterator.next() == .notification(method: "future/event", params: envelope["params"]!))
    typed.cancel(); raw.cancel(); await client.close()
}

@Test func exactIntegerAccessorsRejectFractionsAndOverflow() throws {
    #expect(JSONValue.number(Decimal(string: "1.5")!).intValue == nil)
    #expect(JSONValue.number(Decimal(string: "9223372036854775808")!).int64Value == nil)
    #expect(JSONValue.number(Decimal(Int64.max)).int64Value == Int64.max)
    #expect(JSONValue.number(-1).uint32Value == nil)
    #expect(JSONValue.number(Decimal(UInt32.max)).uint32Value == UInt32.max)
}

@Test func pagingUsesTypedSortValuesPreservesBothCursorsAndRejectsInvalidLimitsLocally() async throws {
    let transport = CodexScriptedTransport(results: [
        "thread/list": ["data": [], "nextCursor": "newer", "backwardsCursor": "older"],
        "thread/turns/list": ["data": [], "backwardsCursor": "turn-older"],
    ])
    let client = try await CodexClient.connectedTestClient(transport)
    let threads = try await client.listThreads(.init(limit: 50, sortKey: .recencyAt, sortDirection: .descending))
    #expect(threads.nextCursor == "newer" && threads.backwardsCursor == "older")
    let turns = try await client.listTurns(threadID: "t", limit: 10, itemView: .full, sortDirection: .ascending)
    #expect(turns.backwardsCursor == "turn-older")
    let messages = await transport.messages()
    let threadRequest = messages.last { $0["method"] == "thread/list" }
    #expect(threadRequest?["params"]?["sortKey"] == "recency_at")
    #expect(threadRequest?["params"]?["sortDirection"] == "desc")
    let turnRequest = messages.last { $0["method"] == "thread/turns/list" }
    #expect(turnRequest?["params"]?["itemsView"] == "full")
    #expect(turnRequest?["params"]?["sortDirection"] == "asc")
    let before = messages.count
    await #expect(throws: CodexError.invalidArgument("limit must fit an unsigned 32-bit integer")) {
        _ = try await client.listThreads(.init(limit: -1))
    }
    #expect(await transport.messages().count == before)
    await client.close()
}

@Test func commandOutputRejectsWrongTypesAndInvalidBase64() {
    #expect(throws: CodexError.invalidField("commandOutput.stream")) {
        try CodexCommandOutput(raw: ["processId": "p", "stream": 1, "deltaBase64": "aGk=", "capReached": false])
    }
    #expect(throws: CodexError.invalidField("commandOutput.deltaBase64")) {
        try CodexCommandOutput(raw: ["processId": "p", "stream": "stdout", "deltaBase64": "%%%", "capReached": false])
    }
    #expect(throws: CodexError.invalidField("commandOutput.capReached")) {
        try CodexCommandOutput(raw: ["processId": "p", "stream": "stdout", "deltaBase64": "aGk=", "capReached": 0])
    }
}

@Test func unscopedLostInteractionRequiresExplicitAcknowledgementWhileReadsRemainAvailable() async throws {
    let first = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let second = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: sequence.factory, configuration: CodexClient.immediateReconnectConfiguration)
    _ = try await client.connect()
    try await first.inject(["id": "global-request", "method": "account/request", "params": [:]])
    while await client.connectionState() != .connected(generation: 1) { await Task.yield() }
    await first.finish(CodexError.transportClosed("drop"))
    var context: CodexRecoveryContext?
    for _ in 0..<2_000 {
        if case .recoveryRequired(let value) = await client.connectionState() { context = value; break }
        await Task.yield()
    }
    #expect(context?.unscopedRequestIDs == ["global-request"])
    _ = try await client.listModels()
    await #expect(throws: CodexError.operationUnavailableDuringRecovery("thread/start")) {
        _ = try await client.startThread()
    }
    try await client.acknowledgeLostInteractions(ids: ["global-request"])
    #expect(await client.connectionState() == .connected(generation: 2))
    await client.close()
}

@Test func explicitAndStreamSubscriptionIntentsHaveIndependentLifetimes() async throws {
    let first = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let second = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: sequence.factory, configuration: CodexClient.immediateReconnectConfiguration)
    _ = try await client.connect()
    _ = try await client.subscribeThread(id: "explicit")
    let temporary = try await client.events(for: "temporary")
    temporary.cancel()
    for _ in 0..<100 { await Task.yield() }
    await first.finish(CodexError.transportClosed("drop"))
    for _ in 0..<2_000 {
        if await client.connectionState() == .connected(generation: 2) { break }
        await Task.yield()
    }
    let restored = await second.messages().filter { $0["method"] == "thread/resume" }.compactMap { $0["params"]?["threadId"]?.stringValue }
    #expect(restored == ["explicit"])
    await client.close()
}

@Test func dequeEventBufferHandlesLargeOrderedBacklog() async throws {
    let count = 100_000
    let buffer = CodexEventBuffer(policy: .unbounded, maximumCoalescedBytes: 1024, onTermination: {})
    for index in 0..<count {
        #expect(buffer.yield(.notification(method: "event", params: ["index": .number(Decimal(index))])))
    }
    for index in 0..<count {
        guard case .notification(_, let params) = try await buffer.next() else { Issue.record("missing queued event"); return }
        #expect(params["index"]?.intValue == index)
    }
    buffer.finish()
}

@Test func reviewDeltaCoalescingPreservesAppendedText() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .boundedCoalescingDeltas(1))
    await client.emit(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "hello "]))
    await client.emit(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "world"]))
    var iterator = subscription.events.makeAsyncIterator()
    if case .itemDelta(_, _, _, let raw) = try await iterator.next() { #expect(raw["delta"]?.stringValue == "hello world") }
    else { Issue.record("Missing coalesced delta") }
    await client.close()
}

@Test func reviewCommandAndReasoningDeltasRouteAsTypedEvents() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": "item/reasoning/textDelta", "params": ["threadId": "t", "turnId": "u", "itemId": "i", "delta": "reasoning", "contentIndex": 0]])
    var iterator = subscription.events.makeAsyncIterator()
    if case .itemDelta = try await iterator.next() {} else { Issue.record("Reasoning delta routed as generic notification") }
    await client.close()
}

@Test func reviewUsageUpdatesAreAvailableThroughTypedAccessor() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": "thread/tokenUsage/updated", "params": ["threadId": "t", "turnId": "u", "tokenUsage": ["total": ["totalTokens": 123]]]])
    var iterator = subscription.events.makeAsyncIterator(); _ = try await iterator.next()
    #expect(await client.turnUsage(threadID: "t") != nil)
    await client.close()
}

@Test func reviewNullNetworkContextIsCommandApproval() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["id": 44, "method": "item/commandExecution/requestApproval", "params": ["threadId": "t", "networkApprovalContext": .null]])
    var iterator = subscription.events.makeAsyncIterator()
    if case .serverRequest(let interaction) = try await iterator.next() { #expect(interaction.kind == .commandApproval) }
    else { Issue.record("request missing") }
    await client.close()
}


@Test func reviewReplayedInteractionHandlerCanRespondDuringRecovery() async throws {
    let history: JSONValue = ["thread": ["id": "t", "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]], "turns": []]]
    let first = CodexScriptedTransport(results: ["thread/resume": history, "thread/read": history])
    let second = CodexScriptedTransport(results: ["thread/resume": history, "thread/read": history], replayOnResume: true)
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: CodexClient.immediateReconnectConfiguration)
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
    let gate = CodexTestGate(), transport = CodexScriptedTransport()
    await transport.holdStart(at: gate)
    let client = CodexClient(transportFactory: .init { transport })
    let connection = Task { try? await client.connect() }
    while !(await gate.isWaiting()) { await Task.yield() }
    await client.close(); await gate.release(); _ = await connection.value
    #expect(await client.connectionState() == .disconnected)
    #expect(await transport.isClosed())
}

@Test func closeCancelsReconnectBackoffBeforeCreatingTransport() async throws {
    let first = CodexScriptedTransport(), second = CodexScriptedTransport()
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: .init(reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .seconds(10), jitter: false)))
    _ = try await client.connect()
    let events = await client.subscribe(policy: .unbounded)
    await first.close()
    for try await event in events.events {
        if case .connection(.reconnecting) = event { break }
    }
    await client.close()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await sequence.remainingCount() == 1)
    #expect(await client.connectionState() == .disconnected)
}

@Test func supersededConnectCannotTearDownNewConnection() async throws {
    let gate = CodexTestGate(), first = CodexScriptedTransport(), second = CodexScriptedTransport()
    await first.holdStart(at: gate)
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() })
    let initial = Task { try? await client.connect() }
    while !(await gate.isWaiting()) { await Task.yield() }
    _ = try await client.reconnect()
    await gate.release(); _ = await initial.value
    #expect(await client.connectionState() == .connected(generation: 1))
    #expect(await first.isClosed())
    #expect(!(await second.isClosed()))
    await client.close()
}

@Test func directResponsesAreReservedBeforeTransportSend() async throws {
    let transport = CodexScriptedTransport(delayResponses: true), client = try await CodexClient.connectedTestClient(transport)
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

@Test func ambiguousResponseFailureIsRecoverableOnlyThroughAFreshReplayHandle() async throws {
    let first = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let second = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let third = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let sequence = CodexTransportSequence([first, second, third])
    let client = CodexClient(transportFactory: sequence.factory, configuration: CodexClient.immediateReconnectConfiguration)
    _ = try await client.connect()
    await first.failResponses()
    let events = await client.subscribe(policy: .unbounded)
    try await first.inject(["id": 44, "method": "account/request", "params": [:]])
    var iterator = events.events.makeAsyncIterator()
    guard case .serverRequest(let interaction) = try await iterator.next() else { Issue.record("missing request"); return }
    _ = try? await interaction.response.respond(.answers([:]))
    do { try await interaction.response.respond(.answers([:])); Issue.record("retried ambiguous response") }
    catch { #expect(error as? CodexError == .responseAlreadySent) }
    #expect(await first.messages().filter { $0["id"] == 44 && $0["result"] != nil }.count == 1)
    #expect(await first.isClosed())

    for _ in 0..<2_000 {
        if case .recoveryRequired = await client.connectionState() { break }
        await Task.yield()
    }
    guard case .recoveryRequired(let recovery) = await client.connectionState() else {
        Issue.record("missing recovery state"); await client.close(); return
    }
    #expect(recovery.unscopedRequestIDs == [44])

    try await second.inject(["id": 44, "method": "account/request", "params": [:]])
    var replayIterator = iterator
    let replayTask = Task { () throws -> CodexPendingInteraction? in
        while let event = try await replayIterator.next() {
            if case .serverRequest(let interaction) = event { return interaction }
        }
        return nil
    }
    let replayed: CodexPendingInteraction?
    do {
        replayed = try await boundedValue(of: replayTask, before: ContinuousClock.now + .seconds(2))
    } catch is ReviewEventWaitTimedOut {
        Issue.record("missing replay event before deadline")
        await client.close()
        return
    }
    let replayedInteraction = try #require(replayed)
    #expect(replayedInteraction.generation != interaction.generation)
    try await replayedInteraction.response.respond(.answers([:]))
    #expect(await second.messages().filter { $0["id"] == 44 && $0["result"] != nil }.count == 1)
    try await second.inject(["method": "serverRequest/resolved", "params": ["requestId": 44]])
    await second.finish(CodexError.transportClosed("drop after resolution"))
    for _ in 0..<2_000 {
        if await client.connectionState() == .connected(generation: 3) { break }
        await Task.yield()
    }
    #expect(await client.connectionState() == .connected(generation: 3))
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
    case "lifecycle": next = .itemCompleted(threadID: "t", item: try .init(raw: ["id": "i", "type": "reasoning"]))
    default: next = .itemDelta(threadID: "t", itemID: "i", method: "item/reasoning/textDelta", delta: ["delta": "def", "contentIndex": 0])
    }
    #expect(buffer.yield(first))
    #expect(!buffer.yield(next))
    #expect(try await buffer.next() == first)
    do { _ = try await buffer.next(); Issue.record("overflow was hidden") }
    catch { #expect(error as? CodexSubscriptionError == .bufferOverflow) }
}

@Test func cancellingIdleEventIteratorFinishesIt() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
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
    let transport = CodexScriptedTransport()
    await transport.replayWhenInitialized()
    let client = CodexClient(transportFactory: .init { transport }, configuration: .init(requestTimeout: .seconds(2)))
    await client.setInteractionHandler { _ in .answers([:]) }
    _ = try await client.connect()
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await transport.messages().contains(where: { $0["id"] == 56 && $0["result"] != nil }) { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await transport.messages().contains { $0["id"] == 56 && $0["result"] != nil })
    await client.close()
}

@Test func reviewItemLifecycleRetainsOwningTurn() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let subscription = try await client.events(for: "t", policy: .unbounded)
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
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let slow = await client.subscribe(policy: policy)
    let healthy = await client.subscribe(policy: .unbounded)
    let event = CodexEvent.itemCompleted(threadID: "t", item: try .init(raw: ["id": "i"]))
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
