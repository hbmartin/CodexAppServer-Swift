#!/usr/bin/env bash
set -euo pipefail

if [[ "${CODEX_LUNA_MODEL:-}" != *luna* ]]; then
  echo "CODEX_LUNA_MODEL must explicitly name a Luna model" >&2
  exit 2
fi

RUN_CODEX_LIVE_TESTS=1 swift test -Xswiftc -strict-concurrency=complete --no-parallel --filter authenticatedLunaIsolatedTurnCompletes
