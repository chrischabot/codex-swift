#!/usr/bin/env bash
# Auth, broker, MCP, and memories gate. Live memory/citation flows run through
# the shared live selector when OPENAI_API_KEY is present.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Auth, broker, MCP, memory, and hook tests"
run swift build --product codex-broker
swift_filter "AuthTests|BrokerTests|MCPTests|Mcp|HarnessTasksTests|HooksTests|Memories|LiveTests.testRequestBodyCacheKeyAndToolMapping"

if live_available; then
  gate_start "Live memory and MCP coverage"
  swift_filter "LiveTests.testLiveMemoriesConsolidation|LiveTests.testLiveMcpProxyToolCall|LiveDeepTests.testLiveMemoryToolCitation"
else
  echo "SKIP: OPENAI_API_KEY not set (live memory/MCP tests skipped)"
fi

echo
echo "g4_auth_broker_memories OK"
