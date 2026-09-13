import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerObservation

private actor ReviewTransport: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    let frames: AsyncThrowingStream<Data, Error>.Continuation
    let diagnostic: AsyncStream<CodexTransportDiagnostic>.Continuation
    var sent: [JSONValue] = []
    var closed = false
    var results: [String: JSONValue]
    var delayResponses: Bool
    var historyGate: ObservationHistoryGate?
    var replayOnResume: Bool
    init(results: [String: JSONValue] = [:], delayResponses: Bool = false, replayOnResume: Bool = false) {
        self.replayOnResume = replayOnResume
        self.results = results; self.delayResponses = delayResponses
        let f = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = f.stream; frames = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream(); diagnostics = d.stream; diagnostic = d.continuation
    }
    func start() {}
    func holdHistory(at gate: ObservationHistoryGate) { historyGate = gate }
    func send(frame: Data) async throws {
        let message = try JSONValue.decode(frame); sent.append(message)
        if message["result"] != nil, delayResponses { try await Task.sleep(for: .milliseconds(50)) }
        guard let id = message["id"], let method = message["method"]?.stringValue else { return }
        if method == "thread/resume", let historyGate { await historyGate.wait() }
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

@Test @MainActor func reviewObservationLoadsExistingHistory() async throws {
    let history: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"]]]]]]
    let transport = ReviewTransport(results: ["thread/resume": history, "thread/read": history]), client = try await reviewClient(transport)
    let model = CodexConversationDetailModel(threadID: "t")
    try await model.observe(client)
    #expect(model.turns.count == 1)
    #expect(model.items.count == 1)
    model.stopObserving(); await client.close()
}

private actor ObservationTransportSequence {
    var transports: [ReviewTransport]
    init(_ transports: [ReviewTransport]) { self.transports = transports }
    func next() throws -> ReviewTransport {
        guard !transports.isEmpty else { throw CodexError.transportClosed("exhausted") }
        return transports.removeFirst()
    }
}

@Test @MainActor func observationReconcilesHistoryAfterReconnect() async throws {
    let initial: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "inProgress", "items": [["id": "i", "type": "agentMessage", "text": "partial"]]]]]]
    let completed: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage", "text": "done"], ["id": "j", "type": "agentMessage", "text": "later"]]]]]]
    let first = ReviewTransport(results: ["thread/resume": initial, "thread/read": initial])
    let second = ReviewTransport(results: ["thread/resume": completed, "thread/read": completed])
    let sequence = ObservationTransportSequence([first, second])
    let client = CodexClient(transportFactory: .init { try await sequence.next() }, configuration: .init(requestTimeout: .seconds(2), reconnectPolicy: .init(maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero, jitter: false)))
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
    let transport = ReviewTransport(), client = try await reviewClient(transport)
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

private actor ObservationHistoryGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func stoppingObservationDuringHistorySetupPreventsLateUpdates() async throws {
    let history: JSONValue = ["thread": ["id": "t", "turns": [["id": "u", "status": "completed", "items": [["id": "i", "type": "agentMessage"]]]]]]
    let transport = ReviewTransport(results: ["thread/resume": history, "thread/read": history])
    let client = try await reviewClient(transport)
    let gate = ObservationHistoryGate()
    await transport.holdHistory(at: gate)
    let model = CodexConversationDetailModel(threadID: "t")
    var published = 0
    let token = model.publisher.sink { _ in published += 1 }
    let setup = Task { try await model.observe(client) }
    while !(await gate.waiting) { await Task.yield() }
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
