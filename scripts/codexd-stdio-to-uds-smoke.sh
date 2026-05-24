#!/usr/bin/env bash
# Drives the real codexd Unix-domain app-control socket through a stdio-shaped
# JSONL bridge. This proves a `codex app-server proxy --sock` / stdio-to-UDS
# style client can use the Swift daemon without speaking sockets directly.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

WORK="$(mktemp -d /tmp/cxstdio-uds.XXXXXX)"
OUTF="$WORK/out.txt"
ERRF="$WORK/err.txt"
SOCK="$WORK/home/app-server-control/app-server-control.sock"
trap 'rm -rf "$WORK"; if [ -n "${RUN_PID:-}" ]; then kill "$RUN_PID" 2>/dev/null || true; fi' EXIT

CODEXKIT_MOCK=1 CODEX_HOME="$WORK/home" \
  .build/debug/codexd --listen unix:// >"$OUTF" 2>"$ERRF" &
RUN_PID=$!

for _ in $(seq 1 80); do
  if grep -q "codexd listening unix://$SOCK" "$ERRF" 2>/dev/null; then
    break
  fi
  kill -0 "$RUN_PID" 2>/dev/null || {
    echo "FAIL: codexd exited early"
    cat "$ERRF" || true
    exit 1
  }
  sleep 0.25
done

python3 - "$SOCK" "$WORK/workspace" <<'PY'
import json
import os
import queue
import subprocess
import sys
import threading
import time

sock_path = sys.argv[1]
workspace = sys.argv[2]
os.makedirs(workspace, exist_ok=True)

bridge_code = r'''
import os
import socket
import sys
import threading

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])

def socket_to_stdout():
    while True:
        data = sock.recv(65536)
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

t = threading.Thread(target=socket_to_stdout, daemon=True)
t.start()

try:
    for line in sys.stdin.buffer:
        sock.sendall(line)
finally:
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    t.join(timeout=5)
    sock.close()
'''

bridge = subprocess.Popen(
    [sys.executable, "-u", "-c", bridge_code, sock_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

messages: "queue.Queue[dict]" = queue.Queue()
seen: list[dict] = []
errors: list[str] = []

def read_stdout() -> None:
    assert bridge.stdout is not None
    for line in bridge.stdout:
        try:
            obj = json.loads(line)
        except Exception as exc:
            errors.append(f"invalid bridge JSON: {line[:200]} ({exc})")
            continue
        seen.append(obj)
        messages.put(obj)

def read_stderr() -> None:
    assert bridge.stderr is not None
    for line in bridge.stderr:
        errors.append(line.rstrip())

threading.Thread(target=read_stdout, daemon=True).start()
threading.Thread(target=read_stderr, daemon=True).start()

def send(obj: dict) -> None:
    assert bridge.stdin is not None
    bridge.stdin.write(json.dumps(obj, separators=(",", ":")) + "\n")
    bridge.stdin.flush()

def wait_for(predicate, timeout: float = 20) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if bridge.poll() is not None:
            raise RuntimeError(f"bridge exited early rc={bridge.returncode} errors={errors} seen={seen[-20:]}")
        try:
            msg = messages.get(timeout=0.05)
        except queue.Empty:
            continue
        if predicate(msg):
            return msg
    raise TimeoutError(f"timed out; errors={errors} seen={seen[-20:]}")

try:
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "stdio-to-uds"}}})
    init = wait_for(lambda m: m.get("id") == 1, timeout=10)
    assert "userAgent" in init.get("result", {}), init
    send({"method": "initialized"})

    send({"id": 2, "method": "thread/start", "params": {"cwd": workspace, "model": "mock"}})
    started = wait_for(lambda m: m.get("id") == 2, timeout=10)
    thread_id = started["result"]["thread"]["id"]
    assert thread_id, started

    send({
        "id": 3,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": "stdio to UDS compatibility smoke"}],
        },
    })
    ack = wait_for(lambda m: m.get("id") == 3, timeout=10)
    assert "error" not in ack, ack
    completed = wait_for(
        lambda m: m.get("method") == "turn/completed"
        and m.get("params", {}).get("threadId") == thread_id,
        timeout=30,
    )
    assert completed["params"]["threadId"] == thread_id, completed
    methods = [m.get("method") for m in seen if "method" in m]
    assert "turn/started" in methods, seen
    assert "item/agentMessage/delta" in methods, seen
    assert "item/completed" in methods, seen
finally:
    try:
        if bridge.stdin:
            bridge.stdin.close()
    except Exception:
        pass
    try:
        bridge.wait(timeout=10)
    except subprocess.TimeoutExpired:
        bridge.kill()
        bridge.wait(timeout=10)

print("STDIO TO UDS SMOKE OK")
PY
