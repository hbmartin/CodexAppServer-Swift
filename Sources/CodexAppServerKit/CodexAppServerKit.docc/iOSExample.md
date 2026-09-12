# iOS WSS example

An iOS app supplies credentials without giving the SDK persistence responsibility:

```swift
import CodexAppServerKit

struct Bearer: CodexBearerCredentialProvider {
    func credential() async throws -> CodexBearerCredential {
        .init(value: "value-from-app-secret-store", kind: .capability)
    }
}

struct Tunnel: CodexTunnelHeaderProvider {
    func headers() async throws -> [String: String] {
        ["X-Private-Network-Identity": "value-from-app"]
    }
}

let configuration = try CodexWebSocketConfiguration(
    wssURL: URL(string: "wss://codex.example.com")!,
    applicationBearer: Bearer(),
    tunnelHeaders: Tunnel()
)
let client = CodexClient(
    transportFactory: CodexWebSocketTransport.factory(configuration: configuration)
)
try await client.connect()
```

The example uses placeholders only. Production credentials belong in the app's own secure provider.
