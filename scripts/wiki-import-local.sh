#!/bin/bash
# Resilient on-device Memory-Wiki import: runs devrel-almanac then agentwiki
# fully locally (MLX), with --resume + restart-on-crash so the multi-day
# agentwiki pass survives the MLX teardown segfault and any interruption.
# Live counts land in $LOG/<job>.progress.json (rewritten after every file).
set -u

BIN=/Users/chabotc/Projects/codex-swift/.build/debug/codex-memory
STAGE="$HOME/Library/Caches/CodexKit-wiki-import"
LOG=/tmp/wiki-import
mkdir -p "$LOG"

run_corpus() {
  local job="$1" root="$2" total="$3"
  local prog="$LOG/$job.progress.json"
  local attempt=0 last=-1 stuck=0
  while true; do
    attempt=$((attempt + 1))
    CODEXKIT_MEMORY=1 CODEX_MEMORY_INFERENCE_BACKEND=local "$BIN" \
      import-markdown --extract --json --resume --job-id "$job" \
      --progress-file "$prog" "$root" >"$LOG/$job.out" 2>"$LOG/$job.err"
    local code=$?
    local proc
    proc=$(python3 -c "import json;print(json.load(open('$prog'))['processed'])" 2>/dev/null || echo 0)
    echo "[$(date +%H:%M:%S)] $job attempt=$attempt exit=$code processed=$proc/$total"
    # Success, or every file attempted (teardown crash after the work is done).
    if [ "$code" = "0" ] || [ "$proc" -ge "$total" ]; then
      echo "[$(date +%H:%M:%S)] $job COMPLETE (processed=$proc)"
      return 0
    fi
    # Infinite-loop guard: bail if a mid-file crash stops making progress.
    if [ "$proc" -le "$last" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    last=$proc
    if [ "$stuck" -ge 4 ]; then
      echo "[$(date +%H:%M:%S)] $job STUCK at $proc/$total — aborting (see $LOG/$job.err)"
      return 1
    fi
    sleep 3
  done
}

echo "=== Memory-Wiki local import starting $(date) ==="
run_corpus wiki-devrel "$STAGE/devrel" 122
echo "=== devrel done; starting agentwiki (this is the multi-day pass) ==="
run_corpus wiki-ai "$STAGE/ai" 4877
echo "=== ALL DONE $(date) ==="
