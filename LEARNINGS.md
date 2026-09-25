# Session learnings and setup state

Last updated: 2026-09-25. This is a living record for the current setup session. Append newly **verified** findings under [Later findings](#later-findings) as work continues. It intentionally contains no SSH key material, host-key fingerprints, bearer values, account tokens, or other credentials.

## Goal and selected routes

We are proving that the Swift SDK and reference CLI work, then connecting a personal remote app securely to Codex on a Mac mini. We considered Cloudflare Tunnel, returned to Tailscale, and selected two concrete routes:

1. A MacBook client reaches the Mac mini through **Tailscale plus ordinary macOS SSH**, with an SSH port forward to a bearer-protected loopback WebSocket listener.
2. A personal iOS app reaches the same kind of loopback listener through **Tailscale Serve HTTPS/WSS**, with a separate app-server bearer check.

No Cloudflare Tunnel was created. Tailscale Funnel is not part of either route. The detailed instructions are in [the SSH guide](docs/tailscale-ssh-macos.md) and [the iOS Serve guide](docs/tailscale-serve-ios.md).

## Project and CLI baseline

- The repository is `CodexAppServerSDK`, a Swift 6.2 package for macOS 15+ and iOS 26+. `CodexAppServerKit` owns the core client and WSS transport; `CodexAppServerHost` owns macOS process, daemon, and SSH transports; `codex-app-server-cli` is the reference CLI.
- Earlier in this session, `swift build`, the Swift test suite, and the SDK schema conformance check passed. An isolated CLI model turn using the explicit Luna model returned `SDK_CLI_OK`, and reconnect/history behavior was exercised. Those tests established that local stdio operation works; they did not establish remote SSH or Serve behavior.
- The Codex executable bundled in the desktop app reported `0.155.0-alpha.16.4`. It could run an isolated app-server but was not a complete package for `app-server daemon bootstrap`. A Homebrew/npm `codex` shim was also broken because its platform binary was missing.
- The official standalone installer was run for the Codex-owning macOS account. Its `~/.local/bin/codex` reports `codex-cli 0.157.0`, and `codex login status` reports an existing ChatGPT login. The installer added `~/.local/bin` to that account's `~/.zprofile`.
- We successfully bootstrapped a managed daemon with the standalone CLI, then stopped it after determining that it was not the right transport for this SDK version. It is currently **stopped**. The bootstrap was run without Remote Control enabled. A stopped daemon has no control socket, so `codex app-server daemon version` currently cannot connect to it.

## Tailscale and macOS SSH observations

- Tailscale 1.102.4 is running on the Mac mini. The Mac mini is online under its private MagicDNS name and tailnet IPv4 address, omitted from this tracked file. At the latest check, the MacBook peer was offline; its actual login and forwarding still need an end-to-end test from that computer.
- The installed macOS Tailscale app can carry ordinary SSH traffic, but its Standalone variant cannot be a **Tailscale SSH server**. We therefore use macOS Remote Login/OpenSSH on port 22, reached over Tailscale. Tailscale documents the [macOS variant differences](https://tailscale.com/docs/concepts/macos-variants).
- The Mac mini's SSH listener accepts connections on its tailnet IPv4 and on loopback. The SSH host key was checked on the Mac mini and against the known-host entry during local testing; its fingerprint is deliberately not recorded here.
- The MacBook's supplied public key is installed in the Codex-owning account's `~/.ssh/authorized_keys` with mode `600`; the directory has mode `700`. The key content and its comment are deliberately not recorded here.
- Earlier smoke tests generated temporary SSH keys to reach the Mac mini's Tailscale name from this same Mac. Every temporary authorization was removed. The user-supplied MacBook authorization remains installed.
- An experimental `~/.zshenv` PATH change was made for the Codex-owning account to test a remote `codex` command and then removed. SSH forwarding does not invoke a remote `codex` command, so that change is unnecessary. That account's `~/.zshenv` is currently absent.

## What failed and why the SSH route changed

- The SDK's `CodexHostTransports.sshProxy` and `managedDaemon` adapters send newline-delimited JSON through `codex app-server proxy`. A local check with Codex CLI 0.157.0 found that the managed Unix control socket used a WebSocket stream and the proxy relayed raw bytes to it. Local `initialize` sent through those JSON adapters received no response and timed out, while isolated stdio responded normally. Restarting the managed daemon did not change that result.
- A direct `codex app-server proxy` check likewise did not produce a response for a newline JSON `initialize` request. This is a **transport mismatch in the current SDK route**, not evidence that SSH key authentication failed. The README now records the compatibility limit.
- `CodexHostTransports.sshForward` uses an ordinary OpenSSH local port forward and the SDK's loopback WebSocket client. It worked in a temporary-key test both without bearer authentication and with a bearer-protected listener. In the protected test, the CLI returned `thread.list` and `session.close` results and exited cleanly. This is the route documented for Mac-to-Mac use.

## Current Mac mini host setup

- A random app-server capability token was created at `~/.config/codex-tailnet/app-server.token` for the Codex-owning account. The directory is mode `700`, and the file is mode `600`. Its value is never printed or committed. The MacBook still needs a secure copy after its SSH login is verified.
- A user LaunchAgent under that account's `~/Library/LaunchAgents/` runs `~/.local/bin/codex app-server --listen ws://127.0.0.1:4500 --ws-auth capability-token --ws-token-file ...`. `plutil -lint` passed, `launchctl` reported the agent running, and `http://127.0.0.1:4500/healthz` returned `200`.
- Inspect or unload the service with `launchctl` using its private label or plist path. Its stdout and stderr go to files under that account's `~/Library/Logs/`.
- The listener binds **only** to `127.0.0.1:4500`. A WebSocket upgrade with an incorrect bearer returned `401 Unauthorized`; the correct bearer returned `101 Switching Protocols`. These checks did not disclose the credential.
- With that persistent listener, a temporary SSH key, and the repository CLI's `connect ssh-forward` command, `thread.list` and `session.close` both returned results through the Mac mini's Tailscale address. The temporary key was then removed, leaving the MacBook's supplied authorization intact.
- The host's Tailscale Serve status is `{}`. Serve is not yet enabled in this tailnet, so there is no active HTTPS/WSS Serve route. A previous attempted Serve setup directed us to an owner/admin enablement page; no Serve mapping or Funnel was left running.

## iOS transport finding

- `CodexWebSocketConfiguration` currently requires a nonempty `CodexTunnelHeaderProvider` as well as a nonempty app bearer for remote WSS. For Tailscale Serve, a marker header can satisfy that API requirement, but the marker does **not** authenticate the caller. Tailscale membership and tailnet policy control network access; app-server verifies the bearer. The iOS guide states this explicitly.
- The SDK uses normal platform TLS validation for WSS. The Serve endpoint, certificate provisioning, and end-to-end iOS connection have **not** been live-tested because Serve is not enabled yet. Tailscale's [Serve documentation](https://tailscale.com/docs/features/tailscale-serve) covers enablement and private tailnet access.

## Repository delivery

- The two setup guides and README compatibility note were committed on `codex/tailscale-remote-setup` as `c7eaec4` and pushed. [PR #13](https://github.com/hbmartin/CodexAppServer-Swift/pull/13) is open, targets `main`, and is **ready for review**, not a draft. It has not been merged.
- For that change, `git diff --check` and local Markdown-link checks passed; the example LaunchAgent plist parsed with `plutil -lint`. The SSH-forward CLI check returned real RPC results. The schema and security jobs passed. The iOS simulator job failed in three pre-existing test functions with timeout errors; see [Later findings](#later-findings).
- This file is being added to the same PR. It records host state but no credential material.

## Remaining live work

1. Bring the MacBook online in Tailscale. On it, compare the Mac mini's SSH host-key fingerprint out of band, then test passwordless `ssh` as the Codex-owning account using its existing private key. Do not put the fingerprint or key in this file.
2. Copy the capability token from the Mac mini to the MacBook over the verified SSH connection, keep its local file private, and run `codex-app-server-cli connect ssh-forward` from the MacBook. Confirm an actual RPC result and clean disconnect.
3. When the tailnet owner enables Serve and HTTPS certificates, configure the private Serve mapping, test bearer rejection and acceptance through WSS from another tailnet device, and then test the personal iOS app. Do not use Funnel for this private route.
4. Decide whether to adapt `managedDaemon` and `sshProxy` to the current WebSocket control-socket protocol in a separate code change. Their current CLI 0.157.0 behavior is documented, but this documentation PR does not implement that transport change.

## Later findings

Append dated, verified observations here as this session continues. For each entry, state what changed, the exact check that established the result, and any remaining limit. Never paste key material, fingerprints, bearer values, account tokens, or credential-bearing command output into this file.

- **2026-09-25 — iOS CI:** PR #13's iOS simulator job built the SDK products, then failed in `detailedDirectoryListingCancellationStopsSchedulingMetadataWork`, `detailedDirectoryMetadataRequestsAreBoundedAndPreserveChildOrder`, and `terminalTurnNotificationWinsOverLateStartAcknowledgement`. The logs report waiter and request timeouts. This PR had changed only Markdown files when the job ran; the cause of the simulator timing failure is not yet established. The macOS job had not completed at this check.
- **2026-09-25 — Local Luna verification:** On the development Mac, `codex-cli 0.154.0` and the authenticated `gpt-5.6-luna` isolated-stdio smoke test completed an ephemeral turn with the expected response. The helper regression, strict Swift suite, process-enabled suite, schema conformance check, installer failure/success checks, SSH agent check, and local Markdown links also passed.
