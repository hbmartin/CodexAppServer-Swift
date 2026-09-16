#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_codex_home="${CODEX_HOME:-$HOME/.codex}"
source_auth="$source_codex_home/auth.json"
temporary_home=""
temporary_real_home=""
environment_id=""

command -v codex >/dev/null 2>&1 || { echo "codex CLI is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[[ -f "$source_auth" ]] || { echo "Codex login is required at $source_auth" >&2; exit 2; }

native_codex="$source_codex_home/packages/standalone/current/bin/codex"
if [[ ! -x "$native_codex" ]]; then
  candidate="$(command -v codex)"
  if file "$candidate" | grep -q 'Mach-O'; then native_codex="$candidate"; else
    echo "a native Codex standalone executable is required for daemon Remote Control" >&2
    exit 2
  fi
fi

temporary_home="$(mktemp -d /tmp/codex-sdk-remote-live.XXXXXX)"
temporary_real_home="$(cd "$temporary_home" && pwd -P)"

cleanup() {
  CODEX_HOME="$temporary_home" "$native_codex" remote-control stop --json >/dev/null 2>&1 || true
  if [[ -n "$environment_id" && -x "$repo_dir/.build/debug/codex-app-server-cli" ]]; then
    "$repo_dir/.build/debug/codex-app-server-cli" remote remove "$environment_id" --auth-file "$source_auth" --json >/dev/null 2>&1 || true
  fi
  # Durable daemon bootstrap leaves its isolated updater alive after the app-server stops.
  # Match only this UUID-scoped temporary home before removing it.
  pkill -TERM -f "^$temporary_real_home/packages/standalone/current/bin/codex app-server daemon pid-update-loop$" >/dev/null 2>&1 || true
  python3 - "$temporary_home" <<'PY'
import shutil, sys, time
time.sleep(0.2)
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

ln -s "$source_auth" "$temporary_home/auth.json"
mkdir -p "$temporary_home/packages/standalone/releases/sdk-live/bin"
ln -s "$native_codex" "$temporary_home/packages/standalone/releases/sdk-live/bin/codex"
ln -s "$temporary_home/packages/standalone/releases/sdk-live" "$temporary_home/packages/standalone/current"

start_json="$(CODEX_HOME="$temporary_home" "$native_codex" remote-control start --json)"
environment_id="$(jq -r '.environmentId // empty' <<<"$start_json")"
if [[ -z "$environment_id" ]]; then
  echo "could not read the isolated Remote Control environment ID from: $start_json" >&2
  exit 2
fi

cd "$repo_dir"
RUN_CODEX_REMOTE_LIVE_TESTS=1 \
CODEX_REMOTE_EXPECTED_ENVIRONMENT_ID="$environment_id" \
swift test -Xswiftc -strict-concurrency=complete --filter authenticatedRemoteControlHostDiscovery
