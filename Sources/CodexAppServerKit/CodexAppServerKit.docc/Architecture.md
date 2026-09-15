# Architecture and lifecycle

A client has one immutable transport factory and any number of task states and subscribers. Every connection creates a new generation. Numeric request IDs correlate responses; a cancelled Swift task removes only its local continuation, so a later server response is published as an unmatched raw diagnostic.

`connect()` initializes the protocol and rejects duplicate connections. Requests have no timeout unless the client or call supplies one. `close()` invalidates in-flight connection attempts, drains local waiters, and waits for transport cleanup already in progress; it does not stop a managed daemon. A superseded factory or startup result is closed instead of installed.

After an unexpected close the client tries three jittered exponential reconnects by default. It recreates the channel, initializes, resumes requested tasks, and reads authoritative state. Offline input is rejected. Server-response handles from earlier generations are invalid.

## Event delivery

Every `subscribe` or `events(for:)` call gets an independent stream with one consumer. `subscribe` receives all client events; `events(for:)` requires a nonempty task ID and receives only events scoped to that task. `boundedFailing` ends only the slow subscriber. When full, `boundedCoalescingDeltas` combines adjacent text deltas only when their task, item, method, turn, and remaining metadata match. It preserves fragment order and reasoning segment boundaries. If events cannot be combined without loss, or combined text exceeds the configured frame limit, that subscriber fails explicitly. `unbounded` is explicit and should be reserved for controlled consumers. Cancel subscriptions when their consumers finish.

History responses are reduced in protocol order before the request caller resumes. Full history rebuilds turn and item collections and active turn IDs, then emits `threadStateUpdated`. Metadata-only reads preserve loaded history. Streamed deltas remain provisional events; `item/completed` replaces the cached item. `turnUsage(threadID:)` returns the latest usage notification's `total` cumulative counters and `last` turn counters. More than eight task subscriptions emits an advisory diagnostic without imposing a limit.

## Malformed data and retry safety

Typed list responses and history replay retain valid entries and report skipped entries through diagnostics. Pages preserve their raw response and `nextCursor`, even if every entry is malformed. Diagnostics with a known thread ID reach that thread's `events(for:)` subscribers as `threadMalformedMessage`; unscoped diagnostics remain on the global stream.

Typed operations validate empty identity arguments before sending requests and report `CodexError.invalidArgument`. Whole-object reads still reject malformed response models. For `startThread`, `forkThread`, `startTurn`, and `steerTurn`, an invalid success response raises `CodexError.invalidMutationResponse`, preserving the method and raw response. The server may already have performed the operation. Reconcile server state before retrying; neither this error nor a timeout, transport failure, or local cancellation proves that a mutation was rejected. The SDK never automatically retries these mutations.
