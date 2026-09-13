# Questions, approvals, and tools

Server requests are not notifications: Codex is waiting for the controller's response. ``CodexPendingInteraction`` preserves the full payload while exposing decision choices and multi-question data.

Response handles are one-shot and connection-generation scoped. Present the request to a human, then answer with an advertised decision or structured answer map. Never cache a handle across reconnects. `serverRequest/resolved` removes a pending request; `autoResolutionMs` is informational only.

Dynamic tools are routed automatically through ``CodexDynamicToolRegistry``. Missing handlers receive an explicit failure result. Running handlers are cancelled when the connection closes, and the registry itself survives reconnects.
