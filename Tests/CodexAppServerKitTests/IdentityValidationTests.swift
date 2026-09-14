import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerTestSupport

// Identity fields are validated at initialization, so an empty ID is unconstructible. These
// tests pin the two halves of that contract: a whole-object decode fails the caller, while a
// notification-path decode is reported and dropped without disturbing anything else.

// MARK: - Request path: the caller is told

@Test func threadWithoutIDFailsTheRequest() async throws {
    let transport = CodexScriptedTransport(results: ["thread/read": ["thread": ["name": "no id here"]]])
    let client = try await CodexClient.connectedTestClient(transport)
    do {
        _ = try await client.readThread(id: "t")
        Issue.record("expected a missing-field failure")
    } catch {
        #expect(error as? CodexError == .missingField("thread.id"))
    }
    await client.close()
}

@Test func threadListPreservesValidEntriesAndNextCursor() async throws {
    let raw: JSONValue = ["data": [["id": "a"], ["name": "nameless"]], "nextCursor": "page-2"]
    let transport = CodexScriptedTransport(results: ["thread/list": raw])
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    let page = try await client.listThreads()
    #expect(page.items.map(\.id) == ["a"])
    #expect(page.nextCursor == "page-2")
    #expect(page.raw == raw)
    var iterator = subscription.events.makeAsyncIterator()
    #expect(try await iterator.next() == .diagnostic(.malformedMessage("thread/list: skipped 1 malformed entries")))
    await transport.setResults(["thread/list": ["data": [["id": "b"]]]])
    #expect(try await client.listThreads(.init(cursor: page.nextCursor)).items.map(\.id) == ["b"])
    #expect(await transport.messages().last?["params"]?["cursor"] == "page-2")
    subscription.cancel(); await client.close()
}

@Test func skillListSkipsAnEntryWithoutAName() async throws {
    let transport = CodexScriptedTransport(results: ["skills/list": ["data": [["skills": [["description": "no name"], ["name": "kept"]]]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    #expect(try await client.listSkills().map(\.id) == ["kept"])
    await client.close()
}

@Test func emptyThreadIDIsRejectedBeforeAnyRequestIsSent() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    await #expect(throws: CodexError.invalidArgument("threadID must not be empty")) { _ = try await client.subscribeThread(id: "") }
    // The guard runs first, so no round-trip was spent on a request that could not succeed.
    let methods = await transport.messages().compactMap { $0["method"]?.stringValue }
    #expect(!methods.contains("thread/resume"))
    await client.close()
}

// MARK: - Notification path: reported, dropped, and otherwise harmless

@Test func malformedItemNotificationIsDiagnosedWithoutFailingLaterRequests() async throws {
    let transport = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.events(for: "t", policy: .unbounded)

    try await transport.inject(["method": "item/started", "params": ["threadId": "t", "item": ["type": "agentMessage"]]])

    var iterator = subscription.events.makeAsyncIterator()
    guard case .diagnostic(.threadMalformedMessage(let threadID, let message)) = try await iterator.next() else {
        Issue.record("expected a malformed-message diagnostic"); return
    }
    #expect(threadID == "t")
    #expect(message.contains("item/started"))
    #expect(message.contains("item.id"))

    // Nothing was reduced, and the connection still serves requests.
    #expect(await client.state(for: "t") == nil)
    #expect(try await client.listThreads().items.count == 1)
    await client.close()
}

@Test func turnNotificationWithoutThreadIDIsDiagnosed() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)

    try await transport.inject(["method": "turn/started", "params": ["turn": ["id": "u"]]])

    var iterator = subscription.events.makeAsyncIterator()
    guard case .diagnostic(.malformedMessage(let message)) = try await iterator.next() else {
        Issue.record("expected a malformed-message diagnostic"); return
    }
    #expect(message.contains("params.threadId"))
    await client.close()
}

@Test func commandOutputWithoutProcessIDIsDiagnosedInsteadOfEmitted() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)

    // processId demultiplexes streamed output; an empty one would merge unrelated processes.
    try await transport.inject(["method": "command/exec/outputDelta", "params": ["stream": "stdout", "deltaBase64": "aGk="]])

    var iterator = subscription.events.makeAsyncIterator()
    let event = try await iterator.next()
    guard case .diagnostic(.malformedMessage(let message)) = event else {
        Issue.record("expected a diagnostic, got \(String(describing: event))"); return
    }
    #expect(message.contains("commandOutput.processId"))
    await client.close()
}

@Test func historyReplaySkipsMalformedElementsAndReportsOnce() async throws {
    let history: JSONValue = ["thread": ["id": "t", "turns": [
        ["id": "u", "status": "completed", "items": [
            ["id": "i", "type": "agentMessage", "text": "kept"],
            ["type": "agentMessage", "text": "dropped, no id"],
        ]],
        ["status": "completed", "items": []],
    ]]]
    let transport = CodexScriptedTransport(results: ["thread/read": history, "thread/resume": history])
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.events(for: "t", policy: .unbounded)

    _ = try await client.readThread(id: "t", includeTurns: true)

    // One summary diagnostic covers the whole replay rather than one per bad element.
    var messages: [String] = []
    var iterator = subscription.events.makeAsyncIterator()
    for _ in 0 ..< 4 {
        guard let event = try await iterator.next() else { break }
        if case .diagnostic(.threadMalformedMessage(_, let message)) = event { messages.append(message) }
        if case .threadStateUpdated = event { break }
    }
    #expect(messages.count == 1)
    #expect(messages.first?.contains("skipped 2") == true)

    let state = await client.state(for: "t")
    #expect(state?.turns.count == 1)
    #expect(state?.items.count == 1)
    #expect(state?.itemOrder == ["i"])
    await client.close()
}

// MARK: - Directory entries use the pinned schema and per-child metadata

@Test func directoryListingReadsSymlinkFlagsFromMetadata() async throws {
    let root = URL(fileURLWithPath: "/tmp/workspace")
    let listing: JSONValue = ["entries": [
        ["fileName": "plain.txt", "isDirectory": false, "isFile": true],
        ["fileName": "link.txt", "isDirectory": false, "isFile": true],
    ]]
    let transport = CodexScriptedTransport(results: [
        "fs/getMetadata": ["isDirectory": true, "isFile": false, "isSymlink": false],
        "fs/readDirectory": listing,
    ], requestHandler: { request in
        guard request["method"] == "fs/getMetadata", let path = request["params"]?["path"]?.stringValue else { return nil }
        return ["isDirectory": .bool(path == "/tmp/workspace"), "isFile": .bool(path != "/tmp/workspace"), "isSymlink": .bool(path.hasSuffix("/link.txt"))]
    })
    let client = try await CodexClient.connectedTestClient(transport)
    let entries = try await client.listDirectory(path: "/tmp/workspace", roots: .init([root]))
    #expect(entries.count == 2)
    let metadataPaths = await transport.messages().filter { $0["method"] == "fs/getMetadata" }.compactMap { $0["params"]?["path"]?.stringValue }
    #expect(metadataPaths == ["/tmp/workspace", "/tmp/workspace/plain.txt", "/tmp/workspace/link.txt"])
    #expect(entries.first(where: { $0.name == "link.txt" })?.isSymlink == true)
    #expect(entries.first(where: { $0.name == "plain.txt" })?.isSymlink == false)
    await client.close()
}

@Test(arguments: ["thread/turns/list", "thread/items/list"])
func malformedHistoryPageStillAllowsFetchingNextPage(method: String) async throws {
    let valid: JSONValue = method == "thread/turns/list" ? ["id": "u"] : ["turnId": "u", "item": ["id": "i"]]
    let raw: JSONValue = ["data": [.object([:]), valid], "nextCursor": "next"]
    let transport = CodexScriptedTransport(results: [method: raw])
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.events(for: "t", policy: .unbounded)
    if method == "thread/turns/list" {
        let page = try await client.listTurns(threadID: "t")
        #expect(page.items.map(\.id) == ["u"])
        #expect(page.nextCursor == "next")
        #expect(page.raw == raw)
        _ = try await client.listTurns(threadID: "t", cursor: page.nextCursor)
    } else {
        let page = try await client.listItems(threadID: "t")
        #expect(page.items.map(\.id) == ["i"])
        #expect(page.nextCursor == "next")
        #expect(page.raw == raw)
        _ = try await client.listItems(threadID: "t", cursor: page.nextCursor)
    }
    #expect(await transport.messages().last?["params"]?["cursor"] == "next")
    var iterator = subscription.events.makeAsyncIterator()
    #expect(try await iterator.next() == .diagnostic(.threadMalformedMessage(threadID: "t", message: "\(method): skipped 1 malformed entries")))
    subscription.cancel(); await client.close()
}

@Test(arguments: ["model/list", "collaborationMode/list", "permissionProfile/list"])
func discoveryListsRetainValidEntries(method: String) async throws {
    let valid: JSONValue = ["id": "kept", "name": "kept"]
    let transport = CodexScriptedTransport(results: [method: ["data": [.object([:]), valid]]])
    let client = try await CodexClient.connectedTestClient(transport)
    let ids: [String]
    switch method {
    case "model/list": ids = try await client.listModels().map(\.id)
    case "collaborationMode/list": ids = try await client.listCollaborationModes().map(\.id)
    default: ids = try await client.listPermissionProfiles().map(\.id)
    }
    #expect(ids == ["kept"])
    await client.close()
}

@Test(arguments: ["thread/start", "thread/fork", "turn/start", "turn/steer"], [false, true])
func invalidMutationResultPreservesAcknowledgementAndDoesNotRetry(method: String, missingObject: Bool) async throws {
    let response: JSONValue = missingObject ? .object([:]) : ["thread": ["id": ""], "turn": ["id": ""], "turnId": ""]
    let transport = CodexScriptedTransport(results: [method: response])
    let client = try await CodexClient.connectedTestClient(transport)
    do {
        switch method {
        case "thread/start": _ = try await client.startThread()
        case "thread/fork": _ = try await client.forkThread(id: "t")
        case "turn/start": _ = try await client.startTurn(threadID: "t", prompt: "hello")
        default: _ = try await client.steerTurn(threadID: "t", expectedTurnID: "u", inputs: [.text("hello")])
        }
        Issue.record("malformed success must not return an invalid model")
    } catch let error as CodexError {
        guard case .invalidMutationResponse(let acknowledgedMethod, _, let raw) = error else {
            Issue.record("expected acknowledged mutation error, got \(error)"); await client.close(); return
        }
        #expect(acknowledgedMethod == method)
        #expect(raw == response)
        #expect(error.localizedDescription.contains("may have taken effect"))
    }
    #expect(await transport.messages().filter { $0["method"]?.stringValue == method }.count == 1)
    #expect(await client.state(for: "") == nil)
    await client.close()
}

@Test(arguments: ["read", "resume", "fork", "turns", "items", "start", "steerThread", "steerTurn", "interrupt", "archive", "unsubscribe"])
func invalidIdentityArgumentsNeverSendRequests(operation: String) async throws {
    let transport = CodexScriptedTransport.scripted()
    let client = try await CodexClient.connectedTestClient(transport)
    let before = await transport.messages().count
    do {
        switch operation {
        case "read": _ = try await client.readThread(id: "")
        case "resume": _ = try await client.resumeThread(id: "")
        case "fork": _ = try await client.forkThread(id: "", mode: .lastTurn)
        case "turns": _ = try await client.listTurns(threadID: "")
        case "items": _ = try await client.listItems(threadID: "t", turnID: "")
        case "start": _ = try await client.startTurn(threadID: "", prompt: "hello")
        case "steerThread": _ = try await client.steerTurn(threadID: "", expectedTurnID: "u", inputs: [])
        case "steerTurn": _ = try await client.steerTurn(threadID: "t", expectedTurnID: "", inputs: [])
        case "interrupt": try await client.interruptTurn(threadID: "t", turnID: "")
        case "archive": try await client.archiveThread(id: "")
        default: try await client.unsubscribeThread(id: "")
        }
        Issue.record("expected local argument validation")
    } catch let error as CodexError {
        guard case .invalidArgument = error else { Issue.record("expected argument error, got \(error)"); return }
        #expect(!error.localizedDescription.contains("response"))
    }
    #expect(await transport.messages().count == before)
    await client.close()
}

@Test(arguments: ["item/started", "item/completed", "turn/started", "turn/completed", "thread/tokenUsage/updated", "item/agentMessage/delta"])
func emptyNotificationThreadIDIsDiagnosedWithoutCreatingState(method: String) async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)
    try await transport.inject(["method": .string(method), "params": ["threadId": "", "item": ["id": "i"], "turn": ["id": "u"], "tokenUsage": ["total": 1]]])
    var iterator = subscription.events.makeAsyncIterator()
    #expect(try await iterator.next() == .diagnostic(.malformedMessage("\(method): missing or empty params.threadId")))
    #expect(await client.state(for: "") == nil)
    subscription.cancel(); await client.close()
}

@Test func threadDiagnosticsDoNotLeakIntoOtherThreadSubscriptions() async throws {
    let transport = CodexScriptedTransport(results: ["thread/read": ["thread": ["id": "other", "turns": []]]])
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.events(for: "other", policy: .unbounded)
    try await transport.inject(["method": "item/started", "params": ["threadId": "t", "item": ["type": "agentMessage"]]])
    // A subsequent snapshot is an ordered marker on the other thread's stream.
    _ = try await client.readThread(id: "other", includeTurns: true)
    var iterator = subscription.events.makeAsyncIterator()
    guard case .threadStateUpdated(let threadID, _) = try await iterator.next() else {
        Issue.record("unrelated thread received the diagnostic"); subscription.cancel(); await client.close(); return
    }
    #expect(threadID == "other")
    subscription.cancel(); await client.close()
}
