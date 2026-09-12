# Codex App Server Swift SDK

`CodexAppServerSDK` 0.2.0 is a Swift 6.2 SDK for building interactive Codex clients on macOS 15+ and iOS 26+. It speaks the Codex app-server protocol directly: tasks (protocol “threads”), turns, streamed items, approvals, questions, tools, reconnect recovery, and raw forward-compatible messages.

This is a clean break from the former `CodexAppSDK` API. Source compatibility is promised for public APIs across 0.2.x patch releases, excluding `CodexAppServerRemoteExperimental`.

## Products

- `CodexAppServerKit` — transport protocol, actor RPC engine, typed operations, WSS, event reduction, interactions, dynamic tools, media, read-only filesystem helpers, and `client.raw`.
- `CodexAppServerHost` — macOS-only CLI discovery, daemon lifecycle, isolated stdio, SSH proxy, and SSH WebSocket forwarding.
- `CodexAppServerObservation` — main-actor `@Observable` models and equivalent Combine publishers. It intentionally has no views, navigation, persistence, host registry, or drafts.
- `CodexAppServerRemoteExperimental` — unsupported private WHAM controller research surface. It is never re-exported by the main SDK.
- `codex-app-server-cli` — an interactive, flag-driven reference client for macOS.

## Installation and first connection

Add this package in Xcode, then link only the products your app needs. The SDK requires a user-installed and authenticated Codex CLI 0.146.0 or newer on hosts. It never installs, updates, or signs into Codex.

```swift
import CodexAppServerKit
import CodexAppServerHost

let executable = try CodexCLIResolver().resolve()
let factory = CodexHostTransports.isolated(executableURL: executable)
let client = CodexClient(transportFactory: factory)
try await client.connect()

let task = try await client.startThread(
    options: .init(model: "gpt-5.6-luna", workingDirectory: projectURL)
)
let events = await client.events(for: task.id, policy: .boundedCoalescingDeltas(1_024))
let turn = try await client.startTurn(threadID: task.id, prompt: "Explain this project")
```

Each `subscribe()` or `events(for:)` call creates an independent multicast subscription. The default buffer is 1,024 events and fails only the slow subscriber. Delta-coalescing and unbounded policies are explicit alternatives.

## Lifecycle and durable local tasks

Isolated stdio intentionally creates an independent app-server. To let multiple controllers—including your app on another Mac—share live turns and approvals, bootstrap and reuse one managed daemon:

```swift
let daemon = CodexDaemonController(executableURL: executable)
try await daemon.prepareManagedDaemon() // explicit, one-time durable installation

let clientA = CodexClient(transportFactory: CodexHostTransports.managedDaemon(controller: daemon))
let clientB = CodexClient(transportFactory: CodexHostTransports.managedDaemon(controller: daemon))
try await clientA.connect()
try await clientB.connect()
```

`prepareManagedDaemon()` is the only API that bootstraps durable management. A managed connection starts an existing daemon when needed. Disconnecting a client never stops it. Lifecycle APIs include status, ensure-running, start, stop, restart, CLI version, and daemon version.

The client does not queue input while offline. Calls made while disconnected or reconnecting fail. It reconnects up to three times with jittered exponential delay capped at 30 seconds, reinitializes, resumes requested tasks, and refetches authoritative history. After exhaustion, the same client and task intents remain available to `reconnect()`.

If a question or approval was pending at disconnect and Codex does not replay it, state becomes `recoveryRequired`; the SDK never guesses, interrupts, approves, declines, or acts on `autoResolutionMs` locally.

## Interactive requests

Approvals, permission grants, multi-question input, MCP/OpenAI forms, and URL elicitations arrive as `CodexPendingInteraction`. Every response handle is one-shot and bound to the request ID, task, turn, item, and connection generation.

```swift
let subscription = await client.subscribe()
for try await event in subscription.events {
    guard case .serverRequest(let request) = event else { continue }
    switch request.kind {
    case .commandApproval:
        // Present request.choices and request.raw to your user first.
        try await request.response.respond(.decision("accept"))
    case .userInput:
        try await request.response.respond(.answers(["question-id": ["answer"]]))
    default:
        break
    }
}
```

You can install an optional async interaction handler with `setInteractionHandler`. Returning `nil` leaves the request pending. There is deliberately no auto-approval setting.

## Turns, state, and raw compatibility

Use `startTurn` and `steerTurn(expectedTurnID:)` explicitly. The SDK never reinterprets one as the other. Global and per-task events cover messages, plans, reasoning, command output, file changes, tools, reviews, usage-bearing raw fields, and unknown future notifications/items. `item/completed` replaces delta-derived state as authoritative.

Typed operations include task listing/search/filtering, archived and loaded listings, reads, resume, full/last-turn forks, pagination, rename, pin, archive, compact, turns, reviews, discovery, fuzzy file search, sandboxed command execution, and shell/background-terminal helpers. Permanent deletion, realtime voice, unsandboxed `process/*`, account/config/plugin administration, and filesystem writes remain raw-only or excluded.

Unsupported protocol additions remain reachable without waiting for an SDK release:

```swift
let value = try await client.raw.request(method: "future/method", params: ["x": 1])
```

Treat raw `process/*` as dangerous and unsandboxed.

## Dynamic tools, media, and files

Register typed async tools before starting a task. Registry changes affect newly started tasks, handlers are cancelled at disconnect, and registrations survive reconnects.

```swift
let registry = CodexDynamicToolRegistry(tools: [
    CodexDynamicTool(name: "lookup", description: "Look up an application record", inputSchema: ["type": "object"]) {
        .text("result for \($0)")
    }
])
```

`CodexMedia.image` and `.audio` accept client-device `Data` plus MIME type and encode a data URL. The default limit is 10 MiB. Host-local image/audio inputs use paths interpreted on the app-server host.

Read-only filesystem helpers require declared absolute task workspace roots. The SDK normalizes paths, rejects `..`, checks each path component the server reports as a symlink, and caps decoded file responses. App-server permissions remain the final authority. Protocol frames default to a 32 MiB cap.

## WSS and SSH security

Remote WSS requires two distinct layers:

1. Cloudflare Access, Tailscale/private-network identity, or equivalent tunnel headers.
2. A separate app-server application bearer (capability or signed bearer token).

```swift
let wss = try CodexWebSocketConfiguration(
    wssURL: URL(string: "wss://codex.example.com")!,
    applicationBearer: AppOwnedBearerProvider(),
    tunnelHeaders: AppOwnedTunnelIdentityProvider()
)
let client = CodexClient(transportFactory: CodexWebSocketTransport.factory(configuration: wss))
```

The SDK uses the platform TLS trust store and exposes no trust bypass, hostname bypass, pinning, Keychain, or saved-host registry. Providers are called again on reconnect for token refresh. With a dedicated app-server origin, app-server validates the bearer. With a WSS-to-Unix bridge, your bridge must validate it before forwarding.

Supported deployments are (a) the Unix daemon behind a caller-managed authenticated WSS-to-Unix bridge, or (b) a supervised loopback WebSocket listener reached locally, through WSS, or by SSH forwarding. The SDK does not install or configure Tailscale, Cloudflare Tunnel, DNS, certificates, or reverse proxies.

System SSH always uses `BatchMode=yes` and normal known-host enforcement. Pass an existing host alias or structured hostname/user/port/identity settings. Only a conservative allowlist of extra OpenSSH options is accepted.

## Experimental WHAM controller

`CodexAppServerRemoteExperimental` can parse PIN/QR payloads, claim pairings, list hosts, build controller transports, and revoke application-stored grants. It implements protocol-v2 sequence cursors, duplicate suppression, reconnect cursors, bounded sends, and ping handling. Production ChatGPT is the default endpoint; tests can inject another endpoint.

This uses private, undocumented service endpoints. Exact controller routes and envelopes may change without notice. It is unsupported, excluded from 0.2.x compatibility, and should be feature-gated. The SDK never stores grants or account tokens. Apps provide both credential and grant-storage protocols. On macOS, `WHAMCodexAuthFileCredentialProvider` is an explicit opt-in for a caller-selected file; there is no silent file probing, cookie extraction, or iOS auto-detection.

## Reference CLI

```text
codex-app-server-cli prepare
codex-app-server-cli status
codex-app-server-cli --isolated
codex-app-server-cli --daemon
codex-app-server-cli --ssh-proxy my-host-alias
codex-app-server-cli --ssh-forward my-host --local-port 4501 --remote-port 4500
codex-app-server-cli --wss wss://codex.example.com \
  --app-bearer-env CODEX_APP_BEARER \
  --tunnel-header CF-Access-Client-Secret \
  --tunnel-env CODEX_TUNNEL_SECRET
```

Secrets are accepted only through named environment/provider sources, never literal secret flags. The CLI stores no hosts.

## Logging, tests, and schema drift

Structured logging is silent by default and accepts an application sink. Payloads are redacted by default. Full-payload mode may include prompts, paths, commands, and output; credential-shaped fields remain redacted in all modes.

```sh
swift test
Scripts/check-schema-drift.sh
```

The reviewed CLI 0.146.0 snapshot is in `Schemas/0.146.0`. CI should regenerate it with the latest supported CLI and fail on differences, build macOS 15 and iOS 26, enforce Swift 6 concurrency, build DocC, and compare API compatibility with the latest 0.2.x tag.

Authenticated local tests are opt-in. Any test that starts a model turn must set an explicit Luna model and fails closed otherwise:

```sh
RUN_CODEX_LIVE_TESTS=1 CODEX_LUNA_MODEL=gpt-5.6-luna swift test --filter authenticatedLuna
```

Unit/build/schema tests do not invoke a model.

## License

MIT. See [LICENSE](LICENSE).
