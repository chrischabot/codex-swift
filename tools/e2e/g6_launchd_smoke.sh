#!/usr/bin/env bash
# User-domain launchd lifecycle gate. This intentionally uses unique labels and
# temp install + LaunchAgents roots so the host install locations are not
# modified.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool launchctl
require_tool python3
require_tool rg

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: launchd smoke requires macOS"
  exit 0
fi

uid="$(id -u)"
domain="gui/$uid"
work="$(mktemp -d /tmp/codexkit-launchd.XXXXXX)"
label_prefix="ai.igent.codexkit.test.$RANDOM.$$"
install_root="$work/install"
launch_agents_dir="$work/LaunchAgents"
codex_home="$work/home"
codexd_label="$label_prefix.codexd"
broker_label="$label_prefix.codex-broker"
codexd_sock="$codex_home/app-server-control/app-server-control.sock"
broker_sock="$codex_home/broker.sock"
codexd_err="$install_root/logs/codexd.err.log"
old_broker_pid_file="$work/old-broker-pid.txt"
new_broker_pid_file="$work/new-broker-pid.txt"
old_codexd_pid_file="$work/old-codexd-pid.txt"
new_codexd_pid_file="$work/new-codexd-pid.txt"
turn_count_file="$work/turn-count.txt"
spawned_worker_file="$work/spawned-worker-logged.txt"
worker_ready_file="$work/worker-ready-logged.txt"
evidence_file=""
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_file="$CODEXKIT_EVIDENCE_DIR/g6_launchd_smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi

cleanup() {
  set +e
  scripts/codexkit-lifecycle.sh uninstall \
    --install-root "$install_root" \
    --launch-agents-dir "$launch_agents_dir" \
    --label-prefix "$label_prefix" \
    --launch-domain "$domain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

gate_start "Build and install temp user LaunchAgents"
run swift build -c release
run scripts/codexkit-lifecycle.sh install \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --build-dir .build/release \
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" \
  --listen "unix://" \
  --mock-model

scripts/codexkit-lifecycle.sh status \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" | tee "$work/status.loaded"
rg -q 'installed=yes' "$work/status.loaded"
rg -q "$broker_label=loaded" "$work/status.loaded"
rg -q "$codexd_label=loaded" "$work/status.loaded"

wait_for_path() {
  local path="$1"
  for _ in $(seq 1 80); do
    if [[ -S "$path" ]]; then return 0; fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for socket $path" >&2
  return 1
}

service_pid() {
  launchctl print "$domain/$1" 2>/dev/null \
    | awk -F'= ' '/^[[:space:]]*pid = / {print $2; exit}'
}

wait_for_pid_change() {
  local label="$1"
  local old_pid="$2"
  for _ in $(seq 1 80); do
    local pid
    pid="$(service_pid "$label" || true)"
    if [[ -n "$pid" && "$pid" != "$old_pid" ]]; then
      echo "$pid"
      return 0
    fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for $label restart" >&2
  return 1
}

probe_broker() {
  python3 - "$broker_sock" <<'PY'
import json, os, socket, stat, sys
sock_path = sys.argv[1]
mode = stat.S_IMODE(os.stat(sock_path).st_mode)
assert mode == 0o600, oct(mode)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(6)
s.connect(sock_path)
s.sendall(b'{"id":1,"method":"broker/ping"}\n')
s.shutdown(socket.SHUT_WR)
out = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    out += chunk
resp = json.loads(out.decode().strip())
assert resp["ok"] is True and resp["result"]["ready"] is True, resp
print("broker ready")
PY
}

probe_codexd() {
  python3 - "$codexd_sock" <<'PY'
import os, socket, stat, sys
sock_path = sys.argv[1]
mode = stat.S_IMODE(os.stat(sock_path).st_mode)
assert mode == 0o600, oct(mode)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(6)
s.connect(sock_path)
s.sendall(b"GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
out = b""
while b'{"status":"ok"}' not in out:
    chunk = s.recv(65536)
    if not chunk:
        break
    out += chunk
assert b"200 OK" in out and b'{"status":"ok"}' in out, out
print("codexd ready")
PY
}

probe_codexd_turn() {
  python3 - "$codexd_sock" "$work" "$turn_count_file" <<'PY'
import json, socket, sys, time
sock_path, cwd, turn_count_file = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(8)
s.connect(sock_path)

def send(obj):
    s.sendall((json.dumps(obj, separators=(",", ":")) + "\n").encode())

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "launchd-smoke"}}})
send({"method": "initialized"})
send({"id": 2, "method": "thread/start", "params": {"cwd": cwd}})

buf = b""
thread_id = None
deadline = time.time() + 8
while time.time() < deadline and not thread_id:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("id") == 2:
            thread_id = msg["result"]["thread"]["id"]
            break
assert thread_id, "thread/start did not return a thread id"

send({
    "id": 3,
    "method": "turn/start",
    "params": {
        "threadId": thread_id,
        "input": [{"type": "text", "text": "say ok"}],
    },
})

completed = False
deadline = time.time() + 12
while time.time() < deadline and not completed:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("method") == "turn/completed":
            completed = True
            break
assert completed, "turn/completed was not observed"
try:
    current = int(open(turn_count_file, encoding="utf-8").read().strip() or "0")
except Exception:
    current = 0
open(turn_count_file, "w", encoding="utf-8").write(str(current + 1))
print("codexd turn completed")
PY
  rg -q 'codexd workerMode=spawned' "$codexd_err"
  printf 'true\n' > "$spawned_worker_file"
  rg -q 'codex-session worker ready' "$codexd_err"
  printf 'true\n' > "$worker_ready_file"
}

write_evidence() {
  [[ -n "$evidence_file" ]] || return 0
  CODEXKIT_EVIDENCE_FILE="$evidence_file" \
  CODEXKIT_WORK="$work" \
  CODEXKIT_INSTALL_ROOT="$install_root" \
  CODEXKIT_LAUNCH_AGENTS_DIR="$launch_agents_dir" \
  CODEXKIT_CODEX_HOME="$codex_home" \
  CODEXKIT_LABEL_PREFIX="$label_prefix" \
  CODEXKIT_CODEXD_LABEL="$codexd_label" \
  CODEXKIT_BROKER_LABEL="$broker_label" \
  CODEXKIT_CODEXD_SOCK="$codexd_sock" \
  CODEXKIT_BROKER_SOCK="$broker_sock" \
  CODEXKIT_OLD_BROKER_PID_FILE="$old_broker_pid_file" \
  CODEXKIT_NEW_BROKER_PID_FILE="$new_broker_pid_file" \
  CODEXKIT_OLD_CODEXD_PID_FILE="$old_codexd_pid_file" \
  CODEXKIT_NEW_CODEXD_PID_FILE="$new_codexd_pid_file" \
  CODEXKIT_TURN_COUNT_FILE="$turn_count_file" \
  CODEXKIT_SPAWNED_WORKER_FILE="$spawned_worker_file" \
  CODEXKIT_WORKER_READY_FILE="$worker_ready_file" \
  python3 - <<'PY'
import json, os, platform, subprocess
from datetime import datetime, timezone
from pathlib import Path

def read(path):
    p = Path(path)
    return p.read_text(encoding="utf-8") if p.exists() else ""

def sw_vers():
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}

def hardware_uuid():
    try:
        out = subprocess.check_output(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        for line in out.splitlines():
            if '"IOPlatformUUID"' in line and "=" in line:
                return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        return None
    return None

def read_int(path):
    try:
        return int(read(path).strip())
    except Exception:
        return None

old_broker = read(os.environ["CODEXKIT_OLD_BROKER_PID_FILE"]).strip() or None
new_broker = read(os.environ["CODEXKIT_NEW_BROKER_PID_FILE"]).strip() or None
old_codexd = read(os.environ["CODEXKIT_OLD_CODEXD_PID_FILE"]).strip() or None
new_codexd = read(os.environ["CODEXKIT_NEW_CODEXD_PID_FILE"]).strip() or None
turn_count = read_int(os.environ["CODEXKIT_TURN_COUNT_FILE"])
payload = {
    "gate": "g6_launchd_smoke",
    "result": "passed",
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "paths": {
        "work": os.environ["CODEXKIT_WORK"],
        "installRoot": os.environ["CODEXKIT_INSTALL_ROOT"],
        "launchAgentsDir": os.environ["CODEXKIT_LAUNCH_AGENTS_DIR"],
        "codexHome": os.environ["CODEXKIT_CODEX_HOME"],
        "codexdSocket": os.environ["CODEXKIT_CODEXD_SOCK"],
        "brokerSocket": os.environ["CODEXKIT_BROKER_SOCK"],
    },
    "labels": {
        "prefix": os.environ["CODEXKIT_LABEL_PREFIX"],
        "codexd": os.environ["CODEXKIT_CODEXD_LABEL"],
        "broker": os.environ["CODEXKIT_BROKER_LABEL"],
    },
    "restart": {
        "broker": {"oldPid": old_broker, "newPid": new_broker, "pidChanged": bool(old_broker and new_broker and old_broker != new_broker)},
        "codexd": {"oldPid": old_codexd, "newPid": new_codexd, "pidChanged": bool(old_codexd and new_codexd and old_codexd != new_codexd)},
    },
    "turnCount": turn_count,
    "statusLoaded": read(Path(os.environ["CODEXKIT_WORK"]) / "status.loaded"),
    "statusUninstalled": read(Path(os.environ["CODEXKIT_WORK"]) / "status.uninstalled"),
    "assertions": {
        "brokerRestarted": bool(old_broker and new_broker and old_broker != new_broker),
        "codexdRestarted": bool(old_codexd and new_codexd and old_codexd != new_codexd),
        "turnBeforeAndAfterRestartCompleted": bool(turn_count is not None and turn_count >= 2),
        "spawnedWorkerLogged": read(os.environ["CODEXKIT_SPAWNED_WORKER_FILE"]).strip() == "true",
        "workerReadyLogged": read(os.environ["CODEXKIT_WORKER_READY_FILE"]).strip() == "true",
    },
}
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

wait_for_path "$broker_sock"
wait_for_path "$codexd_sock"
probe_broker
probe_codexd
probe_codexd_turn

gate_start "Verify launchd KeepAlive restart"
broker_pid="$(service_pid "$broker_label")"
codexd_pid="$(service_pid "$codexd_label")"
test -n "$broker_pid"
test -n "$codexd_pid"
printf '%s\n' "$broker_pid" > "$old_broker_pid_file"
printf '%s\n' "$codexd_pid" > "$old_codexd_pid_file"
run kill -9 "$broker_pid"
run kill -9 "$codexd_pid"
new_broker_pid="$(wait_for_pid_change "$broker_label" "$broker_pid")"
new_codexd_pid="$(wait_for_pid_change "$codexd_label" "$codexd_pid")"
test -n "$new_broker_pid"
test -n "$new_codexd_pid"
printf '%s\n' "$new_broker_pid" > "$new_broker_pid_file"
printf '%s\n' "$new_codexd_pid" > "$new_codexd_pid_file"

wait_for_path "$broker_sock"
wait_for_path "$codexd_sock"
probe_broker
probe_codexd
probe_codexd_turn

gate_start "Uninstall temp user LaunchAgents"
run scripts/codexkit-lifecycle.sh uninstall \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain"
scripts/codexkit-lifecycle.sh status \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" | tee "$work/status.uninstalled"
rg -q 'installed=no' "$work/status.uninstalled"
rg -q "$broker_label=not-loaded" "$work/status.uninstalled"
rg -q "$codexd_label=not-loaded" "$work/status.uninstalled"
write_evidence

echo
echo "g6_launchd_smoke OK"
