import Foundation
import Testing
import CodexAppServerKit

private struct ExampleBearer: CodexBearerCredentialProvider {
    func credential() async throws -> CodexBearerCredential { .init(value: "application-layer-placeholder", kind: .capability) }
}
private struct ExampleTunnel: CodexTunnelHeaderProvider {
    func headers() async throws -> [String: String] { ["X-Private-Network-Identity": "tunnel-layer-placeholder"] }
}

@Test func iOSWSSDocumentationExampleCompiles() throws {
    let configuration = try CodexWebSocketConfiguration(wssURL: URL(string: "wss://codex.example.com")!, applicationBearer: ExampleBearer(), tunnelHeaders: ExampleTunnel())
    _ = CodexClient(transportFactory: CodexWebSocketTransport.factory(configuration: configuration))
}
