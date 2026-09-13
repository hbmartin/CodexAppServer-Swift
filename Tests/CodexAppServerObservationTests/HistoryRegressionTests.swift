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
    var replayOnResume: Bool
    init(results: [String: JSONValue] = [:], delayResponses: Bool = false, replayOnResume: Bool = false) {
        self.replayOnResume = replayOnResume
        self.results = results; self.delayResponses = delayResponses
        let f = AsyncThrowingStream<Data, Error>.makeStream(); incomingFrames = f.stream; frames = f.continuation
        let d = AsyncStream<CodexTransportDiagnostic>.makeStream(); diagnostics = d.stream; diagnostic = d.continuation
    }
    func start() {}
    func send(frame: Data) async throws {
        let message = try JSONValue.decode(frame); sent.append(message)
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
