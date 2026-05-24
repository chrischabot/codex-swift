#!/usr/bin/env bash
# Noisy-neighbor certification entrypoint.
#
# This is a heavier preset over g6_soak.sh: multiple concurrent spawned-worker
# sessions, large prompt payloads, rollout/SQLite durability probes, and
# optional live model turns when OPENAI_API_KEY is available.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

export CODEXKIT_SOAK_SECONDS="${CODEXKIT_NOISY_SECONDS:-${CODEXKIT_SOAK_SECONDS:-90}}"
export CODEXKIT_SOAK_SESSIONS="${CODEXKIT_NOISY_SESSIONS:-${CODEXKIT_SOAK_SESSIONS:-12}}"
export CODEXKIT_SOAK_TURNS="${CODEXKIT_NOISY_TURNS:-${CODEXKIT_SOAK_TURNS:-4}}"
export CODEXKIT_SOAK_LIVE="${CODEXKIT_NOISY_LIVE:-${CODEXKIT_SOAK_LIVE:-auto}}"
export CODEXKIT_SOAK_LIVE_SECONDS="${CODEXKIT_NOISY_LIVE_SECONDS:-${CODEXKIT_SOAK_LIVE_SECONDS:-90}}"
export CODEXKIT_SOAK_LIVE_SESSIONS="${CODEXKIT_NOISY_LIVE_SESSIONS:-${CODEXKIT_SOAK_LIVE_SESSIONS:-2}}"
export CODEXKIT_SOAK_LIVE_TURNS="${CODEXKIT_NOISY_LIVE_TURNS:-${CODEXKIT_SOAK_LIVE_TURNS:-2}}"

gate_start "Noisy-neighbor soak preset"
run tools/e2e/g6_soak.sh

echo
echo "g6_noisy OK"
