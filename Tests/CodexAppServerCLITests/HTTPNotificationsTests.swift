#if os(macOS)
import Foundation
import Testing
@testable import CodexAppServerCLI
@testable import CodexAppServerKit

private func decodeConfiguration(_ source: String, environment: [String: String] = [:]) throws -> CLINotificationConfiguration {
    try CLINotificationConfiguration.decode(Data(source.utf8), environment: environment)
}

private func context(_ overrides: [String: String] = [:]) -> CLINotificationContext {
    let base = Dictionary(uniqueKeysWithValues: CLINotificationConfiguration.supportedPlaceholders.map { ($0, "") })
    return .init(values: base.merging(overrides) { _, replacement in replacement })
}

private final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

private actor SuspendedSender {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func send(_ request: URLRequest) async -> URLResponse {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    func release() { continuation?.resume(); continuation = nil }
}

@Test func notificationConfigurationDefaultsAndEnvironmentExpansion() throws {
    let configuration = try decodeConfiguration(
        #"{"url":"${BASE}/notify/{{event}}","headers":{"Authorization":"Bearer ${TOKEN}"},"body":{"secret":"${TOKEN}","event":"{{event}}"}}"#,
        environment: ["BASE": "https://example.test", "TOKEN": "private-token"]
    )
    #expect(configuration.method == "GET")
    #expect(configuration.timeoutSeconds == 10)
    #expect(configuration.headers["Authorization"] == "Bearer private-token")
    #expect(configuration.body?["secret"]?.stringValue == "private-token")

    let request = try configuration.request(for: context(["event": "turn completed/now"]))
    #expect(request.url?.absoluteString == "https://example.test/notify/turn%20completed%2Fnow")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONValue.decode(request.httpBody ?? Data())
    #expect(body["event"]?.stringValue == "turn completed/now")
}

@Test func relativeNotificationConfigurationPathsUseLaunchDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"url":"https://example.test/{{event}}"}"#.utf8).write(to: directory.appendingPathComponent("notify.json"))
    let configuration = try CLINotificationConfiguration.load(path: "notify.json", workingDirectory: directory, environment: [:])
    #expect(configuration.urlTemplate == "https://example.test/{{event}}")
}

@Test func notificationConfigurationRendersHeadersAndNestedJSON() throws {
    let configuration = try decodeConfiguration(#"""
    {
      "url":"https://example.test/hook?summary={{summary}}",
      "method":"post",
      "headers":{"X-Codex-Event":"{{event}}","content-type":"application/vnd.test+json"},
      "body":{"nested":["{{summary}}",7,true,null]},
      "timeoutSeconds":1.5
    }
    """#)
    let request = try configuration.request(for: context(["event": "awaiting_input", "summary": "quote \" and\nemoji 🧭"]))
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 1.5)
    #expect(request.value(forHTTPHeaderField: "X-Codex-Event") == "awaiting_input")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.test+json")
    #expect(request.url?.absoluteString == "https://example.test/hook?summary=quote%20%22%20and%0Aemoji%20%F0%9F%A7%AD")
    let body = try JSONValue.decode(request.httpBody ?? Data())
    #expect(body["nested"]?[0]?.stringValue == "quote \" and\nemoji 🧭")
    #expect(body["nested"]?[1]?.intValue == 7)
    #expect(body["nested"]?[2]?.boolValue == true)
    #expect(body["nested"]?[3] == JSONValue.null)
}

@Test(arguments: [
    #"{}"#,
    #"{"url":"ftp://example.test"}"#,
    #"{"url":"https://example.test","method":"bad method"}"#,
    #"{"url":"https://example.test","timeoutSeconds":0}"#,
    #"{"url":"https://example.test","timeoutSeconds":61}"#,
    #"{"url":"https://example.test/{{future}}"}"#,
    #"{"url":"https://example.test","headers":{"Bad Header":"x"}}"#,
    #"{"url":"https://example.test","headers":{"X-Test":"bad\u0000value"}}"#,
    #"{"url":"https://example.test","unexpected":true}"#,
])
func invalidNotificationConfigurationsAreRejected(source: String) {
    #expect(throws: CodexError.self) { try decodeConfiguration(source) }
}

@Test func missingEnvironmentAndSecretValuesAreNotDisclosed() {
    #expect(throws: CodexError.self) {
        try decodeConfiguration(#"{"url":"${MISSING}"}"#)
    }
    let secret = "do-not-print-this\nsecond-line"
    do {
        _ = try decodeConfiguration(
            #"{"url":"https://example.test","headers":{"Authorization":"${TOKEN}"}}"#,
            environment: ["TOKEN": secret]
        )
        Issue.record("Expected invalid header value")
    } catch {
        #expect(!error.localizedDescription.contains("do-not-print-this"))
    }
}

@Test func notificationArgumentValidation() throws {
    #expect(try CodexAppServerCLI.notificationConfigurationPath(in: ["--daemon"]) == nil)
    #expect(try CodexAppServerCLI.notificationConfigurationPath(in: ["--daemon", "--notify-config", "notify.json"]) == "notify.json")
    #expect(throws: CodexError.self) { try CodexAppServerCLI.notificationConfigurationPath(in: ["--notify-config"]) }
    #expect(throws: CodexError.self) { try CodexAppServerCLI.notificationConfigurationPath(in: ["--notify-config", ""]) }
    #expect(throws: CodexError.self) { try CodexAppServerCLI.notificationConfigurationPath(in: ["--notify-config", "a", "--notify-config", "b"]) }
    #expect(try CodexAppServerCLI.notificationConfigurationPath(in: ["status", "--notify-config", "notify.json"]) == "notify.json")
}

@Test(arguments: [
    ("completed", "turn_completed"),
    ("failed", "turn_failed"),
    ("interrupted", "turn_interrupted"),
    ("future", "turn_ended"),
])
func terminalTurnsMapToStableEvents(status: String, expectedEvent: String) throws {
    let turn = try CodexTurn(threadID: "thread", raw: [
        "id": "turn", "status": .string(status),
        "items": [["id": "one", "type": "agentMessage", "text": "older"], ["id": "two", "type": "agentMessage", "text": " final\nanswer "]],
        "error": ["message": "failure"],
    ])
    let result = CLINotificationContext.makeTurn(threadID: nil, turn: turn, timestamp: "time")
    #expect(result.values["event"] == expectedEvent)
    #expect(result.values["thread_id"] == "thread")
    #expect(result.values["turn_id"] == "turn")
    #expect(result.values["status"] == status)
    #expect(result.values["summary"] == "final answer")
}

@Test func turnSummaryFallsBackAndIsCapped() throws {
    let failed = try CodexTurn(threadID: "t", raw: ["id": "u", "status": "failed", "items": [], "error": ["message": "  network\nfailed  "]])
    #expect(CLINotificationContext.makeTurn(threadID: nil, turn: failed, timestamp: "time").values["summary"] == "network failed")
    let longText = String(repeating: "🧭 ", count: 600)
    let completed = try CodexTurn(threadID: "t", raw: ["id": "u", "status": "completed", "items": [["type": "agentMessage", "text": .string(longText)]]])
    let summary = CLINotificationContext.makeTurn(threadID: nil, turn: completed, timestamp: "time").values["summary"] ?? ""
    #expect(summary.count == 500)
}

@Test func everyInteractionKindMapsAndSummaryUsesDocumentedPrecedence() {
    let cases: [(CodexInteractionKind, String)] = [
        (.commandApproval, "command_approval"), (.networkApproval, "network_approval"),
        (.fileChangeApproval, "file_change_approval"), (.permissionApproval, "permission_approval"),
        (.userInput, "user_input"), (.mcpForm, "mcp_form"), (.openAIForm, "openai_form"),
        (.urlElicitation, "url_elicitation"), (.unknown("future/approval"), "unknown"),
    ]
    for (kind, expected) in cases {
        let result = CLINotificationContext.makeInteraction(
            id: "request", method: kind == .unknown("future/approval") ? "future/approval" : "method",
            kind: kind, threadID: "thread", turnID: "turn", itemID: "item",
            questions: [" First question ", "Second\nquestion"], raw: ["reason": "reason", "command": "command", "serverName": "server"], timestamp: "time"
        )
        #expect(result.values["event"] == "awaiting_input")
        #expect(result.values["interaction_kind"] == expected)
        #expect(result.values["summary"] == "First question / Second question")
        #expect(result.values["request_id"] == "request")
    }

    let reason = CLINotificationContext.makeInteraction(
        id: "r", method: "method", kind: .commandApproval, threadID: nil, turnID: nil, itemID: nil,
        questions: [], raw: ["reason": "because", "command": "ignored"], timestamp: "time"
    )
    #expect(reason.values["summary"] == "because")
    #expect(reason.values["thread_id"] == "")
    let command = CLINotificationContext.makeInteraction(
        id: "r", method: "method", kind: .commandApproval, threadID: nil, turnID: nil, itemID: nil,
        questions: [], raw: ["reason": "", "command": "run this"], timestamp: "time"
    )
    #expect(command.values["summary"] == "run this")
}

@Test func unrelatedEventsDoNotProduceContexts() throws {
    #expect(CLINotificationContext.make(for: .itemCompleted(threadID: "t", item: try .init(raw: ["id": "i"])), timestamp: "time") == nil)
    #expect(CLINotificationContext.make(for: .dynamicToolCompleted(name: "tool", callID: "call", success: true), timestamp: "time") == nil)
    #expect(CLINotificationContext.make(for: .threadStateUpdated(threadID: "t", state: .init()), timestamp: "time") == nil)
}

@Test func serverRequestEventsProduceAwaitingInputContexts() {
    let client = CodexClient(transportFactory: .init { throw CodexError.disconnected })
    let response = CodexInteractionResponseHandle(client: client, requestID: 17, generation: 1)
    let interaction = CodexPendingInteraction(
        id: "17", requestID: 17, method: "item/tool/requestUserInput", kind: .userInput, generation: 1,
        threadID: "thread", turnID: "turn", itemID: "item", choices: [],
        questions: [.init(id: "question", header: "Choice", question: "Pick one", choices: [], raw: [:])],
        raw: ["questions": []], response: response
    )
    let result = CLINotificationContext.make(for: .serverRequest(interaction), timestamp: "time")
    #expect(result?.values["event"] == "awaiting_input")
    #expect(result?.values["summary"] == "Pick one")

    let systemRequest = CodexPendingInteraction(
        id: "18", requestID: 18, method: "currentTime/read", kind: .unknown("currentTime/read"), generation: 1,
        threadID: "thread", turnID: nil, itemID: nil, choices: [], questions: [], raw: [:], response: response
    )
    #expect(CLINotificationContext.make(for: .serverRequest(systemRequest), timestamp: "time") == nil)

    let legacyApproval = CodexPendingInteraction(
        id: "19", requestID: 19, method: "execCommandApproval", kind: .unknown("execCommandApproval"), generation: 1,
        threadID: "thread", turnID: "turn", itemID: "item", choices: [], questions: [], raw: ["command": "echo hi"], response: response
    )
    let legacyResult = CLINotificationContext.make(for: .serverRequest(legacyApproval), timestamp: "time")
    #expect(legacyResult?.values["interaction_kind"] == "command_approval")
}

@Test func dispatcherSendsMatchingEventsAndTreatsTwoHundredsAsSuccess() async throws {
    actor Recorder {
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) -> URLResponse {
            requests.append(request)
            return HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        }
    }
    let recorder = Recorder(), messages = LockedMessages()
    let configuration = try decodeConfiguration(#"{"url":"https://example.test/{{event}}","method":"POST","body":{"summary":"{{summary}}"}}"#)
    let dispatcher = CLINotificationDispatcher(
        configuration: configuration,
        sender: { request in await recorder.send(request) },
        report: { messages.append($0) }
    )
    let turn = try CodexTurn(threadID: "thread", raw: ["id": "turn", "status": "completed", "items": []])
    await dispatcher.enqueue(.turnCompleted(threadID: "thread", turn: turn))
    await dispatcher.enqueue(.itemCompleted(threadID: "thread", item: try .init(raw: ["id": "item"])))
    await dispatcher.finish()
    #expect(await recorder.requests.count == 1)
    #expect(messages.values.isEmpty)
}

@Test func dispatcherReportsSanitizedFailuresAndContinues() async throws {
    actor Counter {
        var value = 0
        func next(_ request: URLRequest) -> URLResponse {
            value += 1
            return HTTPURLResponse(url: request.url!, statusCode: value == 1 ? 503 : 200, httpVersion: nil, headerFields: nil)!
        }
    }
    let counter = Counter(), messages = LockedMessages()
    let configuration = try decodeConfiguration(
        #"{"url":"https://example.test/${TOKEN}/{{event}}","headers":{"Authorization":"${TOKEN}"}}"#,
        environment: ["TOKEN": "highly-secret"]
    )
    let dispatcher = CLINotificationDispatcher(
        configuration: configuration,
        sender: { request in await counter.next(request) },
        report: { messages.append($0) }
    )
    let first = try CodexTurn(threadID: "t", raw: ["id": "one", "status": "completed", "items": []])
    let second = try CodexTurn(threadID: "t", raw: ["id": "two", "status": "completed", "items": []])
    await dispatcher.enqueue(.turnCompleted(threadID: "t", turn: first))
    await dispatcher.enqueue(.turnCompleted(threadID: "t", turn: second))
    await dispatcher.finish()
    #expect(await counter.value == 2)
    #expect(messages.values.contains("request failed: HTTP 503"))
    #expect(!messages.values.joined().contains("highly-secret"))
}

@Test func dispatcherEnqueueDoesNotAwaitHTTPCompletion() async throws {
    let sender = SuspendedSender()
    let configuration = try decodeConfiguration(#"{"url":"https://example.test/{{event}}"}"#)
    let dispatcher = CLINotificationDispatcher(configuration: configuration, sender: { request in await sender.send(request) })
    let turn = try CodexTurn(threadID: "t", raw: ["id": "u", "status": "completed", "items": []])

    await dispatcher.enqueue(.turnCompleted(threadID: "t", turn: turn))
    while !(await sender.started) { await Task.yield() }
    #expect(await sender.started)
    await sender.release()
    await dispatcher.finish()
}
#endif
