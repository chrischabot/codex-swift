#!/usr/bin/env bash
# Baseline macOS completion gate: release build, full non-live suite, daemon
# smokes, and live OpenAI coverage whenever OPENAI_API_KEY is present.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Release build"
run swift build -c release

gate_start "Non-live harness suite"
swift_non_live

gate_start "Deterministic stdio smoke"
run scripts/codexd-stdio-smoke.sh

gate_start "Loopback WebSocket smoke"
run scripts/codexd-ws-smoke.sh

gate_start "Unix-domain WebSocket smoke"
run scripts/codexd-uds-smoke.sh

gate_start "Live stdio smoke"
run scripts/codexd-stdio-live-smoke.sh

swift_live_if_available

echo
echo "g0_baseline OK"
