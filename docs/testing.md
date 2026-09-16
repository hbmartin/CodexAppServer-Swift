# Testing decisions and procedures

This project separates deterministic tests from tests that require a local Codex process or an authenticated production account. The default suite never starts a model turn and never contacts the production Remote Control service.

## Required checks

Run these before merging any SDK change:

```sh
swift build -Xswiftc -strict-concurrency=complete
swift test -Xswiftc -strict-concurrency=complete
Scripts/check-sdk-schema-conformance.sh
```

The build uses complete Swift concurrency checking for every product. The default test suite covers request correlation, cancellation, reconnects, recovery, event buffering, observation models, CLI parsing and JSONL input validation, HTTP notifications, current Remote Control HTTP contracts, real loopback protocol-v3 WebSockets, and high-volume process output ordering.

`Scripts/check-sdk-schema-conformance.sh` requires `jq`. It checks outbound method names, routed notification names, and typed item kinds against `Schemas/0.146.0`. To compare the vendored snapshot with a locally installed Codex CLI, run:

```sh
Scripts/check-schema-drift.sh
```

That drift check requires `jq` and `codex` 0.146.0. It regenerates schemas in a temporary directory and does not modify the checkout.

## Correctness regression tests

The Kit tests deliberately exercise protocol ordering and ambiguity:

- A terminal `turn/completed` notification is delivered before a late `turn/start` acknowledgement; the terminal state must remain authoritative.
- Exact integer access rejects fractions and values outside `Int64` or `UInt32` instead of truncating or wrapping.
- Typed paging sends only schema-supported sort values, validates limits before I/O, and preserves forward and backward cursors.
- Command output rejects missing or wrong-typed stream, base64, and cap fields.
- Raw inbound JSON-RPC notifications are opt-in. Normal subscribers receive one typed event; JSONL subscribers receive the exact protocol envelope followed by the typed lifecycle event.
- Explicit `subscribeThread` intent survives cancellation of a temporary event stream, while a cancelled stream-only intent is not restored.
- An unscoped lost interaction enters recovery, leaves read operations available, blocks mutations, and requires acknowledgement by its exact request ID.
- Filesystem roots deny all paths when empty. Basic directory listing does not fan out metadata requests. Detailed listing limits concurrent metadata requests, preserves server order, and returns per-child diagnostics without discarding successful entries.

## Performance and ordering tests

`dequeEventBufferHandlesLargeOrderedBacklog` enqueues and drains 100,000 events. It verifies order and guards against reintroducing the former array-front-removal behavior.

`processTransportPreservesHighVolumeStdoutFrameOrder` starts a real child process that writes 10,000 JSONL frames. The test checks every sequence number. The process transport uses dedicated blocking reader tasks and does not dispatch one unstructured task per pipe callback.

Detailed directory tests hold metadata responses at a gate and assert the configured concurrency limit. Remote send tests configure a one-frame outbound queue so subsequent producers must wait while preserving sequence order.

## Remote Control and hidden WHAM testing

Remote Control is a supported SDK surface over a service protocol that still changes independently of the app-server JSON-RPC schema. Public SDK names deliberately do not expose `WHAM`. The controller's manual-pair mutation currently uses the hidden WHAM route under the hood, while environment discovery and the controller WebSocket use the current Codex Remote Control routes. The tests assert those exact boundaries so a retired route cannot silently survive behind the supported API again.

The deterministic suite has three layers:

1. `RemoteControlContractTests` injects a `URLProtocol` and verifies the current environment-list and manual-pair paths, request bodies, `Authorization` and `ChatGPT-Account-Id` headers, pagination, per-entry diagnostics, safe-read retry, mutation non-retry, strict account binding, environment-ID path encoding, secret redaction, and rejection of non-ChatGPT credential destinations. It also asserts that the client session token is not sent to the manual-pair HTTP route.
2. `remoteLoopbackWebSocketUsesCurrentEnvelopesSegmentsDuplicatesAndFreshStreams` starts a real WebSocket server on `127.0.0.1`. It requires protocol version 3, account auth, client-session auth, client ID, environment ID, a fresh stream ID per transport, per-stream sequence restart, ordered bounded sends, outbound segmentation, inbound reassembly, and duplicate suppression.
3. `remoteLoopbackWebSocketValidatesAndAnswersDeviceKeyChallengeBeforeAppTraffic` makes the server send a production-shaped `device_key_challenge`. The SDK must validate its purpose, audience, client and account-user identities, target origin and path, token hash, expiration, and scopes before calling the application's signer. The server rejects any app-server message sent before the proof.

Both loopback servers bind ephemeral ports, use no network beyond `127.0.0.1`, write reports under UUID-scoped temporary directories, and are terminated and deleted after each test. They use real HTTP upgrades and WebSocket frames rather than a transport mock.

The authorization split is intentional. A Codex account access token can list environments, but it cannot enroll a controller or open the current controller WebSocket. Production enrollment requires a fresh step-up authorization and a protected device key. `CodexRemoteClientAuthorizationProvider` makes that boundary explicit; its implementation owns enrollment, protected-key persistence, refresh, and challenge signing. The SDK does not copy a Desktop enrollment, scrape another application's Keychain, or downgrade the service's proof requirement.

When the upstream transport changes, compare the client implementation with the [official Codex Remote Control protocol source](https://github.com/openai/codex/blob/main/codex-rs/app-server-transport/src/transport/remote_control/protocol.rs), update both loopback servers, and run the production discovery smoke test. Treat a production 404, 401, challenge mismatch, or new envelope discriminator as a protocol failure, not as a flaky test.

## Local Codex process tests

These tests launch the installed Codex CLI but do not start a model turn:

```sh
RUN_CODEX_PROCESS_TESTS=1 swift test -Xswiftc -strict-concurrency=complete
```

They require `codex` 0.146.0 or newer on `PATH`. They cover a real isolated filesystem listing, a loopback app-server WebSocket, frame-size behavior, and SSH-forward readiness. Temporary `CODEX_HOME` directories and child processes are removed when each test completes.

## Authenticated local Luna test

The local release smoke test uses two clients connected to one managed daemon and verifies that the second client sees the first client's turn:

```sh
CODEX_LUNA_MODEL=gpt-5.6-luna Scripts/run-authenticated-luna-tests.sh
```

The model name must contain `luna`; the test refuses other models. This path bootstraps or starts managed daemon support and creates a persistent Codex task.

## Authenticated production Remote Control test

Run:

```sh
Scripts/run-remote-control-live-tests.sh
```

Prerequisites:

- macOS with a native standalone `codex` 0.146.0 or newer and `jq` on `PATH`.
- A valid Codex login in `${CODEX_HOME:-~/.codex}/auth.json`.
- An account allowed to use Remote Control.

The runner creates an isolated temporary `CODEX_HOME`, links only the existing login and native standalone executable, starts a Remote Control host, reads its environment ID, and runs `authenticatedRemoteControlHostDiscovery`. The test calls the production environment-list route through `CodexAppServerRemote`, waits for that exact environment to be visible and online, and requires clean response diagnostics. Cleanup stops the isolated daemon, removes the temporary environment through the SDK CLI, and deletes the temporary home. It does not change or stop the user's normal daemon.

This production test deliberately stops at authenticated discovery. A normal `auth.json` does not contain the controller session or device private key. Automating production pairing by borrowing another application's enrollment would invalidate the security property the challenge test is meant to preserve. Full pair/connect/model-turn testing is appropriate in an embedding application's test account when that application can supply its own enrollment and signer.

The direct form, used when a host is already online, is:

```sh
RUN_CODEX_REMOTE_LIVE_TESTS=1 \
CODEX_REMOTE_EXPECTED_ENVIRONMENT_ID=env_e_example \
swift test --filter authenticatedRemoteControlHostDiscovery
```

Never place pairing codes, account tokens, controller session tokens, device proofs, or private-key material in committed fixtures or captured test output.

## Full controller integration procedure

The reference CLI accepts `--authorization-helper EXECUTABLE` for `remote pair`, `remote connect`, and `remote revoke-client`. This gives an embedding application a testable process boundary without putting secrets in command-line arguments. The CLI sends one JSON object on stdin and passes the action as the helper's first argument.

For `authorize`, input is:

```json
{
  "schemaVersion": 1,
  "action": "authorize",
  "accountID": "account-id",
  "accountAccessToken": "secret",
  "forceRefresh": false
}
```

The helper returns `clientID`, `sessionToken`, `accountUserID`, `expiresAt` as ISO-8601 text or epoch seconds, `scopes`, and `requiresDeviceKeyProof`. For `sign-challenge`, input contains the validated raw challenge plus `accountID`, `accountUserID`, and `clientID`; output is either the proof object or `{ "proof": { ... } }`. The helper must keep the nonextractable device key under application control and must validate the challenge again before signing.

Run a complete integration in this order:

1. Enroll the helper's controller client using the application's fresh step-up flow.
2. Start an isolated Remote Control host and request its manual pairing code.
3. Run `codex-app-server-cli remote pair --authorization-helper ./helper` in a terminal and enter the code at its protected prompt.
4. Run `codex-app-server-cli remote hosts --json` and capture the paired online environment ID.
5. Run `codex-app-server-cli remote connect ENV_ID --authorization-helper ./helper --json`.
6. Send `model.list`, `thread.start`, `turn.start`, and `client.reconnect` JSONL commands. Require the terminal turn event and read the same task after reconnect.
7. Run `remote revoke-client` only in a disposable enrollment test; otherwise stop the host and run `remote remove ENV_ID` for cleanup.

Use a Luna model explicitly for any model turn. Record the Codex CLI version, environment ID, helper version, and pass/fail result. Do not record the pairing code, account token, client session, challenge, or proof.
