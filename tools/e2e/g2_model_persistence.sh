#!/usr/bin/env bash
# Model + persistence gate: model transport shaping/failures, durable rollout,
# resume, prompt continuity, and live multi-turn sessions when credentials
# are available.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Model client, persistence, resume, and harness continuity tests"
swift_filter "ModelClientTests|OpenAIClientFailureTests|PersistenceTests|PersistenceAdversarialTests|ResumeTests|HarnessCoreTests|WireByteFaithfulTests"

swift_live_if_available

echo
echo "g2_model_persistence OK"
