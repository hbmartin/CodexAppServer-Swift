import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerTestSupport

// Identity fields are validated at initialization, so an empty ID is unconstructible. These
// tests pin the two halves of that contract: a request-path decode fails the caller, while a
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

@Test func threadListRejectsAnEntryWithoutAnID() async throws {
    let transport = CodexScriptedTransport(results: ["thread/list": ["data": [["id": "a"], ["name": "nameless"]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    await #expect(throws: CodexError.missingField("thread.id")) { _ = try await client.listThreads() }
    await client.close()
}

@Test func skillWithoutNameFailsTheRequest() async throws {
    let transport = CodexScriptedTransport(results: ["skills/list": ["data": [["skills": [["description": "no name"]]]]]])
    let client = try await CodexClient.connectedTestClient(transport)
    await #expect(throws: CodexError.missingField("skill.name")) { _ = try await client.listSkills() }
    await client.close()
}

@Test func emptyThreadIDIsRejectedBeforeAnyRequestIsSent() async throws {
    let transport = CodexScriptedTransport()
    let client = try await CodexClient.connectedTestClient(transport)
    await #expect(throws: CodexError.missingField("thread.id")) { _ = try await client.subscribeThread(id: "") }
    // The guard runs first, so no round-trip was spent on a request that could not succeed.
    let methods = await transport.messages().compactMap { $0["method"]?.stringValue }
    #expect(!methods.contains("thread/resume"))
    await client.close()
}

// MARK: - Notification path: reported, dropped, and otherwise harmless

@Test func malformedItemNotificationIsDiagnosedWithoutFailingLaterRequests() async throws {
    let transport = CodexScriptedTransport(results: CodexScriptedTransport.defaultResults)
    let client = try await CodexClient.connectedTestClient(transport)
    let subscription = await client.subscribe(policy: .unbounded)

    try await transport.inject(["method": "item/started", "params": ["threadId": "t", "item": ["type": "agentMessage"]]])

    var iterator = subscription.events.makeAsyncIterator()
    guard case .diagnostic(.malformedMessage(let message)) = try await iterator.next() else {
        Issue.record("expected a malformed-message diagnostic"); return
    }
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
    let subscription = await client.subscribe(policy: .unbounded)

    _ = try await client.readThread(id: "t", includeTurns: true)

    // One summary diagnostic covers the whole replay rather than one per bad element.
    var messages: [String] = []
    var iterator = subscription.events.makeAsyncIterator()
    for _ in 0 ..< 4 {
        guard let event = try await iterator.next() else { break }
        if case .diagnostic(.malformedMessage(let message)) = event { messages.append(message) }
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

// MARK: - Directory entries report the symlink flag the server sent

@Test func directoryListingPreservesTheSymlinkFlag() async throws {
    let root = URL(fileURLWithPath: "/tmp/workspace")
    let listing: JSONValue = ["entries": [
        ["fileName": "plain.txt", "isDirectory": false, "isSymlink": false],
        ["fileName": "link.txt", "isDirectory": false, "isSymlink": true],
    ]]
    let transport = CodexScriptedTransport(results: [
        "fs/getMetadata": ["isDirectory": true, "isFile": false, "isSymlink": false],
        "fs/readDirectory": listing,
    ])
    let client = try await CodexClient.connectedTestClient(transport)
    let entries = try await client.listDirectory(path: "/tmp/workspace", roots: .init([root]))
    #expect(entries.count == 2)
    #expect(entries.first(where: { $0.name == "link.txt" })?.isSymlink == true)
    #expect(entries.first(where: { $0.name == "plain.txt" })?.isSymlink == false)
    await client.close()
}
