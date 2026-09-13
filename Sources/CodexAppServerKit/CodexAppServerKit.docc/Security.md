# Security model

App-server and its host remain the authority for authentication, sandboxing, approvals, and filesystem access.

Remote WSS construction requires normal system TLS trust, a separate application bearer, and non-empty tunnel/private-network identity headers. The SDK has no certificate bypass or pinning surface and never owns Keychain entries. Credential providers are asynchronous and called for each reconnect.

The filesystem convenience API is read-only. It requires declared absolute workspace roots, normalizes paths, rejects traversal, asks app-server for metadata on every component, and rejects reported symlinks. This is defense in depth; app-server permissions make the final decision.

The raw API intentionally includes future methods. Unauthenticated listeners, raw `process/*`, and bridges that forward an application bearer without validating it are unsafe deployments.

Logging defaults to redacted payloads. Full mode can expose source text, prompts, paths, command lines, and output, but credential-shaped fields remain redacted.
