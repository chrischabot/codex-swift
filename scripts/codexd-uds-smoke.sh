#!/usr/bin/env bash
# Drives the real codexd binary over the default unix:// app-control socket.
# Uses CODEXKIT_MOCK=1 so it is deterministic and does not require network.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

WORK="$(mktemp -d /tmp/cxuds.XXXXXX)"
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

python3 - "$SOCK" "$WORK/workspace" >"$WORK/probe.txt" <<'PY'
import base64, json, os, socket, stat, sys, time
sock_path = sys.argv[1]
workspace = sys.argv[2]
os.makedirs(workspace, exist_ok=True)

mode = stat.S_IMODE(os.stat(sock_path).st_mode)
assert mode == 0o600, oct(mode)

def request(raw: bytes) -> bytes:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(6)
    s.connect(sock_path)
    s.sendall(raw)
    out = b""
    while b"\r\n\r\n" not in out or (b"/readyz" in raw and b'{"status":"ok"}' not in out):
        chunk = s.recv(65536)
        if not chunk:
            break
        out += chunk
        if len(out) > 65536:
            break
    s.close()
    return out

ready = request(b"GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
assert b"200 OK" in ready and b'{"status":"ok"}' in ready, ready

origin = request(
    b"GET /ws HTTP/1.1\r\nHost: localhost\r\nOrigin: https://example.com\r\n"
    b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
    b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    b"Sec-WebSocket-Version: 13\r\n\r\n")
assert b"403 Forbidden" in origin, origin

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(6)
s.connect(sock_path)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((
    "GET /ws HTTP/1.1\r\nHost: localhost\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n").encode())
handshake = b""
while b"\r\n\r\n" not in handshake:
    handshake += s.recv(4096)
assert b"101 Switching Protocols" in handshake, handshake
s.close()

class JSONLClient:
    def __init__(self, path: str) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(6)
        self.sock.connect(path)
        self.buf = b""

    def send(self, obj: dict) -> None:
        self.sock.sendall(json.dumps(obj, separators=(",", ":")).encode() + b"\n")

    def recv(self, timeout: float = 10) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                return json.loads(line)
            self.sock.settimeout(max(0.05, min(1, deadline - time.time())))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("socket closed before JSONL response")
            self.buf += chunk
        raise TimeoutError("timeout waiting for JSONL response")

    def recv_until(self, predicate, timeout: float = 20) -> tuple[dict, list[dict]]:
        deadline = time.time() + timeout
        seen = []
        while time.time() < deadline:
            msg = self.recv(max(0.05, deadline - time.time()))
            seen.append(msg)
            if predicate(msg):
                return msg, seen
        raise TimeoutError(f"timed out waiting for predicate; seen={seen[-20:]}")

    def close(self) -> None:
        self.sock.close()

jsonl = JSONLClient(sock_path)
try:
    jsonl.send({"id": 10, "method": "initialize", "params": {"clientInfo": {"name": "uds-jsonl-full"}}})
    init, _ = jsonl.recv_until(lambda m: m.get("id") == 10)
    assert "userAgent" in init.get("result", {}), init
    jsonl.send({"method": "initialized"})
    jsonl.send({"id": 11, "method": "thread/start", "params": {"cwd": workspace, "model": "mock"}})
    start, _ = jsonl.recv_until(lambda m: m.get("id") == 11)
    thread_id = start["result"]["thread"]["id"]
    assert thread_id, start
    jsonl.send({
        "id": 12,
        "method": "turn/start",
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": "UDS full turn smoke"}],
        },
    })
    completed, seen = jsonl.recv_until(
        lambda m: m.get("method") == "turn/completed" and m.get("params", {}).get("threadId") == thread_id,
        timeout=30,
    )
    methods = [m.get("method") for m in seen if "method" in m]
    assert "turn/started" in methods, seen
    assert completed["params"]["threadId"] == thread_id, completed
finally:
    jsonl.close()

print("UDS SMOKE OK")
print("UDS FULL TURN OK")
PY

cat "$WORK/probe.txt"
