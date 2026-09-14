import Foundation
import Testing
import CodexAppServerKit
@testable import CodexAppServerRemoteExperimental

// The WHAM surface talks to a private, undocumented service, so these tests cover only the
// parts that are decidable offline: payload parsing, identity validation, and the sequence
// cursor that suppresses replayed frames.

// MARK: - WHAMPairingCode

@Test(arguments: [
    ("codex://pair?code=123456", "123456"),
    ("codex://pair?pairing_code=223456", "223456"),
    ("codex://pair?pairingCode=323456", "323456"),
])
func pairingCodeAcceptsEveryQueryAlias(payload: String, expected: String) throws {
    #expect(try WHAMPairingCode(qrPayload: payload).value == expected)
}

@Test func pairingCodeFallsBackToTheWholePayloadWhenNoQueryMatches() throws {
    // A plain code scanned from a screen rather than a URL.
    #expect(try WHAMPairingCode(qrPayload: "483920").value == "483920")
    // A URL carrying no recognised query item is treated the same way.
    #expect(try WHAMPairingCode(qrPayload: "codex://pair?other=1").value == "codex://pair?other=1")
}

@Test func pairingCodeTrimsSurroundingWhitespace() throws {
    #expect(try WHAMPairingCode("  123456 \n").value == "123456")
}

@Test(arguments: ["", "   ", "\n\t"])
func pairingCodeRejectsBlankInput(payload: String) {
    #expect(throws: CodexError.self) { try WHAMPairingCode(payload) }
}

// MARK: - WHAMHost identity

@Test(arguments: [
    (JSONValue.object(["serverId": "s", "hostId": "h", "id": "i"]), "s"),
    (JSONValue.object(["hostId": "h", "id": "i"]), "h"),
    (JSONValue.object(["id": "i"]), "i"),
])
func hostIdentityPrefersServerIDThenHostIDThenID(raw: JSONValue, expected: String) throws {
    #expect(try WHAMHost(raw: raw).id == expected)
}

@Test func hostWithoutAnyIdentityIsRejected() {
    // An empty-id host is unusable: it would look up a grant for "" and revoke a malformed path.
    #expect(throws: CodexError.missingField("host.serverId|hostId|id")) {
        try WHAMHost(raw: ["name": "nameless"])
    }
}

@Test func hostCarriesNameAndOnlineFlag() throws {
    let host = try WHAMHost(raw: ["serverId": "s", "name": "Studio", "online": true])
    #expect(host.name == "Studio")
    #expect(host.online == true)
}

// MARK: - WHAMPairingGrant

@Test func pairingGrantRoundTripsThroughCodable() throws {
    let grant = WHAMPairingGrant(hostID: "host-1", environmentID: "env-1", grant: "secret")
    let decoded = try JSONDecoder().decode(WHAMPairingGrant.self, from: JSONEncoder().encode(grant))
    #expect(decoded == grant)
    #expect(decoded.id == "host-1", "Identifiable must key on the host")
}

// MARK: - WHAMEndpoints

@Test func endpointDefaultsMatchTheControllerContract() {
    let endpoints = WHAMEndpoints()
    #expect(endpoints.claimPath == "controller/pair")
    #expect(endpoints.hostsPath == "controller/servers")
    #expect(endpoints.controllerWebSocketPath == "controller")
    #expect(endpoints.revokePath("host-1") == "controller/pairing/host-1")
}

@Test func endpointsAreFullyInjectableForTesting() {
    let endpoints = WHAMEndpoints(baseURL: URL(string: "http://127.0.0.1:9999")!, claimPath: "pair", hostsPath: "hosts", revokePath: { "revoke/\($0)" }, controllerWebSocketPath: "ws")
    #expect(endpoints.baseURL.absoluteString == "http://127.0.0.1:9999")
    #expect(endpoints.revokePath("x") == "revoke/x")
}

// MARK: - WHAMCursor: duplicate and replay suppression

@Test func cursorAcceptsStrictlyIncreasingSequenceIDs() async {
    let cursor = WHAMCursor()
    #expect(await cursor.accept(1))
    #expect(await cursor.accept(2))
    #expect(await cursor.accept(100))
    #expect(await cursor.current() == 100)
}

@Test func cursorRejectsReplayedAndOutOfOrderFrames() async {
    let cursor = WHAMCursor()
    #expect(await cursor.accept(5))
    #expect(await cursor.accept(5) == false, "a duplicate must be suppressed")
    #expect(await cursor.accept(4) == false, "an out-of-order frame must be suppressed")
    #expect(await cursor.current() == 5, "a rejected frame must not move the cursor")
}

@Test func cursorStartsAtZeroAndRejectsNonPositiveSequenceIDs() async {
    let cursor = WHAMCursor()
    #expect(await cursor.current() == 0)
    #expect(await cursor.accept(0) == false)
    #expect(await cursor.accept(-1) == false)
}

// MARK: - Grant-store gating

private actor EmptyGrantStore: WHAMPairingGrantStore {
    func grant(for hostID: String) async throws -> WHAMPairingGrant? { nil }
    func save(_ grant: WHAMPairingGrant) async throws {}
    func remove(hostID: String) async throws {}
}

private struct StaticCredentials: WHAMCredentialProvider {
    func accountBearer() async throws -> String { "test-bearer" }
}

@Test func transportFactoryFailsBeforeAnyNetworkUseWhenNoGrantIsStored() async throws {
    let controller = WHAMController(credentials: StaticCredentials(), grantStore: EmptyGrantStore())
    let factory = await controller.transportFactory(hostID: "unknown-host")
    await #expect(throws: CodexError.self) { _ = try await factory.makeTransport() }
}
