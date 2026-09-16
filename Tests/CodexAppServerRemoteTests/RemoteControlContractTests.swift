import Foundation
import Testing
import CodexAppServerKit
@testable import CodexAppServerRemote

@Test(arguments: [
    ("codex://pair?code=123456", "123456"),
    ("codex://pair?pairing_code=223456", "223456"),
    ("codex://pair?pairingCode=323456", "323456"),
    ("codex://pair?manual_pairing_code=423456", "423456"),
])
func remotePairingCodeAcceptsQueryAliases(payload: String, expected: String) throws {
    #expect(try CodexRemotePairingCode(qrPayload: payload).value == expected)
}

@Test func remotePairingCodeTrimsAndFallsBackToWholePayload() throws {
    #expect(try CodexRemotePairingCode(" 483920\n").value == "483920")
    #expect(try CodexRemotePairingCode(qrPayload: "codex://pair?other=1").value == "codex://pair?other=1")
    #expect(throws: CodexRemoteError.invalidConfiguration("pairing code must not be empty")) {
        try CodexRemotePairingCode(" \n")
    }
}

@Test(arguments: [
    (JSONValue.object(["env_id": "current", "environment_id": "legacy"]), "current"),
    (JSONValue.object(["environment_id": "snake", "environmentId": "camel"]), "snake"),
    (JSONValue.object(["environmentId": "camel"]), "camel"),
])
func remoteHostIdentityUsesCurrentFieldFirst(raw: JSONValue, expected: String) throws {
    #expect(try CodexRemoteHost(raw: raw).id == expected)
}

@Test func remoteHostExposesCurrentEnvironmentMetadata() throws {
    let host = try CodexRemoteHost(raw: [
        "env_id": "env-1", "display_name": "Display", "host_name": "Studio",
        "online": true, "busy": false, "client_type": "CODEX_DESKTOP",
        "app_server_version": "0.146.0",
    ])
    #expect(host.name == "Display")
    #expect(host.hostName == "Studio")
    #expect(host.online == true)
    #expect(host.busy == false)
    #expect(host.environmentID == "env-1")
}

@Test func remoteSensitiveValuesAreRedactedFromDescriptionsAndReflection() {
    let value = CodexRemoteSensitiveValue("remote-test-secret")
    #expect(String(describing: value) == "<redacted>")
    #expect(String(reflecting: value) == "<redacted>")
    #expect(value.withUnsafeValue { $0 } == "remote-test-secret")
}

@Test func remoteConfigurationRejectsCredentialExfiltrationTargets() throws {
    #expect(throws: CodexRemoteError.self) {
        try CodexRemoteConfiguration(baseURL: URL(string: "https://example.com/backend-api")!)
    }
    #expect(throws: CodexRemoteError.self) {
        try CodexRemoteConfiguration(baseURL: URL(string: "http://chatgpt.com/backend-api")!)
    }
    #expect(throws: CodexRemoteError.self) {
        try CodexRemoteConfiguration(baseURL: URL(string: "https://chatgpt.com.evil.test/backend-api")!)
    }
    #expect(try CodexRemoteConfiguration(baseURL: URL(string: "http://127.0.0.1:8080/backend-api")!).baseURL.host == "127.0.0.1")
}

private struct StaticRemoteCredentials: CodexRemoteCredentialProvider {
    var token = "test-token"
    var accountID = "account-1"
    func credential() async throws -> CodexRemoteCredential {
        try .init(accountID: accountID, accessToken: .init(token))
    }
}

private struct StaticRemoteAuthorization: CodexRemoteClientAuthorizationProvider {
    var accountID = "account-1"
    var clientID = "client-1"
    func authorization(for credential: CodexRemoteCredential, forceRefresh: Bool) async throws -> CodexRemoteClientAuthorization {
        try .init(accountID: accountID, clientID: clientID, sessionToken: .init("session-token"), requiresDeviceKeyProof: false)
    }
}

private final class RemoteMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var body: JSONValue? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(host: String, _ values: [String: [Reply]]) {
        lock.lock()
        for (path, repliesForPath) in values { replies[host + path] = repliesForPath }
        requests.removeAll { $0.url?.host == host }
        lock.unlock()
    }
    static func capturedRequests(host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.host == host }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".chatgpt-staging.com") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = (request.url?.host ?? "") + (request.url?.path ?? "")
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBodyStream = nil
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(captured)
        var queue = Self.replies[key] ?? []
        let reply = queue.isEmpty ? Reply(status: 404, body: ["detail": "not found"]) : queue.removeFirst()
        Self.replies[key] = queue
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = reply.body, let data = try? body.encoded() { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func remoteController(
    host: String,
    authorization: (any CodexRemoteClientAuthorizationProvider)? = StaticRemoteAuthorization(),
    attempts: Int = 1,
    diagnosticMode: CodexRemoteDiagnosticMode = .redacted
) throws -> CodexRemoteController {
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [RemoteMockURLProtocol.self]
    let configuration = try CodexRemoteConfiguration(
        baseURL: URL(string: "https://\(host)/backend-api")!,
        maximumReadAttempts: attempts,
        diagnosticMode: diagnosticMode
    )
    return .init(credentials: StaticRemoteCredentials(), authorizationProvider: authorization, configuration: configuration, sessionConfiguration: session)
}

@Test func remotePairUsesEnrolledClientAndCurrentRouteWithoutLeakingSessionToken() async throws {
    let host = "pair.chatgpt-staging.com"
    let path = "/backend-api/wham/remote/control/client/pair"
    RemoteMockURLProtocol.reset(host: host, [path: [.init(status: 200, body: ["env_id": "env-1"])]] )
    let result = try await remoteController(host: host).pair(.init("123456"))
    #expect(result.clientID == "client-1")
    #expect(result.environmentID == "env-1")

    let request = try #require(RemoteMockURLProtocol.capturedRequests(host: host).first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
    #expect(request.value(forHTTPHeaderField: "x-codex-client-session-token") == nil)
    #expect(request.httpMethod == "POST")
    let body = try JSONValue.decode(try #require(request.httpBody))
    #expect(body == ["client_id": "client-1", "manual_pairing_code": "123456"])
}

@Test func remoteHostListPaginatesAndDiagnosesMalformedEntries() async throws {
    let host = "hosts.chatgpt-staging.com"
    let path = "/backend-api/codex/remote/control/environments"
    RemoteMockURLProtocol.reset(host: host, [path: [
        .init(status: 200, body: ["items": [
            ["env_id": "env-1", "display_name": "Studio", "online": true],
            ["display_name": "missing identity"],
        ], "cursor": "next"]),
        .init(status: 200, body: ["items": [["env_id": "env-2", "host_name": "Laptop", "online": false]], "cursor": .null]),
    ]])
    let result = try await remoteController(host: host, diagnosticMode: .full).listHosts()
    #expect(result.hosts.map(\.id) == ["env-1", "env-2"])
    #expect(result.diagnostics.count == 1)
    #expect(result.diagnostics.first?.entryIndex == 1)
    #expect(result.diagnostics.first?.raw?["display_name"] == "missing identity")
    let requests = RemoteMockURLProtocol.capturedRequests(host: host)
    #expect(requests.count == 2)
    #expect(requests[0].url?.query == "limit=100")
    #expect(Set(URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems ?? []) == Set([.init(name: "limit", value: "100"), .init(name: "cursor", value: "next")]))
}

@Test func remoteSafeReadsRetryTransientFailuresButPairDoesNot() async throws {
    let host = "retry.chatgpt-staging.com"
    let hostsPath = "/backend-api/codex/remote/control/environments"
    RemoteMockURLProtocol.reset(host: host, [hostsPath: [
        .init(status: 503, body: ["detail": "retry"]),
        .init(status: 200, body: ["items": [], "cursor": .null]),
    ]])
    let controller = try remoteController(host: host, attempts: 2)
    #expect(try await controller.listHosts().hosts.isEmpty)
    #expect(RemoteMockURLProtocol.capturedRequests(host: host).count == 2)

    let pairPath = "/backend-api/wham/remote/control/client/pair"
    RemoteMockURLProtocol.reset(host: host, [pairPath: [
        .init(status: 503, body: ["detail": "do not retry mutation"]),
        .init(status: 200, body: ["env_id": "unexpected"]),
    ]])
    await #expect(throws: CodexRemoteError.self) { try await controller.pair(.init("123")) }
    #expect(RemoteMockURLProtocol.capturedRequests(host: host).count == 1)
}

@Test func remoteSafeReadRereadsCredentialsOnceAfterUnauthorizedResponse() async throws {
    let host = "reauth.chatgpt-staging.com"
    let path = "/backend-api/codex/remote/control/environments"
    RemoteMockURLProtocol.reset(host: host, [path: [
        .init(status: 401, body: ["detail": "expired"]),
        .init(status: 200, body: ["items": [], "cursor": .null]),
    ]])
    let controller = try remoteController(host: host, attempts: 3)
    #expect(try await controller.listHosts().hosts.isEmpty)
    #expect(RemoteMockURLProtocol.capturedRequests(host: host).count == 2)
}

@Test func remotePairAndConnectRequireExplicitControllerAuthorization() async throws {
    let host = "unauthorized.chatgpt-staging.com"
    let controller = try remoteController(host: host, authorization: nil)
    await #expect(throws: CodexRemoteError.authorizationRequired("pairing and connections require controller enrollment, a client session, and device-key signing")) {
        try await controller.pair(.init("123"))
    }
    let factory = await controller.transportFactory(environmentID: "env-1")
    await #expect(throws: CodexRemoteError.self) { _ = try await factory.makeTransport() }
    #expect(RemoteMockURLProtocol.capturedRequests(host: host).isEmpty)
}

@Test func remoteAuthorizationMustMatchAccountBeforeConnectionIOMayStart() async throws {
    let host = "mismatch.chatgpt-staging.com"
    let controller = try remoteController(host: host, authorization: StaticRemoteAuthorization(accountID: "other-account"))
    let factory = await controller.transportFactory(environmentID: "env-1")
    await #expect(throws: CodexRemoteError.authorizationAccountMismatch(expected: "account-1", received: "other-account")) {
        _ = try await factory.makeTransport()
    }
}

@Test func remoteEnvironmentRemovalEncodesIdentityAsOnePathComponent() async throws {
    let host = "remove.chatgpt-staging.com"
    let encodedPath = "/backend-api/codex/remote/control/environments/env%2F..%2Fother"
    RemoteMockURLProtocol.reset(host: host, [encodedPath: [.init(status: 204, body: nil)]])
    let controller = try remoteController(host: host)
    try await controller.removeEnvironment(id: "env/../other")
    let request = try #require(RemoteMockURLProtocol.capturedRequests(host: host).first)
    #expect(request.url?.absoluteString.contains("env%2F..%2Fother") == true)
    #expect(request.httpMethod == "DELETE")
}
