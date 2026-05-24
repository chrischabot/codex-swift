#!/usr/bin/env bash
# Bootstrap the local Codex oracle metadata used by conformance gates.
#
# This script intentionally pins the oracle to the checked-out local Codex tree.
# When that tree is not a git checkout, the pin falls back to the SHA-256 of the
# authoritative ClientRequest schema so drift is still mechanical and explicit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CODEX_TREE="$(cd "$REPO_ROOT/.." && pwd)/codex"
CODEX_TREE="${CODEX_TREE:-$DEFAULT_CODEX_TREE}"
SCHEMA_DIR="${CODEX_SCHEMA_DIR:-$CODEX_TREE/codex-rs/app-server-protocol/schema/json}"
CLIENT_REQUEST="$SCHEMA_DIR/ClientRequest.json"
TYPESCRIPT_DIR="$(cd "$SCHEMA_DIR/.." && pwd)/typescript"
GOLDEN_DIR="$SCRIPT_DIR/golden"
PIN_FILE="$SCRIPT_DIR/PINNED_REV"

if [[ ! -f "$CLIENT_REQUEST" ]]; then
  echo "FAIL: pinned Codex ClientRequest schema not found: $CLIENT_REQUEST" >&2
  echo "Set CODEX_TREE or CODEX_SCHEMA_DIR to the local Codex oracle checkout." >&2
  exit 66
fi
if [[ ! -d "$TYPESCRIPT_DIR" ]]; then
  echo "FAIL: pinned Codex generated TypeScript schema directory not found: $TYPESCRIPT_DIR" >&2
  echo "Set CODEX_TREE or CODEX_SCHEMA_DIR to the local Codex oracle checkout." >&2
  exit 66
fi

mkdir -p "$GOLDEN_DIR"

PIN="$(
  CODEX_TREE="$CODEX_TREE" CLIENT_REQUEST="$CLIENT_REQUEST" PYTHONPATH="$SCRIPT_DIR" python3 - <<'PY'
import os
from pathlib import Path
from schema_tools import pin_for

print(pin_for(Path(os.environ["CODEX_TREE"]), Path(os.environ["CLIENT_REQUEST"])))
PY
)"

if [[ ! -f "$PIN_FILE" ]]; then
  printf '%s\n' "$PIN" > "$PIN_FILE"
elif [[ "$(cat "$PIN_FILE")" != "$PIN" ]]; then
  echo "FAIL: existing PINNED_REV does not match the local oracle." >&2
  echo "  existing: $(cat "$PIN_FILE")" >&2
  echo "  current:  $PIN" >&2
  echo "Move to the pinned oracle tree or intentionally refresh $PIN_FILE." >&2
  exit 67
fi

PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" golden \
  --codex-tree "$CODEX_TREE" \
  --schema-dir "$SCHEMA_DIR" \
  --golden-dir "$GOLDEN_DIR" \
  --pin "$PIN"

echo "conformance bootstrap OK"
echo "pin=$PIN"
echo "schema=$CLIENT_REQUEST"
