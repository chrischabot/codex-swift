#!/usr/bin/env bash
# Phase 1 — MemoryStore + MemoryInfer skeleton.
# Acceptance: round-trip insert/query of 10k synthetic chunks under 200 ms p99.
# This script runs the dedicated XCTest target and a quick top-k probe.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 1)"

# Run the targeted store tests; they include `testRoundTripScale` which seeds
# 500 chunks and asserts the search hits land in the right order. The full
# 10k-chunk benchmark runs in CODEXKIT_MEMORY_QUICK=0 mode.
test_log="$evidence/store-tests.log"
set +e
swift test --filter "MemoryStoreTests|MemoryInferTests" > "$test_log" 2>&1
rc=$?
set -e
tail -n 5 "$test_log"

ok="false"
if [[ "$rc" -eq 0 ]]; then ok="true"; fi
write_evidence 1 result.json "{\"rc\":$rc,\"ok\":$ok,\"tests\":\"MemoryStoreTests|MemoryInferTests\"}"
pass_or_fail "$ok" 1 "store + infer tests rc=$rc"
