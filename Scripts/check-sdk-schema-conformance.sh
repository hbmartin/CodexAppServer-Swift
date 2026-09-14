#!/usr/bin/env bash
#
# Checks the SDK against the vendored schema snapshot.
#
# This is the complement to check-schema-drift.sh. That script answers "has upstream moved
# away from the snapshot?" and needs the codex CLI to regenerate. This one answers "does the
# SDK still agree with the snapshot it is pinned to?" and needs nothing but the checked-in
# files, so it runs on any machine and in any CI job.
#
# Every check below is green at the time it was written; a failure means a real divergence,
# not a tightening of the rules.
#
set -uo pipefail   # deliberately not -e: report every failure, then exit once.

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
snapshot_dir="$repo_dir/Schemas/0.146.0"
sources_dir="$repo_dir/Sources/CodexAppServerKit"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

command -v jq >/dev/null 2>&1 || {
    echo "check-sdk-schema-conformance: jq is required but not installed (brew install jq)" >&2
    exit 2
}
[[ -d "$snapshot_dir" ]] || { echo "check-sdk-schema-conformance: no snapshot at $snapshot_dir" >&2; exit 2; }

failures=0

fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
pass() { printf 'ok   %s\n' "$1"; }

# --- (a) every method the SDK sends must exist in the schema -------------------------------
# Both real request paths: rawRequest for typed operations, performRequest for initialize.
grep -rhoE '(rawRequest|performRequest)\(method: "[^"]+"' "$sources_dir" \
    | sed 's/.*method: "//; s/"$//' | sort -u > "$work_dir/sdk-requests"
jq -r '.oneOf[].properties.method.enum[0] // empty' "$snapshot_dir/ClientRequest.json" \
    | sort -u > "$work_dir/schema-requests"

if [[ ! -s "$work_dir/sdk-requests" ]]; then
    fail "client requests: extracted no methods from $sources_dir — did the call shape change?"
else
    unknown="$(comm -23 "$work_dir/sdk-requests" "$work_dir/schema-requests")"
    if [[ -n "$unknown" ]]; then
        fail "client requests: the SDK sends methods the schema does not define:"
        printf '       %s\n' $unknown
    else
        pass "client requests: $(wc -l < "$work_dir/sdk-requests" | tr -d ' ')/$(wc -l < "$work_dir/schema-requests" | tr -d ' ') schema methods implemented, all valid"
    fi
fi

# --- (b) every notification method the SDK routes must exist in the schema ------------------
# The slice is delimited by two anchors. Both must exist: a `sed` range whose end pattern is
# missing silently runs to end of file, which would quietly widen the slice instead of failing.
notification_anchors_ok=1
notification_start='^[[:space:]]*private func routeNotification[(]'
notification_end='^[[:space:]]*private func routeServerRequest[(]'
for anchor in "$notification_start" "$notification_end"; do
    grep -qE "$anchor" "$sources_dir/CodexClient.swift" || {
        fail "notifications: anchor \"$anchor\" not found in CodexClient.swift — was it renamed?"
        notification_anchors_ok=0
    }
done

sed -nE "/$notification_start/,/$notification_end/p" "$sources_dir/CodexClient.swift" \
    > "$work_dir/notification-route"

# Extract operands from direct `method == "..."` conditions and the Set<String> collections
# passed to `contains(method)`. Method spelling is irrelevant, so slash-free methods are kept.
{
    grep -oE 'method[[:space:]]*==[[:space:]]*"[^"]*"' "$work_dir/notification-route"
    sed -nE '/^[[:space:]]*(let|var)[^:]+:[[:space:]]*Set<String>[[:space:]]*=[[:space:]]*\[/,/^[[:space:]]*\]/p' \
        "$work_dir/notification-route"
} | grep -o '"[^"]*"' | tr -d '"' | sort -u > "$work_dir/sdk-notifications"
jq -r '.oneOf[].properties.method.enum[0] // empty' "$snapshot_dir/ServerNotification.json" \
    | sort -u > "$work_dir/schema-notifications"

if [[ $notification_anchors_ok -eq 0 ]]; then
    : # already reported above; the slice below would be unreliable
elif [[ ! -s "$work_dir/sdk-notifications" ]]; then
    fail "notifications: routeNotification slice was empty — was the function body changed?"
else
    unknown="$(comm -23 "$work_dir/sdk-notifications" "$work_dir/schema-notifications")"
    if [[ -n "$unknown" ]]; then
        fail "notifications: the SDK routes methods the schema does not define:"
        printf '       %s\n' $unknown
    else
        pass "notifications: $(wc -l < "$work_dir/sdk-notifications" | tr -d ' ')/$(wc -l < "$work_dir/schema-notifications" | tr -d ' ') schema notifications named, all valid (the rest reach the .notification catch-all)"
    fi
fi

# --- (c) CodexItemKind against the ThreadItem discriminator --------------------------------
sed -n '/public enum CodexItemKind/,/^}/p' "$sources_dir/Models.swift" \
    | grep -o 'case "[^"]*"' | sed 's/case "//; s/"//' | sort -u > "$work_dir/sdk-itemkinds"
jq -r '.definitions.ThreadItem.oneOf[].properties.type.enum[0] // empty' \
    "$snapshot_dir/v2/ItemCompletedNotification.json" | sort -u > "$work_dir/schema-itemkinds"

if [[ ! -s "$work_dir/sdk-itemkinds" ]]; then
    fail "item kinds: extracted no cases from CodexItemKind — did the enum move?"
else
    # A case the schema dropped is only a warning: it is dead, not wrong.
    retired="$(comm -23 "$work_dir/sdk-itemkinds" "$work_dir/schema-itemkinds")"
    [[ -n "$retired" ]] && { printf 'WARN item kinds: CodexItemKind has cases the schema no longer defines:\n'; printf '       %s\n' $retired; }

    # A case the schema added is a failure: it silently degrades to .unknown today.
    missing="$(comm -13 "$work_dir/sdk-itemkinds" "$work_dir/schema-itemkinds")"
    if [[ -n "$missing" ]]; then
        fail "item kinds: the schema defines cases CodexItemKind lacks:"
        printf '       %s\n' $missing
    else
        pass "item kinds: $(wc -l < "$work_dir/sdk-itemkinds" | tr -d ' ') cases match the ThreadItem discriminator"
    fi
fi

# --- (d) the server-request classifier matches by substring, so keep those unambiguous -----
# makeInteraction() in CodexClient.swift classifies with method.contains(...). The moment a new
# schema method contains one of these substrings, that method is silently misclassified. Fail
# here instead, and force a choice between exact matching and widening.
jq -r '.oneOf[].properties.method.enum[0] // empty' "$snapshot_dir/ServerRequest.json" | sort -u > "$work_dir/schema-serverrequests"
ambiguous=0
while IFS='=' read -r substring expected; do
    actual="$(grep -F "$substring" "$work_dir/schema-serverrequests" | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$actual" != "$expected" ]]; then
        fail "classifier substring \"$substring\" now matches [$actual], expected only [$expected]"
        ambiguous=1
    fi
done <<'SUBSTRINGS'
commandExecution=item/commandExecution/requestApproval
fileChange=item/fileChange/requestApproval
permissions=item/permissions/requestApproval
requestUserInput=item/tool/requestUserInput
SUBSTRINGS
[[ $ambiguous -eq 0 ]] && pass "classifier substrings: all 4 still match exactly one method"

if [[ $failures -gt 0 ]]; then
    printf '\n%s check(s) failed.\n' "$failures"
    exit 1
fi
printf '\nSDK and schema snapshot agree.\n'
