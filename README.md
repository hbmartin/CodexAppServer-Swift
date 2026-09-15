# Codex App Server Swift SDK

`CodexAppServerSDK` 0.2.0 is a Swift 6.2 SDK for building interactive Codex clients on macOS 15+ and iOS 26+. It speaks the Codex app-server protocol directly: tasks (protocol “threads”), turns, streamed items, approvals, questions, tools, reconnect recovery, and raw forward-compatible messages.

This is a clean break from the former `CodexAppSDK` API. No release is tagged yet, so the public API is still moving. From the first `0.2.x` tag onward, source compatibility will be promised for public APIs across patch releases, excluding `CodexAppServerRemoteExperimental`; CI enforces that promise with `swift package diagnose-api-breaking-changes` against the latest tag.

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
let events = try await client.events(for: task.id, policy: .boundedCoalescingDeltas(1_024))
let turn = try await client.startTurn(threadID: task.id, prompt: "Explain this project")
```

Each `subscribe()` or `events(for:)` call creates an independent multicast subscription. Use `subscribe()` for all client events and `events(for:)` only for one specific task. The default buffer is 1,024 events and fails only the slow subscriber. Delta-coalescing and unbounded policies are explicit alternatives.

Coalescing preserves adjacent text fragments for the same item and segment. Incompatible events cause an explicit overflow failure rather than silent data loss. Each subscription supports one event iterator; call `cancel()` when its consumer finishes.

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

System SSH always uses `BatchMode=yes` and normal known-host enforcement. Pass an existing host alias or structured hostname/user/port/identity settings. Only a conservative allowlist of extra OpenSSH options is accepted. SSH forwarding requires OpenSSH 8.7 or newer, or a compatible client that supports `ForkAfterAuthentication`.

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
codex-app-server-cli --daemon --notify-config ./codex-notifications.json
codex-app-server-cli --wss wss://codex.example.com \
  --app-bearer-env CODEX_APP_BEARER \
  --tunnel-header CF-Access-Client-Secret \
  --tunnel-env CODEX_TUNNEL_SECRET
```

Secrets are accepted only through named environment/provider sources, never literal secret flags. The CLI stores no hosts.

### HTTP notifications

Interactive sessions can send best-effort HTTP notifications when a turn ends or Codex is waiting for a human response. Pass one JSON configuration with `--notify-config FILE`; lifecycle commands such as `status` and `restart` do not accept this option. Relative paths are resolved from the directory where the CLI was launched, and requests originate from that Mac.

```json
{
  "url": "https://hooks.example/notify?event={{event}}&thread={{thread_id}}",
  "method": "POST",
  "headers": {
    "Authorization": "Bearer ${CODEX_NOTIFY_TOKEN}"
  },
  "body": {
    "event": "{{event}}",
    "threadId": "{{thread_id}}",
    "turnId": "{{turn_id}}",
    "status": "{{status}}",
    "summary": "{{summary}}"
  },
  "timeoutSeconds": 10
}
```

`url` is required and must be an absolute HTTP or HTTPS URL. `method` defaults to `GET`, `headers` defaults to empty, and `timeoutSeconds` defaults to 10 and accepts values from 1 through 60. When `body` is present, it can be any JSON value; the CLI adds `Content-Type: application/json` unless the configuration supplies it.

Use `${NAME}` in the URL, header values, or JSON string values to load secrets from non-empty environment variables. Supported event placeholders are `{{event}}`, `{{timestamp}}`, `{{thread_id}}`, `{{turn_id}}`, `{{item_id}}`, `{{request_id}}`, `{{status}}`, `{{interaction_kind}}`, `{{interaction_method}}`, and `{{summary}}`. Values are percent-encoded in the URL and safely JSON-encoded in the body. `event` is one of `turn_completed`, `turn_failed`, `turn_interrupted`, `turn_ended`, or `awaiting_input`; absent values become empty strings.

Delivery does not block Codex event processing and is not retried. HTTP 2xx is considered successful. Other responses and transport failures produce a sanitized stderr message without printing the URL, headers, body, or resolved secrets, and do not stop the interactive session. The CLI waits for requests already in progress before exiting, subject to each request's configured timeout.

## Decoding and retries

Typed list methods retain valid entries and pagination cursors when individual entries are malformed. They report skipped entries through diagnostics; history replay uses the same policy. Diagnostics tied to a known thread also reach `events(for:)` subscribers. Whole-object reads still throw for invalid required fields. Empty identity arguments fail locally with `CodexError.invalidArgument` before a request is sent.

`startThread`, `forkThread`, `startTurn`, and `steerTurn` throw `CodexError.invalidMutationResponse` if the server acknowledges the operation but its result cannot be decoded. The error includes the method and raw response for reconciliation. The operation may already have taken effect: inspect the server's thread/turn state before deciding whether to retry. Timeouts, cancellation, and transport failures can also leave delivery uncertain. The SDK does not automatically retry these mutations.

Directory listings obtain each child's symlink flag using `fs/getMetadata`, since the pinned `fs/readDirectory` entry schema does not include it. This requires one additional metadata request per child.

## Logging, tests, and schema drift

Structured logging is silent by default and accepts an application sink. Payloads are redacted by default. Full-payload mode may include prompts, paths, commands, and output; credential-shaped fields remain redacted in all modes.

```sh
swift test
Scripts/check-sdk-schema-conformance.sh   # does the SDK still match the pinned snapshot?
Scripts/check-schema-drift.sh             # has upstream moved away from the snapshot?
```

The reviewed CLI 0.146.0 snapshot is in `Schemas/0.146.0`. CI regenerates it with the pinned CLI and fails on any difference, builds macOS 15 and iOS 26, enforces Swift 6 strict concurrency, builds DocC for every library target, and compares API compatibility against the latest 0.2.x tag. A weekly job additionally audits the snapshot against `codex@latest` as an early warning that upstream has moved.

`Scripts/check-sdk-schema-conformance.sh` checks the SDK against the pinned snapshot: every method the SDK sends must exist in `ClientRequest.json`, every notification method it routes must exist in `ServerNotification.json`, and `CodexItemKind` must still match the `ThreadItem` discriminator. An SDK case absent from the snapshot warns; a snapshot case missing from the SDK fails. Drift against a newer upstream schema is checked separately by `check-schema-drift.sh`.

Authenticated local tests are opt-in. Any test that starts a model turn must set an explicit Luna model and fails closed otherwise:

```sh
RUN_CODEX_LIVE_TESTS=1 CODEX_LUNA_MODEL=gpt-5.6-luna swift test --filter authenticatedLuna
```

Unit/build/schema tests do not invoke a model.

## License

MIT. See [LICENSE](LICENSE).
