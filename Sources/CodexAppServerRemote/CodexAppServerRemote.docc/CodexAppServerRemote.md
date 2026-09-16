# ``CodexAppServerRemote``

Discover and connect to Codex app-server environments through Remote Control.

## Overview

``CodexRemoteController`` uses account credentials for environment discovery. Pairing and WebSocket connections also require a device-bound ``CodexRemoteClientAuthorizationProvider``. This separation reflects the service contract: a normal account token does not enroll a controller and cannot replace the short-lived controller session or device-key proof.

```swift
let credentials = try CodexRemoteCodexLoginCredentialProvider()
let controller = CodexRemoteController(
    credentials: credentials,
    authorizationProvider: applicationAuthorizationProvider
)

// Obtain the short-lived manual code from `codex remote-control pair` on the host.
_ = try await controller.pair(try CodexRemotePairingCode(qrPayload: pairingCode))
let listing = try await controller.listHosts()
guard let environment = listing.hosts.first(where: { $0.online == true }) else { return }

let session = try await controller.connect(environmentID: environment.id)
let tasks = try await session.client.listThreads(.init(limit: 20))
await session.close()
```

The authorization provider owns interactive step-up enrollment, protected device-key persistence, controller-session refresh, and challenge signing. ``CodexRemoteClosureAuthorizationProvider`` adapts application services expressed as `Sendable` async closures. The SDK validates challenge purpose, audience, identities, target, token hash, expiration, and scopes before calling the signer.

The supported API contains no public WHAM names. The hidden manual-pair route and the Remote Control WebSocket protocol can change independently of the app-server JSON-RPC schema. Environment discovery is a safe read with bounded retry. Pairing, environment removal, and client revocation are mutations and are never retried because a transport failure can leave their result ambiguous.

Protocol-v3 transports use a fresh stream identity and sequence space for each connection. They preserve send order under bounded backpressure, segment large outbound messages, bound and reassemble inbound segments, suppress duplicates, and fail on sequence gaps or identity mismatches.

``CodexRemoteSensitiveValue`` redacts normal descriptions, debug descriptions, and reflection. Read its underlying value only at a credential boundary. The default login provider rereads the Codex login file for every credential request so refreshed sessions are picked up.

## Topics

### Controller

- ``CodexRemoteController``
- ``CodexRemotePairingCode``
- ``CodexRemotePairingResult``
- ``CodexRemoteHost``
- ``CodexRemoteHostListing``
- ``CodexRemoteSession``

### Credentials and authorization

- ``CodexRemoteCredential``
- ``CodexRemoteCredentialProvider``
- ``CodexRemoteCodexLoginCredentialProvider``
- ``CodexRemoteClientAuthorization``
- ``CodexRemoteClientAuthorizationProvider``
- ``CodexRemoteClosureAuthorizationProvider``
- ``CodexRemoteSensitiveValue``

### Configuration and diagnostics

- ``CodexRemoteConfiguration``
- ``CodexRemoteDiagnostic``
- ``CodexRemoteDiagnosticMode``
- ``CodexRemoteError``
