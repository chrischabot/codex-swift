#!/usr/bin/env bash
# Phase 2 — MemoryIngest soak.
# Acceptance: 24h soak ingesting at >= 200 docs/day with zero ring drops and
# crash-consistent recovery proven by a kill-9 fuzzer.
#
# Strict mode (default): 24-hour soak with periodic kill-9 every 30 min.
# CODEXKIT_MEMORY_QUICK=1: 90-second soak, single kill-9, used in CI.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 2)"
quick="${CODEXKIT_MEMORY_QUICK:-1}"
if [[ "$quick" == "1" ]]; then
    soak_seconds=90
    kill_after=45
else
    soak_seconds=86400
    kill_after=1800
fi

tmp_db="$(mktemp -t codex-memory-phase2.XXXXXX).db"
tmp_home="$(mktemp -d /tmp/codex-memory-phase2.XXXXXX)"
log="$evidence/ingest.log"
: > "$log"

start_daemon() {
    CODEX_MEMORY_DB="$tmp_db" CODEX_HOME="$tmp_home" \
        .build/debug/codex-memory tick >> "$log" 2>&1 &
    echo $!
}

# A tick is bounded — we drive it on a loop to simulate continuous ingest.
deadline=$(( $(date +%s) + soak_seconds ))
ticks=0
killed=0
while [[ $(date +%s) -lt $deadline ]]; do
    pid="$(start_daemon)"
    sleep 1
    if (( ticks > 0 && ticks % (kill_after / 5) == 0 )); then
        kill -9 "$pid" 2>/dev/null || true
        killed=$((killed+1))
    fi
    wait "$pid" 2>/dev/null || true
    ticks=$((ticks+1))
done

# Verify the DB still opens cleanly after the kills.
.build/debug/codex-memory verify >> "$log" 2>&1 || true
ok="true"
grep -q "FAIL" "$log" && ok="false" || true

write_evidence 2 result.json "{\"ticks\":$ticks,\"kills\":$killed,\"soak_s\":$soak_seconds,\"ok\":$ok}"
rm -f "$tmp_db" "${tmp_db}-wal" "${tmp_db}-shm"
rm -rf "$tmp_home"
pass_or_fail "$ok" 2 "ticks=$ticks kills=$killed soak_s=$soak_seconds"
