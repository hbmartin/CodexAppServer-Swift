# ``CodexAppServerKit``

Build interactive Swift clients for one durable Codex app-server.

## Overview

``CodexClient`` is an actor that owns JSON-RPC correlation, server requests, multicast event delivery, reconnect generations, and keyed task state. A ``CodexTransportFactory`` creates a fresh transport for initial connection and each reconnect. Unknown protocol data stays available through ``JSONValue``.

```swift
let client = CodexClient(transportFactory: factory)
try await client.connect()
let task = try await client.startThread()
let turn = try await client.startTurn(threadID: task.id, prompt: "Hello")
```

The SDK always enables experimental app-server APIs and extended MCP/OpenAI form elicitation. It does not opt into attestation.

## Topics

### Core

- ``CodexClient``
- ``CodexTransport``
- ``CodexTransportFactory``
- ``JSONValue``
- ``CodexError``
- ``CodexConnectionState``

### Events and state

- ``CodexEvent``
- ``CodexSubscription``
- ``CodexBufferingPolicy``
- ``CodexThreadState``
- ``CodexDiagnostic``

### Tasks, turns, and items

- ``CodexThread``
- ``CodexTurn``
- ``CodexItem``
- ``CodexInput``
- ``CodexThreadOptions``
- ``CodexTurnOptions``

### Human interaction

- ``CodexPendingInteraction``
- ``CodexInteractionResponseHandle``
- ``CodexInteractionResponse``
- ``CodexInteractionKind``

### Extensions

- ``CodexDynamicToolRegistry``
- ``CodexDynamicTool``
- ``CodexMedia``
- ``CodexWorkspaceRoots``
- ``CodexWebSocketConfiguration``
