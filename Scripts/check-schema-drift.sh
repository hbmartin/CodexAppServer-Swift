#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
snapshot_dir="$repo_dir/Schemas/0.146.0"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

codex app-server generate-json-schema --experimental --out "$temporary_dir"

diff -u \
  <(cd "$snapshot_dir" && find . -type f -name '*.json' | sort) \
  <(cd "$temporary_dir" && find . -type f -name '*.json' | sort)

while IFS= read -r relative_path; do
  diff -u \
    <(jq --sort-keys . "$snapshot_dir/$relative_path") \
    <(jq --sort-keys . "$temporary_dir/$relative_path")
done < <(cd "$snapshot_dir" && find . -type f -name '*.json' | sort)
