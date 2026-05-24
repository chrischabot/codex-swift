#!/usr/bin/env bash
# Phase 0 — Verify-on-install (CI gate).
# Runs `codex-memory verify`, asserts the report ends with PASS, and stamps
# evidence with the resolved sqlite-vec status and embedder dimension.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

set +e
report=".build/codex-memory-verify.log"
.build/debug/codex-memory verify > "$report" 2>&1
rc=$?
set -e

cat "$report"
write_evidence 0 verify.log "$(cat "$report")"

# PASS criteria: exit-0 AND the last printed line begins with "[PASS]".
last_line="$(tail -n1 "$report")"
ok="false"
if [[ "$rc" -eq 0 && "$last_line" == \[PASS\]* ]]; then ok="true"; fi

write_evidence 0 result.json "{\"rc\":$rc,\"ok\":$ok,\"summary\":\"$last_line\"}"
pass_or_fail "$ok" 0 "verify rc=$rc summary=\"$last_line\""
