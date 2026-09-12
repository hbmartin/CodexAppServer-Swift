#if os(macOS)
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerHost

/// Opt-in release smoke test. It refuses to start a turn with a non-Luna model.
@Test func authenticatedLunaTwoClientSharedTask() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_CODEX_LIVE_TESTS"] == "1" else { return }
    guard let model = environment["CODEX_LUNA_MODEL"], model.lowercased().contains("luna") else {
        Issue.record("CODEX_LUNA_MODEL must explicitly name a Luna model"); return
    }
    let executable = try CodexCLIResolver().resolve(), daemon = CodexDaemonController(executableURL: executable)
    try await daemon.prepareManagedDaemon()
    let factory = CodexHostTransports.managedDaemon(controller: daemon)
    let first = CodexClient(transportFactory: factory), second = CodexClient(transportFactory: factory)
    _ = try await first.connect(); _ = try await second.connect()
    let thread = try await first.startThread(options: .init(model: model))
    _ = try await second.subscribeThread(id: thread.id)
    let events = await second.events(for: thread.id, policy: .unbounded)
    let turn = try await first.startTurn(threadID: thread.id, prompt: "Reply with exactly OK.", options: .init(model: model))
    var iterator = events.events.makeAsyncIterator(), observed = false
    for _ in 0..<500 {
        if let event = try await iterator.next(), case .turnStarted(_, let remoteTurn) = event, remoteTurn.id == turn.id { observed = true; break }
    }
    #expect(observed)
    await first.close(); await second.close()
}
#endif
