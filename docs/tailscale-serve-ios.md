# Connect a personal iOS app with Tailscale Serve and WSS

This guide exposes a Codex app-server running on a Mac to **your own iOS app**. The iPhone joins the same tailnet, Tailscale Serve supplies a trusted HTTPS/WSS endpoint inside that tailnet, and app-server checks a separate bearer token during the WebSocket upgrade. The app-server listener stays on Mac loopback; it is never bound to a LAN or public address.

```
iOS app -> iOS Tailscale VPN -> wss://mac.tailnet.ts.net:443
        -> Tailscale Serve -> ws://127.0.0.1:4500
        -> Codex app-server (bearer required)
```

Tailscale **Serve** is private to the tailnet. Tailscale **Funnel** publishes a service to the internet and is outside this setup. See [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) and [the Serve command reference](https://tailscale.com/docs/reference/tailscale-cli/serve).

## 1. Prepare the host and tailnet

1. Install and authenticate a Codex CLI on the Mac. Run `codex --version` and `codex login status` as the macOS account that will run app-server. This route runs a loopback WebSocket listener directly; it does not need a managed Unix daemon.
2. Connect the Mac and iPhone to the same tailnet. On the Mac, run `tailscale status` and read `Self.DNSName` from `tailscale status --json` for its full `*.ts.net` hostname. On the iPhone, connect the Tailscale VPN before launching your app.
3. Enable MagicDNS and HTTPS certificates in the tailnet DNS settings. `tailscale serve` may present an admin URL to enable Serve and HTTPS; complete that owner/admin step before retrying. Tailscale provisions the certificate for Serve. The node hostname appears in public certificate transparency logs, though the service remains tailnet-only. See [Enabling HTTPS](https://tailscale.com/docs/how-to/set-up-https-certificates).
4. If you restrict traffic with tailnet policy, allow only the intended iPhone user or device to reach the Mac on `tcp:443`. A grant after tagging the Mac `tag:codex-host` could include:

   ```json
   {"src":["your-github-user@github"],"dst":["tag:codex-host"],"ip":["tcp:443"]}
   ```

   Inspect existing grants and ACLs too: a narrower grant does not override an older broad allowance. `tcp:4500` need not be opened in the tailnet because the origin binds only to the Mac's loopback interface. See [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants).

## 2. Create the app-server capability token

On the Mac, create a random bearer token in a file readable only by your user. Reuse the existing token if you followed the SSH guide first; replacing it would disconnect that client. Do not commit, log, or embed this token in an iOS binary:

```sh
install -d -m 700 "$HOME/.config/codex-tailnet"
umask 077
if [ ! -f "$HOME/.config/codex-tailnet/app-server.token" ]; then
  openssl rand -hex 32 > "$HOME/.config/codex-tailnet/app-server.token"
fi
chmod 600 "$HOME/.config/codex-tailnet/app-server.token"
```

For a personal app, provision that token to the iPhone through your app's secure enrollment flow and store it in the iOS Keychain. Anyone holding the token **and** able to reach the Serve URL can connect as the host's Codex user. Rotate it if a device is lost or the token leaks. For several independent users, build per-client authorization with signed bearer tokens or an authenticating bridge rather than sharing one static capability. The [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server) describes its WebSocket listener and bearer modes.

## 3. Start a loopback WebSocket listener

For the first test, run this in a dedicated Mac terminal and leave it open:

```sh
codex app-server \
  --listen ws://127.0.0.1:4500 \
  --ws-auth capability-token \
  --ws-token-file "$HOME/.config/codex-tailnet/app-server.token"
```

Use the standalone `codex` binary's absolute path if another install wins `PATH`. A second terminal can check `nc -G 3 -z 127.0.0.1 4500`. Do not use `ws://0.0.0.0:4500`; Serve connects locally to the loopback origin.

For unattended operation, supervise the same command with a user LaunchAgent or another process manager under the **same macOS account**. Use absolute paths for the Codex binary and token file, and start the agent only after that account has a working Codex login. For example, replace `MAC_ACCOUNT` in this plist and save it as `~/Library/LaunchAgents/com.example.codex-tailnet-ws.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.codex-tailnet-ws</string>
  <key>ProgramArguments</key><array>
    <string>/Users/MAC_ACCOUNT/.local/bin/codex</string>
    <string>app-server</string>
    <string>--listen</string><string>ws://127.0.0.1:4500</string>
    <string>--ws-auth</string><string>capability-token</string>
    <string>--ws-token-file</string><string>/Users/MAC_ACCOUNT/.config/codex-tailnet/app-server.token</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```

Load it with `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.example.codex-tailnet-ws.plist"`. Use `launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.example.codex-tailnet-ws.plist"` to unload it. Do not run the foreground listener and the LaunchAgent on port 4500 simultaneously.

## 4. Enable Serve and verify WSS

On the Mac:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:4500
tailscale serve status
```

The status output should show an HTTPS endpoint for the Mac's MagicDNS name proxying to `127.0.0.1:4500`. Use the same name with the `wss://` scheme in the app, for example `wss://mac-mini-name.your-tailnet.ts.net/`. Port 443 is implicit. If the command says Serve is not enabled, open its printed owner/admin URL, finish the approval, and rerun it. The route is unavailable until that tailnet setting is enabled.

From another tailnet-connected Mac, make an authenticated WebSocket handshake using the repository CLI (with this SDK built there):

```sh
export CODEX_APP_BEARER="$(cat /path/to/secure/app-server.token)"
export CODEX_TAILNET_ROUTE=tailscale-serve
.build/debug/codex-app-server-cli connect wss \
  wss://mac-mini-name.your-tailnet.ts.net/ \
  --app-bearer-env CODEX_APP_BEARER \
  --tunnel-header X-Codex-Private-Network \
  --tunnel-env CODEX_TAILNET_ROUTE
```

Enter `list`, then `quit`. Test a missing or incorrect bearer separately: the app-server must reject the WebSocket upgrade. A `502` suggests Serve cannot reach the local listener; a TLS or DNS failure points to MagicDNS, HTTPS enablement, or the iPhone's Tailscale connection. Do not disable TLS validation to make a failed connection pass.

## 5. Connect the iOS SDK

Link `CodexAppServerKit` to the iOS app. Provide the token from your app's Keychain backed secret store; the SDK does not store or refresh it for you:

```swift
import CodexAppServerKit

struct AppBearer: CodexBearerCredentialProvider {
    let loadToken: @Sendable () async throws -> String

    func credential() async throws -> CodexBearerCredential {
        .init(value: try await loadToken(), kind: .capability)
    }
}

struct TailnetRoute: CodexTunnelHeaderProvider {
    func headers() async throws -> [String: String] {
        ["X-Codex-Private-Network": "tailscale-serve"]
    }
}

let configuration = try CodexWebSocketConfiguration(
    wssURL: URL(string: "wss://mac-mini-name.your-tailnet.ts.net/")!,
    applicationBearer: AppBearer(loadToken: {
        try await secretStore.readAppServerToken() // Implement with your Keychain store.
    }),
    tunnelHeaders: TailnetRoute()
)
let client = CodexClient(
    transportFactory: CodexWebSocketTransport.factory(configuration: configuration)
)
try await client.connect()
let tasks = try await client.listThreads(.init(limit: 20))
```

**Current SDK constraint:** remote `CodexWebSocketConfiguration` requires a nonempty tunnel-header provider. The marker in this Tailscale example satisfies that API shape; it is **not** an authenticator and app-server does not verify it. The actual network access check is Tailscale membership plus tailnet policy; the actual application check is app-server's bearer token. Do not use the marker as an access decision in another proxy. The SDK uses the platform TLS trust store and refreshes provider values on reconnect.

## Operation and cleanup

- Keep Tailscale connected on the Mac and iPhone, and keep the Mac awake when remote access is needed. A user LaunchAgent needs that user session; arrange a suitable persistent host session for unattended service.
- Confirm the loopback listener with `nc -G 3 -z 127.0.0.1 4500`, Serve with `tailscale serve status`, and the remote route with an authenticated WSS client. A TCP check alone does not prove bearer authorization or app-server RPCs.
- After changing the token file, restart the listener and reprovision the iPhone token. Revoke lost devices in the tailnet and rotate the bearer.
- To remove this route, stop the listener and remove its Serve mapping. `tailscale serve reset` clears **all** Serve configuration on that node, so use it only if this is the only service. Never replace Serve with `tailscale funnel` for a private app.
