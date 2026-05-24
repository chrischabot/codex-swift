#!/usr/bin/env bash
# Drives the real `codexd` binary over stdio (Codex default transport) and
# asserts wire-contract behavior without a JSON parser. Portable: codexd
# exits on stdin EOF; a pure-bash watchdog guards against a hang (no GNU
# `timeout` dependency, so this runs identically on macOS and Linux).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

WORK="$(mktemp -d)"
OUTF="$WORK/out.txt"
trap 'rm -rf "$WORK"' EXIT

INPUT=$'{"id":1,"method":"thread/list","params":{}}\n{"id":2,"method":"initialize","params":{"clientInfo":{"name":"smoke"}}}\n'

# Run in background; stdin closes after printf so codexd reaches EOF and exits.
( printf '%s' "$INPUT" | CODEXKIT_MOCK=1 CODEX_HOME="$WORK/home" \
    swift run codexd >"$OUTF" 2>/dev/null ) &
RUN_PID=$!

# Pure-bash watchdog: kill the run if it has not finished within the budget.
( for _ in {1..60}; do
    kill -0 "$RUN_PID" 2>/dev/null || exit 0
    sleep 1
  done
  kill -9 "$RUN_PID" 2>/dev/null || true ) &
WD_PID=$!

wait "$RUN_PID" 2>/dev/null || true
kill "$WD_PID" 2>/dev/null || true

echo "--- codexd stdout ---"
cat "$OUTF" || true

grep -q '"Not initialized"' "$OUTF" \
  || { echo "FAIL: expected 'Not initialized' before initialize"; exit 1; }
grep -q '"userAgent"' "$OUTF" \
  || { echo "FAIL: expected initialize result with userAgent"; exit 1; }

echo "SMOKE OK"