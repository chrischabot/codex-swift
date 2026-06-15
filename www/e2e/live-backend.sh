#!/bin/bash
# Live backend test for the WS job stream: starts a FULLY ISOLATED codexd
# (temp CODEX_HOME + temp CODEX_MEMORY_DB + alt port 8444 + a stub codex-memory),
# connects a real WSS client (e2e/live-backend.mjs), calls wiki/research/start, and
# asserts the job streams wiki/job/event → wiki/job/done. Never touches a running
# daemon or the production store.
#
#   www/e2e/live-backend.sh            # fast/free: stub codex-memory (scripted NDJSON)
#   REAL=1 www/e2e/live-backend.sh     # true live research (writes the isolated store, hits the web/LLM)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PORT=8444
HOME_DIR="$(mktemp -d /tmp/codexd-live.XXXXXX)"
DB="$HOME_DIR/memory.db"
LOG="$HOME_DIR/codexd.log"
trap 'pkill -f "listen-web=127.0.0.1:$PORT" 2>/dev/null || true; rm -rf "$HOME_DIR"' EXIT

# self-signed loopback cert (codexd's auto-gen is flaky in some envs)
mkdir -p "$HOME_DIR/web-gateway"
openssl req -x509 -newkey rsa:2048 -keyout "$HOME_DIR/web-gateway/key.pem" \
  -out "$HOME_DIR/web-gateway/cert.pem" -days 1 -nodes -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null

# stub codex-memory (default): emits the --progress NDJSON sequence, no store writes
STUB="$HOME_DIR/stub.sh"
cat > "$STUB" <<'EOS'
#!/bin/sh
printf '{"type":"event","kind":"started","mode":"topic"}\n'; sleep 0.1
printf '{"type":"event","kind":"sources","round":1,"count":3}\n'; sleep 0.1
printf '{"type":"event","kind":"compiled","round":1,"written":2,"claims":8}\n'; sleep 0.1
printf '{"type":"result","status":"completed","rounds":1,"sources":3,"pages":2,"finalScore":44}\n'
EOS
chmod +x "$STUB"
MEM_BIN="$STUB"
[ "${REAL:-0}" = "1" ] && MEM_BIN="$REPO/.build/debug/codex-memory"

# start the isolated daemon — keep stdin OPEN (the stdio transport shuts down on EOF)
( tail -f /dev/null | env CODEX_HOME="$HOME_DIR" CODEX_MEMORY_DB="$DB" CODEXKIT_MEMORY=1 \
    CODEXKIT_MLX="${CODEXKIT_MLX:-0}" CODEX_MEMORY_BIN="$MEM_BIN" CODEXKIT_LISTEN_WEB="127.0.0.1:$PORT" \
    "$REPO/.build/debug/codexd" --listen-web="127.0.0.1:$PORT" > "$LOG" 2>&1 ) &
for i in $(seq 1 30); do
  lsof -nP -iTCP:$PORT 2>/dev/null | grep -q LISTEN && break
  sleep 1
done
lsof -nP -iTCP:$PORT 2>/dev/null | grep -q LISTEN || { echo "codexd did not bind :$PORT"; tail -20 "$LOG"; exit 1; }

node "$REPO/www/e2e/live-backend.mjs" "wss://127.0.0.1:$PORT/ws"
