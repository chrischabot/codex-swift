#!/usr/bin/env bash
# Local signing gate: stage release binaries, ad-hoc sign them with hardened
# runtime + generated entitlements, then verify strict signatures and metadata.
#
# This does not replace Developer ID signing, notarization, stapling, or
# Gatekeeper assessment. It makes the local signing path executable and catches
# bad entitlements, missing hardened-runtime flags, and invalid Mach-O signatures
# before the release-only credentials are involved.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "codesign smoke requires macOS; skipping on $(uname -s)"
  exit 0
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 69
  fi
}

require_tool codesign
require_tool rg

gate_start "Build release binaries for codesign smoke"
run swift build -c release

WORK="$(mktemp -d /tmp/codexkit-codesign.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

gate_start "Stage lifecycle artifacts for codesign smoke"
run scripts/codexkit-lifecycle.sh stage-install \
  --destdir "$WORK/stage" \
  --build-dir .build/release \
  --codex-home "$WORK/home"

STAGED_ROOT="$WORK/stage/Library/Application Support/CodexKit"

for name in codexd codex-broker codex-session; do
  binary="$STAGED_ROOT/bin/$name"
  entitlements="$WORK/stage/entitlements/$name.entitlements"

  gate_start "Ad-hoc sign and verify $name"
  test -x "$binary"
  test -f "$entitlements"

  run codesign --force --options runtime --entitlements "$entitlements" --sign - "$binary"
  run codesign --verify --strict --verbose=2 "$binary"

  display="$WORK/$name.codesign-display.txt"
  ent_dump="$WORK/$name.entitlements.txt"
  codesign -d --verbose=4 "$binary" >"$display" 2>&1
  codesign -d --entitlements :- "$binary" >"$ent_dump" 2>&1

  rg -q 'flags=.*runtime' "$display"
  rg -q 'TeamIdentifier=not set' "$display"
  rg -q '<key>com.apple.security.network.client</key><true/>' "$ent_dump"
  rg -q '<key>com.apple.security.network.server</key><true/>' "$ent_dump"
  rg -q '<key>com.apple.security.cs.disable-library-validation</key><false/>' "$ent_dump"
done

echo
echo "g6_codesign_smoke OK"
