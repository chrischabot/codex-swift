#!/usr/bin/env bash
# Lifecycle packaging gate: render/stage launchd plists, entitlements, and
# signing/notarization runbook artifacts, then validate them with Swift tests.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Lifecycle artifact tests"
swift_filter "LifecycleArtifactsTests"

gate_start "Stage lifecycle artifacts from release binaries"
run swift build -c release
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
run scripts/codexkit-lifecycle.sh stage-install \
  --destdir "$WORK/stage" \
  --build-dir .build/release \
  --codex-home "$WORK/home"

test -x "$WORK/stage/Library/Application Support/CodexKit/bin/codexd"
test -x "$WORK/stage/Library/Application Support/CodexKit/bin/codex-broker"
test -x "$WORK/stage/Library/Application Support/CodexKit/bin/codex-session"
test -f "$WORK/stage/LaunchAgents/ai.igent.codexkit.codexd.plist"
test -f "$WORK/stage/entitlements/codexd.entitlements"
test -f "$WORK/stage/runbooks/sign-notarize.md"

gate_start "Ad-hoc hardened-runtime signing smoke"
run tools/e2e/g6_codesign_smoke.sh

gate_start "Developer ID signing smoke"
run tools/e2e/g6_developer_id_sign_smoke.sh

gate_start "User launchd bootstrap/restart smoke"
run tools/e2e/g6_launchd_smoke.sh

echo
echo "g6_lifecycle OK"
