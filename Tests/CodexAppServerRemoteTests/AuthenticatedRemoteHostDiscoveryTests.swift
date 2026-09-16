#if os(macOS)
import Foundation
import Testing
import CodexAppServerRemote

/// Production smoke test for the account-authenticated half of Remote Control.
///
/// Controller enrollment requires an interactive step-up token and protected device-key signing,
/// so the deterministic loopback tests cover pairing, challenge signing, and app-server transport.
/// This opt-in test verifies the production route, authentication headers, response schema, and
/// visibility of the host started by Scripts/run-remote-control-live-tests.sh.
@Test func authenticatedRemoteControlHostDiscovery() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_CODEX_REMOTE_LIVE_TESTS"] == "1" else { return }
    let controller = try CodexRemoteController.codexLogin()
    let expected = environment["CODEX_REMOTE_EXPECTED_ENVIRONMENT_ID"]
    var latest: CodexRemoteHostListing?
    var lastError: Error?
    for attempt in 0..<40 {
        do {
            let listing = try await controller.listHosts()
            latest = listing
            let found = if let expected, !expected.isEmpty {
                listing.hosts.contains { $0.id == expected && $0.online == true }
            } else {
                listing.hosts.contains { $0.online == true }
            }
            if found {
                #expect(listing.diagnostics.isEmpty)
                return
            }
        } catch {
            lastError = error
        }
        if attempt < 39 { try await Task.sleep(for: .milliseconds(500)) }
    }
    if let lastError { throw lastError }
    throw CodexRemoteError.malformedResponse("the live Remote Control environment did not become visible and online; latest hosts: \(latest?.hosts.map(\.id) ?? [])")
}
#endif
