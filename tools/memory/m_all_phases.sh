#!/usr/bin/env bash
# Run all six memory-phase gates in order. Honors CODEXKIT_MEMORY_QUICK for
# the long-running soak phases.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

phases=(m_phase0_verify.sh m_phase1_store.sh m_phase2_ingest_soak.sh
        m_phase3_process_score.sh m_phase4_retrieve_mcp.sh
        m_phase5_braingate.sh m_phase6_hardening.sh)

failed=0
for p in "${phases[@]}"; do
    echo "==================================================================="
    echo "[memory all] running $p"
    echo "==================================================================="
    if ! ./"$p"; then
        echo "[memory all] phase $p FAILED"
        failed=$((failed+1))
    fi
done

if (( failed > 0 )); then
    echo "[memory all] $failed phase(s) failed"
    exit 1
fi
echo "[memory all] all phases passed"
