#if os(macOS)
import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import CodexAppServerCLI
@testable import CodexAppServerKit
import CodexAppServerRemote

private actor CleanupTrackingTransport: CodexTransport {
    nonisolated let incomingFrames: AsyncThrowingStream<Data, Error>
    nonisolated let diagnostics: AsyncStream<CodexTransportDiagnostic>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let diagnosticContinuation: AsyncStream<CodexTransportDiagnostic>.Continuation
    private var closed = false

    init() {
        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        incomingFrames = frames.stream
        frameContinuation = frames.continuation
        let diagnostics = AsyncStream<CodexTransportDiagnostic>.makeStream()
        self.diagnostics = diagnostics.stream
        diagnosticContinuation = diagnostics.continuation
    }

    func start() {}
    func send(frame: Data) throws {
        let request = try JSONValue.decode(frame)
        guard request["method"] == "initialize", let id = request["id"] else { return }
        frameContinuation.yield(try JSONValue.object(["id": id, "result": ["serverInfo": ["name": "test", "version": "0.146.0"]]]).encoded())
    }
    func close() async {
        try? await Task.sleep(for: .milliseconds(50))
        closed = true
        frameContinuation.finish()
        diagnosticContinuation.finish()
    }
    func isClosed() -> Bool { closed }
}

@Test func commandTreeParsesEveryConnectionAndRemoteBranch() throws {
    #expect(try CodexAppServerCLI.parseAsRoot(["daemon", "status", "--json"]) is CodexAppServerCLI.Daemon.Status)
    #expect(try CodexAppServerCLI.parseAsRoot(["connect", "isolated", "--codex", "/tmp/codex"]) is CodexAppServerCLI.Connect.Isolated)
    #expect(try CodexAppServerCLI.parseAsRoot(["connect", "daemon"]) is CodexAppServerCLI.Connect.Managed)
    #expect(try CodexAppServerCLI.parseAsRoot(["connect", "ssh-proxy", "builder"]) is CodexAppServerCLI.Connect.SSHProxy)
    #expect(try CodexAppServerCLI.parseAsRoot(["connect", "ssh-forward", "builder", "--local-port", "9000", "--remote-port", "9001"]) is CodexAppServerCLI.Connect.SSHForward)
    #expect(try CodexAppServerCLI.parseAsRoot(["connect", "wss", "wss://example.test", "--app-bearer-env", "APP", "--tunnel-env", "TUNNEL", "--tunnel-header", "X-Tunnel"]) is CodexAppServerCLI.Connect.WSS)
    #expect(try CodexAppServerCLI.parseAsRoot(["remote", "pair", "123456", "--json"]) is CodexAppServerCLI.Remote.Pair)
    #expect(try CodexAppServerCLI.parseAsRoot(["remote", "hosts"]) is CodexAppServerCLI.Remote.Hosts)
    #expect(try CodexAppServerCLI.parseAsRoot(["remote", "connect", "env-1", "--authorization-helper", "/tmp/helper", "--json"]) is CodexAppServerCLI.Remote.Connect)
    #expect(try CodexAppServerCLI.parseAsRoot(["remote", "remove", "env-1"]) is CodexAppServerCLI.Remote.Remove)
    #expect(try CodexAppServerCLI.parseAsRoot(["remote", "revoke-client", "--authorization-helper", "/tmp/helper"]) is CodexAppServerCLI.Remote.RevokeClient)
}

@Test func machineCommandSchemaIsStrictAndVersioned() throws {
    let command = try CodexAppServerCLI.decodeMachineCommand(#"{"schemaVersion":1,"id":"request-1","command":"thread.list","arguments":{"limit":10}}"#)
    #expect(command == .init(id: "request-1", name: "thread.list", arguments: ["limit": 10]))
    #expect(throws: CodexError.invalidArgument("schemaVersion must be 1")) {
        try CodexAppServerCLI.decodeMachineCommand(#"{"schemaVersion":2,"id":"x","command":"thread.list"}"#)
    }
    #expect(throws: CodexError.invalidArgument("id must be a non-empty string")) {
        try CodexAppServerCLI.decodeMachineCommand(#"{"schemaVersion":1,"id":"","command":"thread.list"}"#)
    }
    #expect(throws: CodexError.invalidArgument("arguments must be an object")) {
        try CodexAppServerCLI.decodeMachineCommand(#"{"schemaVersion":1,"id":"x","command":"thread.list","arguments":[]}"#)
    }
}

@Test func remoteCredentialOptionsRejectPartialAndConflictingSources() {
    #expect(throws: (any Error).self) {
        try CodexAppServerCLI.parseAsRoot(["remote", "hosts", "--account-token-env", "TOKEN"])
    }
    #expect(throws: (any Error).self) {
        try CodexAppServerCLI.parseAsRoot(["remote", "hosts", "--account-token-env", "TOKEN", "--account-id-env", "ACCOUNT", "--auth-file", "/tmp/auth.json"])
    }
}

@Test func interactiveClientCleanupFinishesBeforeAnErrorReturns() async throws {
    let transport = CleanupTrackingTransport()
    let factory = CodexTransportFactory { transport }
    await #expect(throws: (any Error).self) {
        try await runInteractive(factory: factory, notificationPath: "/definitely/missing/notify.json", json: false)
    }
    #expect(await transport.isClosed())
}

@Test func remoteAuthorizationHelperUsesStdinJSONForAuthorizationAndChallengeProof() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("remote-helper.py")
    try #"""
#!/usr/bin/python3
import json, sys
value = json.load(sys.stdin)
assert len(sys.argv) == 2
assert value["schemaVersion"] == 1
assert value["action"] == sys.argv[1]
if sys.argv[1] == "authorize":
    assert value["accountAccessToken"] == "account-secret"
    print(json.dumps({"accountID": value["accountID"], "clientID": "helper-client", "sessionToken": "session-secret", "expiresAt": "2030-01-02T03:04:05.123Z", "requiresDeviceKeyProof": False}))
elif sys.argv[1] == "sign-challenge":
    assert "accountAccessToken" not in value
    assert value["challenge"]["nonce"] == "n"
    print(json.dumps({"proof": {"type": "device_key_proof", "keyId": "helper-key"}}))
else:
    raise SystemExit(2)
"""#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let helper = try RemoteAuthorizationHelper(path: script.path)
    let credential = try CodexRemoteCredential(accountID: "account-1", accessToken: .init("account-secret"))
    let authorization = try await helper.authorization(for: credential, forceRefresh: false)
    #expect(authorization.clientID == "helper-client")
    #expect(authorization.sessionToken.unsafeRawValue == "session-secret")
    #expect(authorization.expiresAt != nil)
    let proof = try await helper.response(to: ["nonce": "n"], using: authorization)
    #expect(proof == ["type": "device_key_proof", "keyId": "helper-key"])
}

@Test func remoteAuthorizationHelperDrainsLargeStderrWithoutBlocking() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try writeAuthorizationHelper(
        #"""
        #!/usr/bin/python3
        import json, sys
        sys.stderr.write("e" * 2000000)
        sys.stderr.flush()
        json.load(sys.stdin)
        print(json.dumps({"clientID":"client","sessionToken":"token","requiresDeviceKeyProof":False}))
        """#,
        in: directory
    )
    let helper = try RemoteAuthorizationHelper(path: script.path)
    let credential = try CodexRemoteCredential(accountID: "account", accessToken: .init(String(repeating: "s", count: 2_000_000)))
    #expect(try await helper.authorization(for: credential, forceRefresh: false).clientID == "client")
}

@Test func remoteAuthorizationHelperRejectsOversizedStdout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = try writeAuthorizationHelper(
        #"""
        #!/usr/bin/python3
        import sys, time
        sys.stdin.read()
        sys.stdout.write("x" * 1100000)
        sys.stdout.flush()
        time.sleep(10)
        """#,
        in: directory
    )
    let helper = try RemoteAuthorizationHelper(path: script.path)
    let credential = try CodexRemoteCredential(accountID: "account", accessToken: .init("secret"))
    await #expect(throws: CodexRemoteError.self) {
        _ = try await helper.authorization(for: credential, forceRefresh: false)
    }
}

@Test func remoteAuthorizationHelperTimesOutThenKillsAnUnresponsiveProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("timeout-pid")
    let script = try writeAuthorizationHelper(
        """
        #!/usr/bin/python3
        import os, signal, sys, time
        open(\"\(pidFile.path)\", \"w\").write(str(os.getpid()))
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
        """,
        in: directory
    )
    // Leave startup headroom when the full suite is concurrently spawning process transports.
    let helper = try RemoteAuthorizationHelper(path: script.path, timeout: .seconds(2))
    let credential = try CodexRemoteCredential(accountID: "account", accessToken: .init(String(repeating: "s", count: 2_000_000)))
    await #expect(throws: CodexRemoteError.self) {
        _ = try await helper.authorization(for: credential, forceRefresh: false)
    }
    let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8))!
    #expect(Darwin.kill(pid, 0) != 0)
}

@Test func remoteAuthorizationHelperCancellationCleansUpAndPropagates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("cancel-pid")
    let script = try writeAuthorizationHelper(
        """
        #!/usr/bin/python3
        import os, signal, sys, time
        open(\"\(pidFile.path)\", \"w\").write(str(os.getpid()))
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
        """,
        in: directory
    )
    let helper = try RemoteAuthorizationHelper(path: script.path)
    let credential = try CodexRemoteCredential(accountID: "account", accessToken: .init(String(repeating: "s", count: 2_000_000)))
    let task = Task { try await helper.authorization(for: credential, forceRefresh: false) }
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidFile.path) {
        try await Task.sleep(for: .milliseconds(2))
    }
    let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8))!
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Darwin.kill(pid, 0) != 0)
}

@Test func remoteAuthorizationHelperDoesNotWaitForInheritedOutputDescriptors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let childPIDFile = directory.appendingPathComponent("inherited-output-pid")
    let script = try writeAuthorizationHelper(
        """
        #!/usr/bin/python3
        import json, os, signal, sys, time
        json.load(sys.stdin)
        child = os.fork()
        if child == 0:
            open(\"\(childPIDFile.path)\", \"w\").write(str(os.getpid()))
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True: time.sleep(1)
        print(json.dumps({"clientID":"client","sessionToken":"token","requiresDeviceKeyProof":False}), flush=True)
        """,
        in: directory
    )
    var childPID: Int32?
    defer { if let childPID { _ = Darwin.kill(childPID, SIGKILL) } }
    let helper = try RemoteAuthorizationHelper(path: script.path, timeout: .seconds(2))
    let credential = try CodexRemoteCredential(accountID: "account", accessToken: .init("secret"))
    #expect(try await helper.authorization(for: credential, forceRefresh: false).clientID == "client")
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
        try await Task.sleep(for: .milliseconds(2))
    }
    childPID = try Int32(String(contentsOf: childPIDFile, encoding: .utf8))!
}

private func writeAuthorizationHelper(_ source: String, in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("authorization-helper.py")
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}
#endif
