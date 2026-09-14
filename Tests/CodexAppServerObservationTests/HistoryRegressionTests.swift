import Foundation
import Testing
import CodexAppServerTestSupport
import CodexAppServerKit
import CodexAppServerObservation

@Test @MainActor func reviewObservationLoadsExistingHistory() async throws {
    let history: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"]]]]]]
    let transport = CodexScriptedTransport(results: ["thread/resume": history, "thread/read": history]), client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConversationDetailModel(threadID: "t")
    try await model.observe(client)
    #expect(model.turns.count == 1)
    #expect(model.items.count == 1)
    model.stopObserving(); await client.close()
}


@Test @MainActor func observationReconcilesHistoryAfterReconnect() async throws {
    let initial: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "inProgress", "items": [["id": "i", "type": "agentMessage", "text": "partial"]]]]]]
    let completed: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"], ["id": "j", "type": "agentMessage", "text": "later"]]]]]]
    let first = CodexScriptedTransport(results: ["thread/resume": initial, "thread/read": initial])
    let second = CodexScriptedTransport(results: ["thread/resume": completed, "thread/read": completed])
    let sequence = CodexTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: CodexClient.immediateReconnectConfiguration)
    _ = try await client.connect()
    let model = CodexConversationDetailModel(threadID: "t")
    try await model.observe(client)
    #expect(model.turns.first?.status == "inProgress")
    await first.close()
    for _ in 0..<1000 {
        if model.turns.first?.status == "completed" { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.turns.first?.status == "completed")
    #expect(model.items.map(\.id) == ["i", "j"])
    #expect(model.items.first?.raw["text"]?.stringValue == "done")
    #expect(await client.state(for: "t")?.activeTurnIDs.isEmpty == true)
    model.stopObserving(); await client.close()
}

@Test @MainActor func observationRemovesResolvedNumericRequests() async throws {
    let transport = CodexScriptedTransport(), client = try await CodexClient.connectedTestClient(transport)
    let model = CodexPendingInteractionModel()
    await model.observe(client)
    try await transport.inject(["id": 44, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "questions": []]])
    for _ in 0..<1000 {
        if !model.pending.isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.pending.count == 1)
    try await transport.inject(["method": "serverRequest/resolved", "params": ["threadId": "t", "requestId": 44]])
    for _ in 0..<1000 {
        if model.pending.isEmpty { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(model.pending.isEmpty)
    model.stopObserving(); await client.close()
}


@Test @MainActor func stoppingObservationDuringHistorySetupPreventsLateUpdates() async throws {
    let history: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage"]]]]]]
    let transport = CodexScriptedTransport(results: ["thread/resume": history, "thread/read": history])
    let client = try await CodexClient.connectedTestClient(transport)
    let gate = CodexTestGate()
    await transport.hold(method: "thread/resume", at: gate)
    let model = CodexConversationDetailModel(threadID: "t")
    var published = 0
    let token = model.publisher.sink { _ in published += 1 }
    let setup = Task { try await model.observe(client) }
    while !(await gate.isWaiting()) { await Task.yield() }
    model.stopObserving()
    await gate.release()
    try await setup.value
    #expect(model.thread == nil)
    #expect(model.turns.isEmpty)
    #expect(model.items.isEmpty)
    #expect(published == 0)
    // A later state update must not revive the cancelled subscription.
    _ = try await client.readThread(id: "t", includeTurns: true)
    await client.close()
    for _ in 0..<10 { await Task.yield() }
    #expect(published == 0)
    token.cancel()
}
