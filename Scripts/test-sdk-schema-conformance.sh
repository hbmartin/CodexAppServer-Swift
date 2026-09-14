#!/usr/bin/env bash
# Exercise the source-extraction anchors without modifying the checkout.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -r "$test_dir"' EXIT
mkdir -p "$test_dir/Scripts" "$test_dir/Sources"
cp "$repo_dir/Scripts/check-sdk-schema-conformance.sh" "$test_dir/Scripts/"
cp -R "$repo_dir/Sources/CodexAppServerKit" "$test_dir/Sources/"
ln -s "$repo_dir/Schemas" "$test_dir/Schemas"
client="$test_dir/Sources/CodexAppServerKit/CodexClient.swift"
check="$test_dir/Scripts/check-sdk-schema-conformance.sh"

bash "$check" > "$test_dir/output"
for function_name in routeNotification routeServerRequest; do
    sed "s/^[[:space:]]*private func $function_name(/        private func $function_name(/" "$client" > "$test_dir/client.swift"
    mv "$test_dir/client.swift" "$client"
    bash "$check" > "$test_dir/output"
done

sed 's/private func routeServerRequest(/private func renamedServerRequest(/' "$client" > "$test_dir/client.swift"
mv "$test_dir/client.swift" "$client"
if bash "$check" > "$test_dir/output"; then
    echo 'FAIL: missing notification anchor was accepted' >&2
    exit 1
fi
grep -q 'FAIL notifications: anchor' "$test_dir/output"
if grep -q 'SDK routes methods the schema does not define' "$test_dir/output"; then
    echo 'FAIL: missing anchor produced a misleading method error' >&2
    exit 1
fi
echo 'Schema anchor regressions passed.'
