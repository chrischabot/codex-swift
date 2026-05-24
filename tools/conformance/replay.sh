#!/usr/bin/env bash
# Replay deterministic app-server transcripts against Swift and, when present,
# the pinned Codex oracle binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CODEX_TREE="$(cd "$REPO_ROOT/.." && pwd)/codex"
CODEX_TREE="${CODEX_TREE:-$DEFAULT_CODEX_TREE}"
CODEX_BIN="${CODEX_BIN:-$CODEX_TREE/codex-rs/target/debug/codex}"

cd "$REPO_ROOT"

if [[ "${CODEXKIT_REPLAY_BUILD_SWIFT:-1}" == "1" ]]; then
  echo "+ swift build -c release"
  swift build -c release
fi

SWIFT_BIN="${SWIFT_BIN:-$REPO_ROOT/.build/release/codexd}"
if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "FAIL: Swift codexd binary not found or not executable: $SWIFT_BIN" >&2
  exit 66
fi

ARGS=(--swift-bin "$SWIFT_BIN")
if [[ -x "$CODEX_BIN" ]]; then
  ARGS+=(--codex-bin "$CODEX_BIN")
else
  echo "WARN: Codex oracle binary not found at $CODEX_BIN; running Swift-only transcript validation." >&2
  echo "      Build it with: (cd $CODEX_TREE/codex-rs && cargo build -p codex-cli --bin codex)" >&2
fi

echo "+ python3 tools/conformance/transcript_replay.py ${ARGS[*]}"
python3 "$SCRIPT_DIR/transcript_replay.py" "${ARGS[@]}"

echo
echo "transcript replay OK"
