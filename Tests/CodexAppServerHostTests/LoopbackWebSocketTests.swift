#if os(macOS)
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerHost

/// Controlled real-process transport test. It initializes app-server but never starts a model turn.
@Test func controlledLoopbackWebSocketProcess() async throws {
    guard ProcessInfo.processInfo.environment["RUN_CODEX_PROCESS_TESTS"] == "1" else { return }
    let executable = try CodexCLIResolver().resolve()
    let port = Int(ProcessInfo.processInfo.environment["CODEX_TEST_WS_PORT"] ?? "45432")!
    let server = try CodexLoopbackWebSocketServer(executableURL: executable, port: port)
    let client = CodexClient(transportFactory: try await server.transportFactory())
    _ = try await client.connect(); #expect(await server.isRunning())
    _ = try await client.listThreads(.init(limit: 1))
    await client.close(); await server.stop()
}
#endif
