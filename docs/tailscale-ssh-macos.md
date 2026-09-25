# Connect a macOS client through Tailscale and SSH

This guide runs Codex on a Mac mini and connects a Swift app or this repository's CLI from a MacBook. Tailscale carries the network traffic; macOS Remote Login authenticates SSH; SSH forwards a MacBook loopback port to a Codex WebSocket listener bound to **Mac mini loopback**. The Mac mini must already be signed in to Codex.

```
MacBook app or CLI -> ws://127.0.0.1:4501 -> SSH over Tailscale
                    -> ws://127.0.0.1:4500 on Mac mini -> Codex app-server
```

The macOS App Store and Standalone Tailscale apps cannot act as **Tailscale SSH servers**. Keep those apps and use ordinary OpenSSH plus macOS Remote Login. The separate open-source `tailscaled` variant supports Tailscale SSH, but changing variants is unnecessary for this setup. See [Tailscale's macOS variant comparison](https://tailscale.com/docs/concepts/macos-variants).

## 1. Prepare the Mac mini

1. Install Tailscale on both Macs, sign in to the same tailnet, and connect both devices. On the Mac mini, `tailscale status` should show it online. `tailscale ip -4` gives its tailnet IP; `tailscale status --json` contains its full MagicDNS name in `Self.DNSName`. Use that `*.ts.net` name below. The MacBook must also be online for the final test.
2. In **System Settings → General → Sharing**, turn on **Remote Login** and allow the macOS account that owns the Codex login. This starts Apple's normal SSH service. There is no router port forwarding step. Apple documents the setting in [Allow a remote computer to access your Mac](https://support.apple.com/guide/mac-help/mchlp1066/mac).
3. On the Mac mini, check that port 22 is reachable on its Tailscale address:

   ```sh
   nc -G 3 -z "$(tailscale ip -4)" 22
   ```

   This only proves that an SSH listener accepts TCP connections. It does not prove that the MacBook has a valid key or that tailnet policy allows the MacBook through.

4. Install and authenticate a Codex CLI on the Mac mini. The [official standalone installer](https://learn.chatgpt.com/docs/codex/cli) provides a complete package and places `codex` in `~/.local/bin`:

   ```sh
   (
     installer="$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXXXX")" || exit 1
     trap 'rm -f "$installer"' EXIT
     curl -fsSL https://chatgpt.com/codex/install.sh -o "$installer" || exit 1
     sh "$installer"
   ) &&
   "$HOME/.local/bin/codex" --version &&
   "$HOME/.local/bin/codex" login status
   ```

   If the host is not signed in, run `"$HOME/.local/bin/codex" login`. This SSH-forward route starts a loopback app-server directly; it does not require `codex app-server daemon bootstrap` or `codex app-server proxy`.

5. Create a capability token on the Mac mini and start the listener in a dedicated terminal:

   ```sh
   install -d -m 700 "$HOME/.config/codex-tailnet"
   umask 077
   if [ ! -f "$HOME/.config/codex-tailnet/app-server.token" ]; then
     openssl rand -hex 32 > "$HOME/.config/codex-tailnet/app-server.token"
   fi
   chmod 600 "$HOME/.config/codex-tailnet/app-server.token"
   "$HOME/.local/bin/codex" app-server \
     --listen ws://127.0.0.1:4500 \
     --ws-auth capability-token \
     --ws-token-file "$HOME/.config/codex-tailnet/app-server.token"
   ```

   The token is separate from the SSH key. Provision it securely to the MacBook; do not commit it or paste it into an SSH alias. A second terminal can confirm `nc -G 3 -z 127.0.0.1 4500`. For unattended service, the [iOS Serve guide](tailscale-serve-ios.md#3-start-a-loopback-websocket-listener) includes a user LaunchAgent example. You can use the **same** listener and token for both SSH forwarding and Tailscale Serve.

## 2. Authorize the MacBook's SSH key

On the **MacBook**, use an existing Ed25519 key or create one. Keep the private key on the MacBook; only transfer the `.pub` text:

```sh
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

On the **Mac mini**, logged in as the Codex-owning macOS account, append that one public-key line to `~/.ssh/authorized_keys`:

```sh
install -d -m 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
# Paste the MacBook's one-line public key into authorized_keys, then save it.
```

Before first connection, display the Mac mini's SSH host-key fingerprint **on the Mac mini** and compare it with the fingerprint presented on the MacBook:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Do not bypass host-key checking. A changed fingerprint needs investigation before accepting a new key.

## 3. Make a MacBook SSH alias

Add a host to the **MacBook's** `~/.ssh/config` (replace the hostname and username):

```sshconfig
Host codex-mini
    HostName mac-mini-name.your-tailnet.ts.net
    User macos-account-name
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 10
```

Then run these on the MacBook:

```sh
tailscale status
ssh -o BatchMode=no codex-mini true # First connection: compare and accept the host key.
ssh codex-mini 'whoami; nc -G 3 -z 127.0.0.1 4500'
```

Accept the host key only after comparing the fingerprint above. `ssh-add` loads a passphrase-protected key into the agent so the later `BatchMode=yes` connection can use it without a prompt; load it again if the agent loses the key. If authentication fails, check the public key, permissions of `~/.ssh` and `authorized_keys`, the `User` setting, and the Remote Login allowlist. The SSH-forward transport itself does not run a remote `codex` command.

## 4. Connect this SDK

On the MacBook, copy the token over the now-verified SSH connection. Keep its directory at mode `700` and file at mode `600`. Then build and connect from a checkout of this repository:

```sh
install -d -m 700 "$HOME/.config/codex-tailnet"
umask 077
scp codex-mini:.config/codex-tailnet/app-server.token \
  "$HOME/.config/codex-tailnet/app-server.token"
chmod 600 "$HOME/.config/codex-tailnet/app-server.token"
swift build
export CODEX_APP_BEARER="$(cat "$HOME/.config/codex-tailnet/app-server.token")"
.build/debug/codex-app-server-cli connect ssh-forward codex-mini \
  --local-port 4501 --remote-port 4500 \
  --app-bearer-env CODEX_APP_BEARER
```

At the `codex>` prompt, enter `list`, then `quit`. If port 4501 is taken, choose another unused local port. `ssh -V` must report OpenSSH 8.7 or newer, or a compatible client that supports `ForkAfterAuthentication`. For a machine-readable check, add `--json` and send a `thread.list` command followed by `session.close`; a response with matching `id` should have `type: "result"`:

```json
{"schemaVersion":1,"id":"list","command":"thread.list","arguments":{"limit":1}}
{"schemaVersion":1,"id":"close","command":"session.close","arguments":{}}
```

The equivalent macOS Swift setup is:

```swift
import CodexAppServerHost
import CodexAppServerKit

struct Bearer: CodexBearerCredentialProvider {
    let loadToken: @Sendable () async throws -> String
    func credential() async throws -> CodexBearerCredential {
        .init(value: try await loadToken(), kind: .capability)
    }
}

let factory = try CodexHostTransports.sshForward(
    host: .alias("codex-mini"), localPort: 4501, remotePort: 4500,
    bearer: Bearer(loadToken: { try await secretStore.readAppServerToken() })
)
let client = CodexClient(transportFactory: factory)
try await client.connect()
let tasks = try await client.listThreads(.init(limit: 20))
await client.close()
```

The app supplies its own secret store. The transport establishes SSH with `BatchMode=yes` and normal known-host enforcement, then uses a loopback WebSocket with the bearer. The Mac mini listener stays alive when a client disconnects. An iOS app should use the [Tailscale Serve WSS guide](tailscale-serve-ios.md).

### Why this guide uses `ssh-forward`

The repository also exposes `ssh-proxy`, which sends newline JSON to `codex app-server proxy`. A local check with Codex CLI 0.157.0 found that its managed control socket carried a WebSocket stream and this JSON transport never received an `initialize` response. Use the verified SSH-forward path for this setup; `daemon version` alone does not prove that `ssh-proxy` works.

## Restrict access and troubleshoot

If your tailnet policy is intentionally restrictive, permit the MacBook user or device to reach the Mac mini on `tcp:22`. For example, after tagging the host as `tag:codex-host`, a grant can include:

```json
{"src":["your-github-user@github"],"dst":["tag:codex-host"],"ip":["tcp:22"]}
```

Review the **whole** tailnet policy: grants are additive, so an existing broad rule may still allow other devices. This is a network rule, not a Tailscale SSH `ssh` policy. See [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants).

| Symptom | Check |
| --- | --- |
| `tailscale ping HOST` fails | Both Macs are connected, the MagicDNS name is current, and policy permits traffic. |
| SSH connection refused or timed out | Remote Login, Mac mini sleep state, `tailscale status`, and port 22 on the tailnet IP. |
| `Permission denied (publickey)` | MacBook public key in the correct Mac mini user's `authorized_keys`; SSH alias `User` and `IdentityFile`. |
| `Host key verification failed` | Compare the Mac mini's current fingerprint with the trusted one before changing `known_hosts`. |
| Local port unavailable | Pick a free `--local-port`; make sure an old forward process has exited. |
| WebSocket upgrade gets `401` | Check that the MacBook bearer matches the Mac mini token file and that the listener was restarted after token rotation. |
| WebSocket connection fails | Check `nc -G 3 -z 127.0.0.1 4500` on the Mac mini and through `ssh codex-mini` from the MacBook. |

Keep the Mac mini awake when it must accept remote sessions. For short tests, the host can run `caffeinate -dimsu`; configure a durable power setting for unattended use. To revoke this MacBook, remove only its public key from `authorized_keys`, remove its network grant if one was added, and rotate the bearer if the MacBook held a copy.
