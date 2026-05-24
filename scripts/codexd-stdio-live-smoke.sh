#!/usr/bin/env bash
# Live end-to-end smoke: drives the real `codexd` binary over stdio against
# the live OpenAI Responses API (codexd auto-selects the live client when
# OPENAI_API_KEY is set). Asserts a streamed assistant delta and a
# turn/completed notification on the wire. Skips cleanly without a key.
# Pure-bash watchdog (no GNU `timeout`), runs identically on macOS and Linux.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "SKIP: OPENAI_API_KEY not set (live smoke skipped)"
  exit 0
fi

swift build >/dev/null

WORK="$(mktemp -d)"
OUTF="$WORK/out.txt"
ERRF="$WORK/err.txt"
trap 'rm -rf "$WORK"' EXIT
MODEL="${CODEXKIT_LIVE_MODEL:-gpt-4o-mini}"

# initialize -> initialized -> thread/start(model) -> turn/start.
INPUT=$(cat <<EOF
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"livesmoke"}}}
{"method":"initialized"}
{"id":2,"method":"thread/start","params":{"cwd":"$WORK","model":"$MODEL"}}
EOF
)
# thread/start's response carries the thread id; codexd is a single session
# here, so drive turn/start using the id parsed from the response stream.

( ( printf '%s\n' "$INPUT"
    # Wait for the thread id to appear, then send turn/start.
    for _ in $(seq 1 60); do
      tid=$(grep -o '"id":"thr_[^"]*"' "$OUTF" 2>/dev/null \
        | head -1 | sed 's/.*"\(thr_[^"]*\)"/\1/' || true)
      [ -n "${tid:-}" ] && break
      sleep 0.5
    done
    if [ -n "${tid:-}" ]; then
      printf '{"id":3,"method":"turn/start","params":{"threadId":"%s","input":[{"type":"text","text":"Reply with exactly: LIVE_SMOKE_OK"}]}}\n' "$tid"
    fi
    # Keep stdin open long enough for slower live API responses to stream
    # fully before EOF closes the session.
    sleep 40
  ) | CODEX_HOME="$WORK/home" swift run codexd >"$OUTF" 2>"$ERRF" ) &
RUN_PID=$!

( for _ in $(seq 1 120); do
    kill -0 "$RUN_PID" 2>/dev/null || exit 0
    sleep 1
  done
  kill -9 "$RUN_PID" 2>/dev/null || true ) &
WD_PID=$!

wait "$RUN_PID" 2>/dev/null || true
kill "$WD_PID" 2>/dev/null || true

echo "--- codexd live stdout (tail) ---"
tail -c 2000 "$OUTF" || true
echo

fail() {
  echo "FAIL: $1"
  echo "--- codexd stderr (tail) ---"
  tail -c 2000 "$ERRF" 2>/dev/null || true
  exit 1
}

grep -q '"userAgent"' "$OUTF" || fail "no initialize result"
grep -q '"turn/started"' "$OUTF" || fail "no turn/started notification"
grep -q '"turn/completed"' "$OUTF" || fail "no turn/completed notification"
grep -Eq '"item/agentMessage/delta"|"item/completed"' "$OUTF" \
  || fail "no streamed assistant content"
grep -q 'codexd workerMode=spawned' "$ERRF" \
  || fail "codexd did not report spawned worker mode"
grep -q 'codex-session worker ready' "$ERRF" \
  || fail "codex-session worker did not start"

echo "LIVE SMOKE OK"
