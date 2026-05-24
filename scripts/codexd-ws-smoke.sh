#!/usr/bin/env bash
# Drives the real codexd binary over loopback WebSocket and health routes.
# Uses CODEXKIT_MOCK=1 so it is deterministic and does not require network.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

WORK="$(mktemp -d)"
OUTF="$WORK/out.txt"
ERRF="$WORK/err.txt"
trap 'rm -rf "$WORK"; if [ -n "${RUN_PID:-}" ]; then kill "$RUN_PID" 2>/dev/null || true; fi' EXIT

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

CODEXKIT_MOCK=1 CODEX_HOME="$WORK/home" \
  .build/debug/codexd --listen "ws://127.0.0.1:$PORT" >"$OUTF" 2>"$ERRF" &
RUN_PID=$!

for _ in $(seq 1 80); do
  if grep -q "codexd listening ws://127.0.0.1:$PORT" "$ERRF" 2>/dev/null; then
    break
  fi
  kill -0 "$RUN_PID" 2>/dev/null || {
    echo "FAIL: codexd exited early"
    cat "$ERRF" || true
    exit 1
  }
  sleep 0.25
done

python3 - "$PORT" >"$WORK/probe.txt" <<'PY'
import base64, os, socket, sys
port = int(sys.argv[1])

def request(raw: bytes) -> bytes:
    s = socket.create_connection(("127.0.0.1", port), timeout=6)
    s.sendall(raw)
    out = b""
    while b"\r\n\r\n" not in out or (b'{"status":"ok"}' in raw and b'{"status":"ok"}' not in out):
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

s = socket.create_connection(("127.0.0.1", port), timeout=6)
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

payload = b'{"id":1,"method":"initialize","params":{"clientInfo":{"name":"wssmoke"}}}'
mask = b"\x12\x34\x56\x78"
frame = bytearray([0x81])
n = len(payload)
if n < 126:
    frame.append(0x80 | n)
else:
    frame += bytes([0x80 | 126, (n >> 8) & 255, n & 255])
frame += mask
frame += bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
s.sendall(frame)

buf = b""
while len(buf) < 2:
    buf += s.recv(4096)
length = buf[1] & 0x7f
off = 2
if length == 126:
    while len(buf) < 4:
        buf += s.recv(4096)
    length = (buf[2] << 8) | buf[3]
    off = 4
elif length == 127:
    raise AssertionError("unexpected huge frame")
while len(buf) < off + length:
    buf += s.recv(4096)
body = buf[off:off + length]
assert b'"userAgent"' in body and b'CodexKit/0.1 (wssmoke)' in body, body
s.close()
print("WS SMOKE OK")
PY

cat "$WORK/probe.txt"
