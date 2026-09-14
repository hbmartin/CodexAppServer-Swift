import Combine
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerObservation
import CodexAppServerTestSupport

// MARK: - CodexStreamedItemModel: a pure reducer, no client needed

@MainActor @Test func streamedItemAdoptsStartedItemAndCollectsDeltas() throws {
    let model = CodexStreamedItemModel()
    let item = try CodexItem(raw: ["id": "i", "type": "agentMessage"])
    model.consume(.itemStarted(threadID: "t", item: item))
    model.consume(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "one"]))
    model.consume(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "two"]))
    #expect(model.item?.id == "i")
    #expect(model.deltas.count == 2)
}

@MainActor @Test func streamedItemIgnoresDeltasForADifferentItemOnceAdopted() throws {
    let model = CodexStreamedItemModel()
    model.consume(.itemStarted(threadID: "t", item: try CodexItem(raw: ["id": "i", "type": "agentMessage"])))
    model.consume(.itemDelta(threadID: "t", itemID: "other", method: "item/agentMessage/delta", delta: ["delta": "x"]))
    #expect(model.deltas.isEmpty)
}

@MainActor @Test func streamedItemAcceptsDeltasBeforeAnyItemIsAdopted() {
    let model = CodexStreamedItemModel()
    model.consume(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "early"]))
    #expect(model.deltas.count == 1)
}

@MainActor @Test func streamedItemCompletionClearsDeltasButStartDoesNot() throws {
    let model = CodexStreamedItemModel()
    let item = try CodexItem(raw: ["id": "i", "type": "agentMessage"])
    model.consume(.itemStarted(threadID: "t", item: item))
    model.consume(.itemDelta(threadID: "t", itemID: "i", method: "item/agentMessage/delta", delta: ["delta": "one"]))
    #expect(model.deltas.count == 1)

    model.consume(.itemStarted(threadID: "t", item: item))
    #expect(model.deltas.count == 1, "itemStarted must not clear accumulated deltas")

    model.consume(.itemCompleted(threadID: "t", item: item))
    #expect(model.deltas.isEmpty)
    #expect(model.item?.id == "i")
}

@MainActor @Test func streamedItemPublishesEveryEventIncludingIgnoredOnes() {
    let model = CodexStreamedItemModel()
    var received = 0
    let token = model.publisher.sink { _ in received += 1 }
    model.consume(.connection(.disconnected))
    model.consume(.diagnostic(.malformedMessage("ignored")))
    #expect(received == 2)
    token.cancel()
}

// MARK: - CodexCombinePublishers

@MainActor @Test func publishThreadsKeepsTheLastEntryForARepeatedID() throws {
    // A server may repeat a thread across pages. That must replace, not trap.
    let publishers = CodexCombinePublishers()
    var latest: [CodexThread] = []
    let token = publishers.threads.sink { latest = $0 }
    let first = try CodexThread(raw: ["id": "t", "name": "first"])
    let second = try CodexThread(raw: ["id": "t", "name": "second"])
    let other = try CodexThread(raw: ["id": "other"])
    publishers.publishThreads([first, other, second])
    #expect(latest.map(\.id) == ["t", "other"])
    #expect(latest.first?.name == "second")
    token.cancel()
}

@MainActor @Test func combinePublishersForwardConnectionAndThreadNotifications() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let publishers = CodexCombinePublishers()
    var states: [CodexConnectionState] = []
    var threadNames: Set<String> = []
    let tokens = [
        publishers.connection.sink { states.append($0) },
        publishers.threads.sink { threads in threadNames.formUnion(threads.compactMap(\.name)) },
    ]
    await publishers.observe(client)

    try await transport.inject(["method": "thread/updated", "params": ["thread": ["id": "t", "name": "Renamed"]]])
    for _ in 0 ..< 1_000 where threadNames.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    #expect(threadNames.contains("Renamed"))

    await client.close()
    for _ in 0 ..< 1_000 where states.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!states.isEmpty)
    publishers.stopObserving()
    tokens.forEach { $0.cancel() }
}

@MainActor @Test func combinePublishersIgnoreAThreadNotificationWithoutAnID() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let publishers = CodexCombinePublishers()
    var emissions = 0
    var processed = false
    let token = publishers.threads.sink { _ in emissions += 1 }
    let acknowledgement = publishers.events.sink { event in
        if case .notification(let method, _) = event, method == "thread/updated" { processed = true }
    }
    await publishers.observe(client)

    try await transport.inject(["method": "thread/updated", "params": ["thread": ["name": "no id"]]])
    // The same MainActor loop emits events and reduces threads without an intervening await.
    for _ in 0 ..< 1_000 where !processed { try await Task.sleep(for: .milliseconds(2)) }
    try #require(processed, "the observer must process the malformed notification")
    #expect(emissions == 0)

    publishers.stopObserving(); token.cancel(); acknowledgement.cancel(); await client.close()
}

// MARK: - CodexConversationCollectionModel

@MainActor @Test func collectionModelRefreshesAndPublishesThreads() async throws {
    let transport = CodexScriptedTransport(results: [
        "thread/list": ["data": [["id": "a", "name": "Alpha"], ["id": "b", "name": "Beta"]]],
    ])
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConversationCollectionModel()
    var published: [[CodexThread]] = []
    let token = model.publisher.sink { published.append($0) }

    try await model.refresh(using: client)
    #expect(model.conversations.map(\.id) == ["a", "b"])
    #expect(published.last?.count == 2)

    token.cancel(); await client.close()
}

@MainActor @Test func collectionModelForwardsTheQueryToTheServer() async throws {
    let transport = CodexScriptedTransport(results: ["thread/list": ["data": []]])
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConversationCollectionModel()

    try await model.refresh(using: client, query: .init(limit: 7))
    let listRequest = await transport.messages().first { $0["method"]?.stringValue == "thread/list" }
    #expect(listRequest?["params"]?["limit"]?.intValue == 7)

    await client.close()
}

@MainActor @Test func collectionModelLeavesConversationsIntactWhenRefreshFails() async throws {
    let transport = CodexScriptedTransport(results: ["thread/list": ["data": [["id": "a"]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConversationCollectionModel()
    try await model.refresh(using: client)
    #expect(model.conversations.count == 1)

    // A request failure must preserve the previous collection.
    await client.close()
    await #expect(throws: CodexError.self) { try await model.refresh(using: client) }
    #expect(model.conversations.count == 1)

    await client.close()
}

// MARK: - CodexConnectionModel

@MainActor @Test func connectionModelStartsDisconnected() {
    #expect(CodexConnectionModel().state == .disconnected)
}

@MainActor @Test func connectionModelTracksStateAndStopsCleanly() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConnectionModel()
    var published: [CodexConnectionState] = []
    let token = model.publisher.sink { published.append($0) }

    await model.observe(client)
    #expect(model.state == .connected(generation: 1))

    await client.close()
    for _ in 0 ..< 1_000 where model.state != .disconnected { try await Task.sleep(for: .milliseconds(2)) }
    #expect(model.state == .disconnected)
    #expect(published.contains(.disconnected))

    model.stopObserving()
    token.cancel()
}

@MainActor @Test func connectionModelStopsUpdatingAfterStopObserving() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexConnectionModel()
    await model.observe(client)
    model.stopObserving()

    await client.close()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.state == .connected(generation: 1), "state must not move after stopObserving")
}

// MARK: - CodexPendingInteractionModel

@MainActor @Test func pendingInteractionsAreClearedWhenTheConnectionDrops() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let model = CodexPendingInteractionModel()
    await model.observe(client)

    try await transport.inject([
        "id": 44, "method": "item/tool/requestUserInput",
        "params": ["threadId": "t", "questions": []],
    ])
    for _ in 0 ..< 1_000 where model.pending.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    #expect(model.pending.count == 1)

    // Losing the connection invalidates every outstanding handle, so the list must empty.
    await client.close()
    for _ in 0 ..< 1_000 where !model.pending.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    #expect(model.pending.isEmpty)

    model.stopObserving()
}
