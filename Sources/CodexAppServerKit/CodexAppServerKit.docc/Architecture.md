# Architecture and lifecycle

A client has one immutable transport factory and any number of task states and subscribers. Every connection creates a new generation. Numeric request IDs correlate responses; a cancelled Swift task removes only its local continuation, so a later server response is published as an unmatched raw diagnostic.

`connect()` initializes the protocol and rejects duplicate connections. Requests have no timeout unless the client or call supplies one. `close()` drains local waiters and closes only that transport; it does not stop a managed daemon.

After an unexpected close the client tries three jittered exponential reconnects by default. It recreates the channel, initializes, resumes requested tasks, and reads authoritative state. Offline input is rejected. Server-response handles from earlier generations are invalid.

## Event delivery

Every `subscribe` or `events(for:)` call gets an independent stream. `boundedFailing` ends only the slow subscriber. `boundedCoalescingDeltas` discards older delta events while preserving lifecycle events. `unbounded` is explicit and should be reserved for controlled consumers.

The reducer accepts deltas only as provisional state. `item/completed` replaces provisional data. More than eight task subscriptions emits an advisory diagnostic without imposing a limit.
