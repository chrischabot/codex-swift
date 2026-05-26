#!/usr/bin/env bash
# Start (or reuse) the Swift codexd app-server and connect the Codex CLI to it.
#
# Environment knobs:
#   CODEX_HOME                  Codex home to use; defaults to ~/.codex
#   CODEX_CLI                   Codex CLI executable; defaults to codex
#   CODEXD_BIN                  Existing codexd binary to run
#   CODEXD_BUILD_CONFIGURATION  SwiftPM build config; defaults to release
#   CODEXD_NO_BUILD=1           Do not build if codexd is missing
#   CODEXD_FORCE_REPLACE=1      Replace a live non-CodexKit socket
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CLI="${CODEX_CLI:-codex}"
CODEXD_BUILD_CONFIGURATION="${CODEXD_BUILD_CONFIGURATION:-release}"
CONTROL_DIR="$CODEX_HOME/app-server-control"
SOCKET_PATH="$CONTROL_DIR/app-server-control.sock"
PID_FILE="$CONTROL_DIR/codexd.pid"
LOG_DIR="$CONTROL_DIR/logs"
OUT_LOG="$LOG_DIR/codexd.out.log"
ERR_LOG="$LOG_DIR/codexd.err.log"

die() {
  echo "codexd-cli: $*" >&2
  exit 1
}

note() {
  echo "codexd-cli: $*" >&2
}

pid_is_running() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

managed_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(tr -d '[:space:]' <"$PID_FILE" 2>/dev/null || true)"
  pid_is_running "$pid" || return 1
  printf '%s\n' "$pid"
}

probe_socket() {
  python3 - "$SOCKET_PATH" <<'PY'
import json
import os
import socket
import sys
import time

sock_path = sys.argv[1]
if not os.path.exists(sock_path):
    sys.exit(1)

def recv_until(sock, marker, limit=65536, timeout=2.0):
    deadline = time.time() + timeout
    data = b""
    while marker not in data:
        if len(data) > limit:
            raise RuntimeError("response too large")
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError("timed out waiting for response")
        sock.settimeout(min(0.25, remaining))
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    return data

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1.0)
    s.connect(sock_path)
except OSError as exc:
    print(f"stale or unreachable socket: {exc}", file=sys.stderr)
    sys.exit(3)

try:
    with s:
        s.sendall(b"GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
        ready = recv_until(s, b"\r\n\r\n")
        if b"200 OK" not in ready or b'{"status":"ok"}' not in ready:
            print("socket answered, but /readyz was not healthy", file=sys.stderr)
            sys.exit(2)
except Exception as exc:
    print(f"socket answered, but health probe failed: {exc}", file=sys.stderr)
    sys.exit(2)

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(sock_path)
    with s:
        req = {
            "id": 1,
            "method": "initialize",
            "params": {"clientInfo": {"name": "codexd-cli-health"}},
        }
        s.sendall(json.dumps(req, separators=(",", ":")).encode() + b"\n")
        line = recv_until(s, b"\n", timeout=3.0).split(b"\n", 1)[0]
        msg = json.loads(line.decode())
except Exception as exc:
    print(f"socket is healthy but does not speak Swift codexd JSONL: {exc}", file=sys.stderr)
    sys.exit(2)

user_agent = msg.get("result", {}).get("userAgent", "")
if not user_agent.startswith("CodexKit/"):
    print(f"socket is healthy but is not Swift codexd: userAgent={user_agent!r}", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
PY
}

find_built_codexd() {
  local candidates=(
    "$SCRIPT_DIR/.build/$CODEXD_BUILD_CONFIGURATION/codexd"
    "$SCRIPT_DIR/.build/arm64-apple-macosx/$CODEXD_BUILD_CONFIGURATION/codexd"
    "$SCRIPT_DIR/.build/x86_64-apple-macosx/$CODEXD_BUILD_CONFIGURATION/codexd"
    "$SCRIPT_DIR/.build/debug/codexd"
    "$SCRIPT_DIR/.build/arm64-apple-macosx/debug/codexd"
    "$SCRIPT_DIR/.build/x86_64-apple-macosx/debug/codexd"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

build_codexd() {
  [[ "${CODEXD_NO_BUILD:-}" == "1" ]] && return 1
  note "building Swift daemon binaries ($CODEXD_BUILD_CONFIGURATION)"
  (
    cd "$SCRIPT_DIR"
    swift build -c "$CODEXD_BUILD_CONFIGURATION"
  )
}

resolve_codexd_bin() {
  if [[ -n "${CODEXD_BIN:-}" ]]; then
    [[ -x "$CODEXD_BIN" ]] || die "CODEXD_BIN is not executable: $CODEXD_BIN"
    printf '%s\n' "$CODEXD_BIN"
    return 0
  fi

  if find_built_codexd; then
    return 0
  fi

  build_codexd || die "codexd is missing and CODEXD_NO_BUILD=1 is set"
  find_built_codexd || die "swift build completed, but no codexd binary was found"
}

require_companion_binaries() {
  local codexd_bin="$1"
  local bin_dir
  bin_dir="$(cd "$(dirname "$codexd_bin")" && pwd)"

  if [[ "${CODEXKIT_IN_PROCESS_WORKERS:-}" != "1" ]]; then
    local session_bin="${CODEXKIT_SESSION_BIN:-$bin_dir/codex-session}"
    [[ -x "$session_bin" ]] || die "missing codex-session companion binary: $session_bin"
  fi

  case "${CODEXKIT_MEMORY:-}" in
    0|false|FALSE|no|NO|off|OFF) return 0 ;;
  esac

  if [[ ! -x "$bin_dir/codex-memory" && ! -x "$SCRIPT_DIR/.build/debug/codex-memory" ]]; then
    die "missing codex-memory companion binary next to codexd; set CODEXKIT_MEMORY=0 to disable it"
  fi
}

stop_managed_daemon() {
  local pid="${1:-}"
  if ! pid_is_running "$pid"; then
    rm -f "$PID_FILE"
    return 0
  fi

  note "stopping managed codexd pid $pid"
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    if ! pid_is_running "$pid"; then
      rm -f "$PID_FILE"
      return 0
    fi
    sleep 0.125
  done

  note "managed codexd pid $pid did not stop; sending SIGKILL"
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
}

start_daemon() {
  local codexd_bin="$1"
  mkdir -p "$CONTROL_DIR" "$LOG_DIR"

  note "starting Swift codexd on unix://$SOCKET_PATH"
  (
    cd "$SCRIPT_DIR"
    CODEX_HOME="$CODEX_HOME" nohup "$codexd_bin" --listen unix:// \
      >"$OUT_LOG" 2>"$ERR_LOG" < /dev/null &
    echo "$!" >"$PID_FILE"
  )
}

ensure_daemon() {
  local codexd_bin="$1"
  local pid=""
  pid="$(managed_pid 2>/dev/null || true)"

  set +e
  local probe_output
  probe_output="$(probe_socket 2>&1)"
  local probe_status=$?
  set -e

  if [[ "$probe_status" -eq 0 ]]; then
    note "Swift codexd is healthy"
    return 0
  fi

  if [[ "$probe_status" -eq 2 && -z "$pid" && "${CODEXD_FORCE_REPLACE:-}" != "1" ]]; then
    die "$probe_output
Refusing to replace a live app-server socket not proven to be this script's Swift codexd.
Use a separate CODEX_HOME, stop the other app-server, or set CODEXD_FORCE_REPLACE=1."
  fi

  if [[ -n "$pid" ]]; then
    note "managed codexd is unhealthy: $probe_output"
    stop_managed_daemon "$pid"
  elif [[ "$probe_status" -eq 3 ]]; then
    note "removing stale socket at $SOCKET_PATH"
    rm -f "$SOCKET_PATH"
  fi

  start_daemon "$codexd_bin"

  local started_pid
  started_pid="$(tr -d '[:space:]' <"$PID_FILE")"
  for _ in $(seq 1 120); do
    set +e
    probe_output="$(probe_socket 2>&1)"
    probe_status=$?
    set -e
    if [[ "$probe_status" -eq 0 ]]; then
      note "Swift codexd is ready (pid $started_pid)"
      return 0
    fi
    if ! pid_is_running "$started_pid"; then
      tail -n 80 "$ERR_LOG" >&2 2>/dev/null || true
      die "codexd exited before becoming healthy"
    fi
    sleep 0.25
  done

  tail -n 80 "$ERR_LOG" >&2 2>/dev/null || true
  die "timed out waiting for Swift codexd to become healthy: $probe_output"
}

command -v "$CODEX_CLI" >/dev/null 2>&1 || die "Codex CLI not found: $CODEX_CLI"
[[ -n "${OPENAI_API_KEY:-}" || "${CODEXKIT_MOCK:-}" == "1" ]] \
  || die "OPENAI_API_KEY is not set (or set CODEXKIT_MOCK=1 for a mock backend)"

CODEXD_BIN="$(resolve_codexd_bin)"
require_companion_binaries "$CODEXD_BIN"
ensure_daemon "$CODEXD_BIN"

export CODEX_HOME
exec "$CODEX_CLI" --remote "unix://$SOCKET_PATH" "$@"
