#if os(macOS)
import ArgumentParser
import Foundation
import Testing
@testable import CodexAppServerCLI
@testable import CodexAppServerKit
import CodexAppServerRemote

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
#endif
