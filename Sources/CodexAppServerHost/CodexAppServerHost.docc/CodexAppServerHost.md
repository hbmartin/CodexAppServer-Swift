# ``CodexAppServerHost``

Manage and connect to Codex app-server processes on macOS.

## Overview

``CodexDaemonController`` resolves lifecycle operations without installing, upgrading, or authenticating Codex. Durable installation occurs only through `prepareManagedDaemon()`. ``CodexHostTransports`` creates isolated stdio, managed-daemon proxy, SSH proxy, and SSH-forwarded loopback WebSocket transports.

``CodexHostProfile`` is an immutable connection description. Application code remains responsible for persisting or selecting profiles and for ensuring controllers for one logical host point at the same daemon/listener.

System SSH uses batch mode and normal known-host enforcement. The library has no host-key bypass. SSH forwarding requires OpenSSH 8.7 or newer, or a compatible client that supports `ForkAfterAuthentication`.
