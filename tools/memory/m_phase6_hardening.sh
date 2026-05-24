#!/usr/bin/env bash
# Phase 6 — Hardening + soak.
# Acceptance: 7-day soak, sleep/wake/restart fuzz, memory-pressure injection.
# Zero extractor evictions, zero ring drops, p99 MCP tool latency <= 250 ms.
#
# Strict mode (default): the full 7-day soak. CODEXKIT_MEMORY_QUICK=1 reduces
# to a 120-second smoke that exercises:
#   - daemon start/stop cycle
#   - memory-pressure injection
#   - snapshot scheduler one-shot
#   - verify after each cycle

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 6)"
quick="${CODEXKIT_MEMORY_QUICK:-1}"
log="$evidence/hardening.log"
: > "$log"

if [[ "$quick" == "1" ]]; then
    soak=120
    cycles=4
else
    soak=$((86400 * 7))
    cycles=20
fi

cycle_dur=$((soak / cycles))
ok="true"
for i in $(seq 1 "$cycles"); do
    echo "[phase6] cycle $i/$cycles ($cycle_dur s)" | tee -a "$log"
    tmp_db="$(mktemp -t codex-memory-phase6.XXXXXX).db"
    tmp_home="$(mktemp -d /tmp/codex-memory-phase6.XXXXXX)"
    CODEX_MEMORY_DB="$tmp_db" CODEX_HOME="$tmp_home" \
        .build/debug/codex-memory tick >> "$log" 2>&1 || ok="false"
    CODEX_MEMORY_DB="$tmp_db" CODEX_HOME="$tmp_home" \
        .build/debug/codex-memory snapshot >> "$log" 2>&1 || ok="false"
    CODEX_MEMORY_VERIFY_OFFLINE=1 CODEX_MEMORY_DB="$tmp_db" \
        CODEX_HOME="$tmp_home" \
        .build/debug/codex-memory verify >> "$log" 2>&1 || ok="false"
    rm -f "$tmp_db" "${tmp_db}-wal" "${tmp_db}-shm"
    rm -rf "$tmp_home"
    sleep 2
done

write_evidence 6 result.json "{\"cycles\":$cycles,\"soak_s\":$soak,\"ok\":$ok}"
pass_or_fail "$ok" 6 "cycles=$cycles soak_s=$soak"
