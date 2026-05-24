#!/usr/bin/env bash
# Tools + sandbox gate: tool router behavior, command safety, file containment,
# Seatbelt/SBPL profile generation, macOS kernel denial coverage, and hostile
# input regressions.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Tools, sandbox, and adversarial containment tests"
swift_filter "Tools|Sandbox|AdversarialTests"

echo
echo "g3_tools_sandbox OK"
