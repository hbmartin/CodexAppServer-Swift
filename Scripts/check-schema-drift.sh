#!/usr/bin/env bash
#
# Regenerates the protocol schemas with the codex CLI on PATH and compares them to the
# vendored snapshot. Answers "has upstream moved away from the snapshot?".
#
# The complement is check-sdk-schema-conformance.sh, which answers "does the SDK still agree
# with the snapshot?" and needs no CLI.
#
# Exit codes: 0 no drift, 1 drift found, 2 tooling missing or generation failed. CI needs to
# tell those apart, so do not collapse them.
#
# Note: `jq --sort-keys` normalises object key order but not array order, so a reordered
# `oneOf` shows up as a large diff. That is deliberate — branch reordering is worth seeing.

set -uo pipefail   # deliberately not -e: report every difference, then exit once.

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
snapshot_dir="$repo_dir/Schemas/0.146.0"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

command -v jq >/dev/null 2>&1 || {
    echo "check-schema-drift: jq is required but not installed (brew install jq)" >&2
    exit 2
}
command -v codex >/dev/null 2>&1 || {
    echo "check-schema-drift: the codex CLI is required (npm install --global @openai/codex@0.146.0)" >&2
    exit 2
}
[[ -d "$snapshot_dir" ]] || { echo "check-schema-drift: no snapshot at $snapshot_dir" >&2; exit 2; }

codex app-server generate-json-schema --experimental --out "$temporary_dir" || {
    echo "check-schema-drift: schema generation failed — is the codex CLI healthy and current?" >&2
    exit 2
}

differences=0

# Added or removed schema files.
if ! diff -u \
    <(cd "$snapshot_dir" && find . -type f -name '*.json' | sort) \
    <(cd "$temporary_dir" && find . -type f -name '*.json' | sort)
then
    echo "--- the set of schema files changed (see above)"
    differences=$((differences + 1))
fi

# Per-file content. Driven off the snapshot's list, so a newly added upstream file is reported
# by the manifest diff above rather than here.
while IFS= read -r relative_path; do
    if [[ ! -f "$temporary_dir/$relative_path" ]]; then
        echo "--- removed upstream: $relative_path"
        differences=$((differences + 1))
        continue
    fi
    if ! diff -u \
        <(jq --sort-keys . "$snapshot_dir/$relative_path") \
        <(jq --sort-keys . "$temporary_dir/$relative_path")
    then
        echo "--- content changed: $relative_path"
        differences=$((differences + 1))
    fi
done < <(cd "$snapshot_dir" && find . -type f -name '*.json' | sort)

if [[ $differences -gt 0 ]]; then
    printf '\n%s schema difference(s) found. Regenerate the snapshot or pin the reviewed CLI version.\n' "$differences"
    exit 1
fi
printf 'Snapshot matches the generated schemas.\n'
