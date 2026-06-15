#!/bin/bash
# Resilient single-corpus Memory-Wiki import with --resume + restart-on-crash,
# so a long pass survives the MLX teardown segfault and any interruption.
# Usage: wiki-import-local.sh <job-id> <root> <mode> [concurrency]
#   mode: "local"  -> fully on-device (MLX embed + Qwen3 extract)
#         "split"  -> on-device nomic embed + remote OpenAI extract (fast)
# Live counts: $LOG/<job>.progress.json (rewritten after every file).
set -u

BIN=/Users/chabotc/Projects/codex-swift/.build/debug/codex-memory
LOG=/tmp/wiki-import
mkdir -p "$LOG"

job="${1:?job-id}"; root="${2:?root}"; mode="${3:-local}"; conc="${4:-1}"
prog="$LOG/$job.progress.json"

env_for_mode() {
  case "$1" in
    split)
      echo "CODEXKIT_MEMORY=1 CODEX_MEMORY_INFERENCE_BACKEND=local \
CODEX_MEMORY_SPLIT_REMOTE_EXTRACT=1 CODEX_MEMORY_EXTRACT_INFLIGHT=$conc" ;;
    *)
      echo "CODEXKIT_MEMORY=1 CODEX_MEMORY_INFERENCE_BACKEND=local" ;;
  esac
}

attempt=0; last=-1; stuck=0
while true; do
  attempt=$((attempt + 1))
  env $(env_for_mode "$mode") "$BIN" import-markdown --extract --json --resume \
    --job-id "$job" --concurrency "$conc" --progress-file "$prog" "$root" \
    >"$LOG/$job.out" 2>"$LOG/$job.err"
  code=$?
  proc=$(python3 -c "import json;print(json.load(open('$prog'))['processed'])" 2>/dev/null || echo 0)
  # COMPLETE gates on SUCCEEDED (imported+unchanged), NEVER on processed (which counts
  # failures) — else an all-failed clean-checkout run would be declared done and stamp a
  # degraded corpus authoritative. Fallback 0 so an old binary lacking the field can't
  # trip the OR clause.
  succ=$(python3 -c "import json;print(json.load(open('$prog')).get('succeeded',0))" 2>/dev/null || echo 0)
  disc=$(python3 -c "import json;print(json.load(open('$prog'))['discovered'])" 2>/dev/null || echo 999999)
  echo "[$(date +%H:%M:%S)] $job attempt=$attempt exit=$code succeeded=$succ processed=$proc/$disc"
  if [ "$code" = "0" ] || { [ "$succ" -ge "$disc" ] && [ "$disc" -gt 0 ]; }; then
    echo "[$(date +%H:%M:%S)] $job COMPLETE (succeeded=$succ/$disc)"; break
  fi
  # Stuck-detection tracks forward progress on SUCCEEDED so a corpus that only ever FAILS
  # is detected as stuck and aborted (visible failure) rather than looping forever.
  if [ "$succ" -le "$last" ]; then stuck=$((stuck + 1)); else stuck=0; fi
  last=$succ
  if [ "$stuck" -ge 4 ]; then
    echo "[$(date +%H:%M:%S)] $job STUCK at $proc/$disc — aborting (see $LOG/$job.err)"; break
  fi
  sleep 3
done
