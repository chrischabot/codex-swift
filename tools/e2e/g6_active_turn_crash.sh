#!/usr/bin/env bash
# Active-turn daemon crash gate.
#
# Starts a slow mock turn through launchd-managed codexd, kills the daemon while
# that turn is in progress, waits for KeepAlive restart, then resumes the same
# durable thread from a fresh connection and completes a later turn.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool launchctl
require_tool python3
require_tool rg

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: active-turn crash smoke requires macOS"
  exit 0
fi

uid="$(id -u)"
domain="gui/$uid"
work="$(mktemp -d /tmp/codexkit-active-crash.XXXXXX)"
label_prefix="ai.igent.codexkit.active.$RANDOM.$$"
install_root="$work/install"
launch_agents_dir="$work/LaunchAgents"
codex_home="$work/home"
workspace="$work/workspace"
codexd_label="$label_prefix.codexd"
broker_label="$label_prefix.codex-broker"
codexd_sock="$codex_home/app-server-control/app-server-control.sock"
thread_file="$work/thread-id.txt"
old_pid_file="$work/old-codexd-pid.txt"
new_pid_file="$work/new-codexd-pid.txt"
statuses_before_file="$work/statuses-before-recovery.json"
statuses_after_file="$work/statuses-after-recovery.json"
turn_count_after_file="$work/turn-count-after-recovery.txt"
spawned_worker_file="$work/spawned-worker-logged.txt"
worker_ready_file="$work/worker-ready-logged.txt"
evidence_file=""
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_file="$CODEXKIT_EVIDENCE_DIR/g6_active_turn_crash-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi

cleanup() {
  set +e
  scripts/codexkit-lifecycle.sh uninstall \
    --install-root "$install_root" \
    --launch-agents-dir "$launch_agents_dir" \
    --codex-home "$codex_home" \
    --label-prefix "$label_prefix" \
    --launch-domain "$domain" \
    --purge-codex-home >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

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

wait_for_readyz() {
  python3 - "$codexd_sock" <<'PY'
import socket, sys, time
sock_path = sys.argv[1]
deadline = time.time() + 25
last = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(sock_path)
        s.sendall(b"GET /readyz HTTP/1.1\r\nHost: localhost\r\n\r\n")
        out = b""
        while b'{"status":"ok"}' not in out:
            chunk = s.recv(65536)
            if not chunk:
                break
            out += chunk
        if b"200 OK" in out and b'{"status":"ok"}' in out:
            print("codexd ready")
            raise SystemExit(0)
    except Exception as exc:
        last = exc
    time.sleep(0.25)
raise SystemExit(f"codexd not ready: {last}")
PY
}

start_slow_turn() {
  python3 - "$codexd_sock" "$workspace" "$thread_file" <<'PY'
import json, socket, sys, time
sock_path, cwd, thread_file = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(35)
s.connect(sock_path)
buf = b""

def send(obj):
    s.sendall((json.dumps(obj, separators=(",", ":")) + "\n").encode())

def read_until(predicate, timeout=12):
    global buf
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            msg = json.loads(line)
            if predicate(msg):
                return msg
    raise AssertionError("condition not observed")

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "active-crash-start"}}})
read_until(lambda m: m.get("id") == 1)
send({"method": "initialized"})
send({"id": 2, "method": "thread/start", "params": {"cwd": cwd, "model": "mock"}})
start = read_until(lambda m: m.get("id") == 2)
tid = start["result"]["thread"]["id"]
send({
    "id": 3,
    "method": "turn/start",
    "params": {
        "threadId": tid,
        "input": [{"type": "text", "text": "slow turn should be interrupted by daemon death"}],
    },
})
read_until(lambda m: m.get("id") == 3)
read_until(lambda m: m.get("method") == "turn/started")
read_until(lambda m: m.get("method") == "item/started")
open(thread_file, "w", encoding="utf-8").write(tid)
print(f"slow turn started thread={tid}")
PY
}

resume_after_crash() {
  python3 - "$codexd_sock" "$thread_file" "$statuses_before_file" "$statuses_after_file" "$turn_count_after_file" <<'PY'
import json, socket, sys, time
sock_path, thread_file, before_file, after_file, turn_count_file = sys.argv[1:6]
tid = open(thread_file, encoding="utf-8").read().strip()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(35)
s.connect(sock_path)
buf = b""

def send(obj):
    s.sendall((json.dumps(obj, separators=(",", ":")) + "\n").encode())

def read_until(predicate, timeout=20):
    global buf
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            msg = json.loads(line)
            if predicate(msg):
                return msg
    raise AssertionError("condition not observed")

send({
    "id": 10,
    "method": "initialize",
    "params": {
        "clientInfo": {"name": "active-crash-resume"},
        "capabilities": {"experimentalApi": True},
    },
})
read_until(lambda m: m.get("id") == 10)
send({"method": "initialized"})
send({"id": 11, "method": "thread/resume", "params": {"threadId": tid}})
resume = read_until(lambda m: m.get("id") == 11)
assert resume["result"]["thread"]["id"] == tid, resume
send({"id": 12, "method": "thread/turns/list", "params": {"threadId": tid}})
before = read_until(lambda m: m.get("id") == 12)
statuses = [t["status"] for t in before["result"]["data"]]
assert ("interrupted" in statuses) or ("inProgress" in statuses), before
open(before_file, "w", encoding="utf-8").write(json.dumps(statuses, sort_keys=True))
send({
    "id": 13,
    "method": "turn/start",
    "params": {
        "threadId": tid,
        "input": [{"type": "text", "text": "recover after active-turn crash"}],
    },
})
read_until(lambda m: m.get("id") == 13)
read_until(lambda m: m.get("method") == "turn/completed", timeout=30)
send({"id": 14, "method": "thread/turns/list", "params": {"threadId": tid}})
after = read_until(lambda m: m.get("id") == 14)
statuses = [t["status"] for t in after["result"]["data"]]
assert ("interrupted" in statuses) or ("inProgress" in statuses), after
assert "completed" in statuses, after
assert len(statuses) >= 2, after
open(after_file, "w", encoding="utf-8").write(json.dumps(statuses, sort_keys=True))
open(turn_count_file, "w", encoding="utf-8").write(str(len(statuses)))
print(f"active-turn crash recovered thread={tid} statuses={statuses}")
PY
}

write_evidence() {
  [[ -n "$evidence_file" ]] || return 0
  CODEXKIT_EVIDENCE_FILE="$evidence_file" \
  CODEXKIT_WORK="$work" \
  CODEXKIT_INSTALL_ROOT="$install_root" \
  CODEXKIT_LAUNCH_AGENTS_DIR="$launch_agents_dir" \
  CODEXKIT_CODEX_HOME="$codex_home" \
  CODEXKIT_WORKSPACE="$workspace" \
  CODEXKIT_LABEL_PREFIX="$label_prefix" \
  CODEXKIT_CODEXD_LABEL="$codexd_label" \
  CODEXKIT_BROKER_LABEL="$broker_label" \
  CODEXKIT_CODEXD_SOCK="$codexd_sock" \
  CODEXKIT_THREAD_FILE="$thread_file" \
  CODEXKIT_OLD_PID_FILE="$old_pid_file" \
  CODEXKIT_NEW_PID_FILE="$new_pid_file" \
  CODEXKIT_STATUSES_BEFORE_FILE="$statuses_before_file" \
  CODEXKIT_STATUSES_AFTER_FILE="$statuses_after_file" \
  CODEXKIT_TURN_COUNT_AFTER_FILE="$turn_count_after_file" \
  CODEXKIT_SPAWNED_WORKER_FILE="$spawned_worker_file" \
  CODEXKIT_WORKER_READY_FILE="$worker_ready_file" \
  python3 - <<'PY'
import json, os, platform, subprocess
from datetime import datetime, timezone
from pathlib import Path

def read(path):
    p = Path(path)
    return p.read_text(encoding="utf-8") if p.exists() else ""

def read_json(path, fallback):
    raw = read(path).strip()
    if not raw:
        return fallback
    return json.loads(raw)

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

work = Path(os.environ["CODEXKIT_WORK"])
thread_id = read(os.environ["CODEXKIT_THREAD_FILE"]).strip() or None
old_pid = read(os.environ["CODEXKIT_OLD_PID_FILE"]).strip() or None
new_pid = read(os.environ["CODEXKIT_NEW_PID_FILE"]).strip() or None
statuses_before = read_json(os.environ["CODEXKIT_STATUSES_BEFORE_FILE"], [])
statuses_after = read_json(os.environ["CODEXKIT_STATUSES_AFTER_FILE"], [])
turn_count_text = read(os.environ["CODEXKIT_TURN_COUNT_AFTER_FILE"]).strip()
try:
    turn_count_after = int(turn_count_text)
except Exception:
    turn_count_after = None
payload = {
    "gate": "g6_active_turn_crash",
    "result": "passed",
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "paths": {
        "work": str(work),
        "installRoot": os.environ["CODEXKIT_INSTALL_ROOT"],
        "launchAgentsDir": os.environ["CODEXKIT_LAUNCH_AGENTS_DIR"],
        "codexHome": os.environ["CODEXKIT_CODEX_HOME"],
        "workspace": os.environ["CODEXKIT_WORKSPACE"],
        "codexdSocket": os.environ["CODEXKIT_CODEXD_SOCK"],
    },
    "labels": {
        "prefix": os.environ["CODEXKIT_LABEL_PREFIX"],
        "codexd": os.environ["CODEXKIT_CODEXD_LABEL"],
        "broker": os.environ["CODEXKIT_BROKER_LABEL"],
    },
    "threadId": thread_id,
    "daemonRestart": {
        "oldPid": old_pid,
        "newPid": new_pid,
        "pidChanged": bool(old_pid and new_pid and old_pid != new_pid),
    },
    "turnStatusesBeforeRecovery": statuses_before,
    "turnStatusesAfterRecovery": statuses_after,
    "turnCountAfterRecovery": turn_count_after,
    "statusLoaded": read(work / "status.loaded"),
    "statusUninstalled": read(work / "status.uninstalled"),
    "assertions": {
        "sameThreadResumed": bool(thread_id),
        "activeTurnMarkedInterruptedOrInProgress": "interrupted" in statuses_before or "inProgress" in statuses_before,
        "laterTurnCompleted": "completed" in statuses_after,
        "atLeastTwoTurnsAfterRecovery": bool(turn_count_after is not None and turn_count_after >= 2),
        "daemonPidChanged": bool(old_pid and new_pid and old_pid != new_pid),
        "spawnedWorkerLogged": read(os.environ["CODEXKIT_SPAWNED_WORKER_FILE"]).strip() == "true",
        "workerReadyLogged": read(os.environ["CODEXKIT_WORKER_READY_FILE"]).strip() == "true",
    },
}
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

gate_start "Build and install slow-mock LaunchAgents"
mkdir -p "$workspace"
run swift build -c release
run scripts/codexkit-lifecycle.sh install \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --build-dir .build/release \
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" \
  --listen "unix://" \
  --mock-model \
  --mock-slow-ms 10000

scripts/codexkit-lifecycle.sh status \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" | tee "$work/status.loaded"
rg -q 'installed=yes' "$work/status.loaded"
rg -q "$broker_label=loaded" "$work/status.loaded"
rg -q "$codexd_label=loaded" "$work/status.loaded"

wait_for_readyz
start_slow_turn &
starter_pid=$!
for _ in $(seq 1 80); do
  if [[ -s "$thread_file" ]]; then break; fi
  sleep 0.1
done
test -s "$thread_file"

gate_start "Kill daemon while turn is active"
old_codexd_pid="$(service_pid "$codexd_label")"
test -n "$old_codexd_pid"
printf '%s\n' "$old_codexd_pid" > "$old_pid_file"
run kill -9 "$old_codexd_pid"
wait "$starter_pid" 2>/dev/null || true
new_codexd_pid="$(wait_for_pid_change "$codexd_label" "$old_codexd_pid")"
test -n "$new_codexd_pid"
printf '%s\n' "$new_codexd_pid" > "$new_pid_file"
wait_for_readyz
resume_after_crash

rg -q 'codexd workerMode=spawned' "$install_root/logs/codexd.err.log"
printf 'true\n' > "$spawned_worker_file"
rg -q 'codex-session worker ready' "$install_root/logs/codexd.err.log"
printf 'true\n' > "$worker_ready_file"

gate_start "Uninstall active-turn crash LaunchAgents"
run scripts/codexkit-lifecycle.sh uninstall \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" \
  --purge-codex-home
scripts/codexkit-lifecycle.sh status \
  --install-root "$install_root" \
  --launch-agents-dir "$launch_agents_dir" \
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" | tee "$work/status.uninstalled"
rg -q 'installed=no' "$work/status.uninstalled"
rg -q "$broker_label=not-loaded" "$work/status.uninstalled"
rg -q "$codexd_label=not-loaded" "$work/status.uninstalled"
write_evidence

echo
echo "g6_active_turn_crash OK"
