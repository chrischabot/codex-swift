#!/usr/bin/env bash
# Behavioral-parity corpus gate. This keeps the executable Phase 7 gate rooted
# in the pinned Codex schema oracle plus byte-faithful prompt/persistence/tool
# scenarios that are already deterministic in the Swift harness.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Codex oracle bootstrap"
run tools/conformance/bootstrap.sh

gate_start "Codex schema/method differential"
run tools/conformance/diff.sh

gate_start "Deterministic app-server transcript replay"
run tools/conformance/replay.sh

gate_start "Release evidence verifier selftests"
run python3 tools/e2e/bounded_primitives_probe.py
run python3 tools/e2e/verify_release_evidence_selftest.py
run python3 tools/e2e/clean_machine_attestation_selftest.py
run python3 tools/e2e/notary_profile_readiness_selftest.py
run python3 tools/e2e/physical_footprint_readiness_selftest.py
run python3 tools/e2e/strict_release_readiness_selftest.py
run python3 tools/e2e/g9_strict_preflight_selftest.py
run python3 tools/e2e/g9_manifest_current_run_selftest.py

gate_start "Deterministic protocol, prompt, persistence, tools, MCP, and extension corpus"
swift_filter "SchemaParityTests|WireByteFaithfulTests|ProtocolModelTests|EndToEndTests|ResumeTests|PersistenceTests|ToolsTests|MCPTests|ExtensionAPITests|ApprovalsTests|HooksTests|PromptInjectionAdversarialTests|FailureModeTests"

swift_live_if_available

echo
echo "g5_full_corpus OK"
