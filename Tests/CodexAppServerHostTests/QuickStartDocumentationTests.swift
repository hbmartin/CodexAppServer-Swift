import Foundation
import CodexAppServerKit
import CodexAppServerHost

#if os(macOS)
// Kept in sync with README.md. The compiler checks this without starting a real Codex process.
private func quickStartDocumentationExample(projectURL: URL) async throws {
    let executable = try CodexCLIResolver().resolve()
    let factory = CodexHostTransports.isolated(executableURL: executable)
    let client = CodexClient(transportFactory: factory)
    try await client.connect()

    let task = try await client.startThread(
        options: .init(model: "gpt-5.6-luna", workingDirectory: projectURL)
    )
    let events = try await client.events(for: task.id, policy: .boundedCoalescingDeltas(1_024))
    let turn = try await client.startTurn(threadID: task.id, prompt: "Explain this project")
    _ = (events, turn)
}
#endif
