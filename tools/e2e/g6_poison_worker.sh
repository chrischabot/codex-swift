#!/usr/bin/env bash
# Production spawned-worker poison containment gate.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool python3

gate_start "Build release binaries for poison-worker containment"
run swift build -c release

evidence_args=()
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_args=(--evidence-file "$CODEXKIT_EVIDENCE_DIR/g6_poison_worker-$(date -u +%Y%m%dT%H%M%SZ)-$$.json")
fi

gate_start "Run spawned-worker poison containment"
run python3 tools/e2e/poison_worker_driver.py "${evidence_args[@]}"

echo
echo "g6_poison_worker OK"
