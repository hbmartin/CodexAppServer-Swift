# Questions, approvals, and tools

Server requests are not notifications: Codex is waiting for the controller's response. ``CodexPendingInteraction`` preserves the full payload while exposing decision choices and multi-question data.

Response handles are one-shot and connection-generation scoped. Present the request to a human, then answer with an advertised decision or structured answer map. Never cache a handle across reconnects. `serverRequest/resolved` removes a pending request; `autoResolutionMs` is informational only.

A response is reserved before sending, including when several callers share a handle. A failed send is ambiguous and cannot be retried through that handle. Both numeric and string request IDs are preserved. Replayed requests can be answered after initialization while task history is being restored; ordinary new requests still wait for recovery to finish. A `recoveryRequired` connection permits explicit user-directed recovery operations such as reading or interrupting the affected turn.

Dynamic tools are routed automatically through ``CodexDynamicToolRegistry``. Missing handlers receive an explicit failure result. Running handlers are cancelled when the connection closes, and the registry itself survives reconnects.
