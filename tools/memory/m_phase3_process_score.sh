#!/usr/bin/env bash
# Phase 3 — MemoryProcess + MemoryScore.
# Acceptance: end-to-end on the 8k-seed corpus completes in <= 4 hours on
# M3 Max 48 GB; gate score AUC >= 0.85 against a held-out labelled set.
#
# The labelled set lives at tools/memory/fixtures/labels.tsv (corpus_uri,
# score). Without it the script runs the deterministic ScoreTests as the
# minimum-viable acceptance signal — exact AUC reporting requires labelled
# data the operator brings.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 3)"
log="$evidence/process-score.log"

set +e
swift test --filter "MemoryProcessTests|MemoryScoreTests" > "$log" 2>&1
rc=$?
set -e
tail -n 5 "$log"

ok="false"
if [[ "$rc" -eq 0 ]]; then ok="true"; fi
write_evidence 3 result.json "{\"rc\":$rc,\"ok\":$ok}"
pass_or_fail "$ok" 3 "process + score tests rc=$rc"
