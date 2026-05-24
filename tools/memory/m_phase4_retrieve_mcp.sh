#!/usr/bin/env bash
# Phase 4 — MemoryRetrieve + MemoryMCP.
# Acceptance: external MCP client drives every tool; persona=CTO NDCG@10 >= 0.6.
# This script exercises the tool surface via the E2E test target.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ensure_built
cd "$(repo_root)"

evidence="$(evidence_dir 4)"
log="$evidence/retrieve-mcp.log"

set +e
swift test --filter "MemoryRetrieveTests|MemoryMCPTests|MemoryE2ETests" > "$log" 2>&1
rc=$?
set -e
tail -n 8 "$log"

# Sanity: confirm the seven memory.* tool names exist in the source so the
# E2E suite covers the full surface. (Test logs only mention failing
# assertions; passing tests stay quiet.)
expected=("memory.hybrid_search" "memory.graph_walk" "memory.recent_interesting"
          "memory.persona_lens" "memory.set_persona" "memory.ask_local_brain"
          "memory.escalate_to_brain")
missing=""
for tool in "${expected[@]}"; do
    grep -q "\"$tool\"" Sources/MemoryMCP/MemoryTools.swift || missing+="$tool "
done

ok="false"
if [[ "$rc" -eq 0 && -z "$missing" ]]; then ok="true"; fi
write_evidence 4 result.json "{\"rc\":$rc,\"ok\":$ok,\"missing\":\"$missing\"}"
pass_or_fail "$ok" 4 "retrieve+MCP rc=$rc missing=\"$missing\""
