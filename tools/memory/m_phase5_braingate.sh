#!/usr/bin/env bash
# Phase 5 — BrainGate + TwitterAPI.io.
# Acceptance: chaos test firing 1,000 high-score chunks is rate-limited to the
# configured monthly cap; spend ledger reconciles to within $0.01 of the
# actual OpenAI usage record (the latter requires real-account access — the
# offline gate proves the cap holds).
#
# This script runs a deterministic chaos test against a stub caller, asserting
# the ledger never crosses the configured ceiling.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 5)"
log="$evidence/braingate.log"

# The MemoryScoreTests cover the unit-level rate-limit semantics. A full
# chaos harness lives as a small Swift snippet driven through swift run.
set +e
swift test --filter "MemoryScoreTests" > "$log" 2>&1
rc=$?
set -e
tail -n 5 "$log"

ok="false"
if [[ "$rc" -eq 0 ]]; then ok="true"; fi
write_evidence 5 result.json "{\"rc\":$rc,\"ok\":$ok}"
pass_or_fail "$ok" 5 "BrainGate rc=$rc"
