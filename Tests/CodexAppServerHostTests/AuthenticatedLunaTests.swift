#if os(macOS)
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerHost

/// Opt-in release smoke test on the isolated stdio transport used by the quick start.
@Test(.timeLimit(.minutes(3))) func authenticatedLunaIsolatedTurnCompletes() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_CODEX_LIVE_TESTS"] == "1" else { return }
    guard let model = environment["CODEX_LUNA_MODEL"], model.lowercased().contains("luna") else {
        Issue.record("CODEX_LUNA_MODEL must explicitly name a Luna model"); return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = CodexClient(transportFactory: CodexHostTransports.isolated(executableURL: try CodexCLIResolver().resolve()))
    do {
        _ = try await client.connect()
        let thread = try await client.startThread(options: .init(model: model, workingDirectory: directory, ephemeral: true))
        let subscription = try await client.events(for: thread.id, policy: .unbounded)
        let turn = try await client.startTurn(threadID: thread.id, prompt: "Reply with exactly SDK_LUNA_OK. Do not use tools.", options: .init(model: model))
        var reply: String?
        var completed = false
        for try await event in subscription.events {
            switch event {
            case .itemCompleted(_, let item) where item.kind == .agentMessage:
                reply = item.raw["text"]?.stringValue
            case .turnCompleted(_, let finished) where finished.id == turn.id:
                #expect(finished.statusValue == .completed)
                completed = true
            default: break
            }
            if completed { break }
        }
        subscription.cancel()
        #expect(completed)
        #expect(reply?.contains("SDK_LUNA_OK") == true)
    } catch {
        await client.close()
        throw error
    }
    await client.close()
}

/// Compatibility check for CLI versions whose managed proxy accepts newline JSON.
@Test func authenticatedLunaTwoClientSharedTask() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_CODEX_MANAGED_TESTS"] == "1" else { return }
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
    let events = try await second.events(for: thread.id, policy: .unbounded)
    let turn = try await first.startTurn(threadID: thread.id, prompt: "Reply with exactly OK.", options: .init(model: model))
    var iterator = events.events.makeAsyncIterator(), observed = false
    for _ in 0..<500 {
        if let event = try await iterator.next(), case .turnStarted(_, let remoteTurn) = event, remoteTurn.id == turn.id { observed = true; break }
    }
    #expect(observed)
    await first.close(); await second.close()
}
#endif
