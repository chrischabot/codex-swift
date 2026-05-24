#!/usr/bin/env bash
# True reboot/resume gate.
#
# This is intentionally two-phase because a real reboot cannot happen inside a
# single process. `prepare` installs persistent user LaunchAgents, creates a
# durable thread, records the current kernel boot time, and leaves the services
# installed. After reboot, `verify` proves the kernel boot time changed, resumes
# the same thread from a fresh client, completes another turn, writes evidence,
# and uninstalls. `cleanup` removes any leftover state.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool launchctl
require_tool python3
require_tool rg

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: true reboot gate requires macOS"
  exit 0
fi

PHASE="${CODEXKIT_REBOOT_PHASE:-prepare}"
STATE_DIR="${CODEXKIT_REBOOT_STATE_DIR:-$HOME/Library/Application Support/CodexKit/reboot-gate}"
STATE_FILE="$STATE_DIR/state.json"
EVIDENCE_DIR="${CODEXKIT_EVIDENCE_DIR:-$STATE_DIR/evidence}"
uid="$(id -u)"
domain="gui/$uid"

boot_sec() {
  sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/'
}

hardware_uuid() {
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
    sed -n 's/.*"IOPlatformUUID" = "\(.*\)"/\1/p' |
    head -n 1
}

wait_for_socket() {
  local path="$1"
  for _ in $(seq 1 120); do
    if [[ -S "$path" ]]; then return 0; fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for socket $path" >&2
  return 1
}

cleanup_from_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    rm -rf "$STATE_DIR"
    return 0
  fi
  python3 - "$STATE_FILE" <<'PY' | while IFS=$'\t' read -r install_root launch_agents_dir codex_home label_prefix domain; do
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    s = json.load(fh)
print("\t".join([
    s["paths"]["installRoot"],
    s["paths"]["launchAgentsDir"],
    s["paths"]["codexHome"],
    s["labels"]["prefix"],
    s["launchDomain"],
]))
PY
    scripts/codexkit-lifecycle.sh uninstall \
      --install-root "$install_root" \
      --launch-agents-dir "$launch_agents_dir" \
      --codex-home "$codex_home" \
      --label-prefix "$label_prefix" \
      --launch-domain "$domain" \
      --purge-codex-home >/dev/null 2>&1 || true
  done
  rm -rf "$STATE_DIR"
}

drive_create_thread() {
  local sock_path="$1"
  local cwd="$2"
  python3 - "$sock_path" "$cwd" <<'PY'
import json, socket, sys, time
sock_path, cwd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(8)
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

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "true-reboot-prepare"}}})
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
        "input": [{"type": "text", "text": "persist before true reboot"}],
    },
})
read_until(lambda m: m.get("id") == 3)
read_until(lambda m: m.get("method") == "turn/completed")
print(tid)
PY
}

drive_resume_thread() {
  local sock_path="$1"
  local tid="$2"
  python3 - "$sock_path" "$tid" <<'PY'
import json, socket, sys, time
sock_path, tid = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(8)
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
        "clientInfo": {"name": "true-reboot-verify"},
        "capabilities": {"experimentalApi": True},
    },
})
read_until(lambda m: m.get("id") == 10)
send({"method": "initialized"})
send({"id": 11, "method": "thread/resume", "params": {"threadId": tid}})
resume = read_until(lambda m: m.get("id") == 11)
assert resume["result"]["thread"]["id"] == tid, resume
send({
    "id": 12,
    "method": "turn/start",
    "params": {
        "threadId": tid,
        "input": [{"type": "text", "text": "continue after true reboot"}],
    },
})
read_until(lambda m: m.get("id") == 12)
read_until(lambda m: m.get("method") == "turn/completed")
send({"id": 13, "method": "thread/turns/list", "params": {"threadId": tid}})
turns = read_until(lambda m: m.get("id") == 13)
count = len(turns["result"]["data"])
assert count >= 2, turns
print(count)
PY
}

write_prepare_state() {
  local install_root="$1"
  local launch_agents_dir="$2"
  local codex_home="$3"
  local workspace="$4"
  local label_prefix="$5"
  local codexd_sock="$6"
  local broker_sock="$7"
  local thread_id="$8"
  local prepare_boot="$9"
  local prepare_hardware_uuid="${10}"
  python3 - "$STATE_FILE" "$install_root" "$launch_agents_dir" "$codex_home" "$workspace" "$label_prefix" "$domain" "$codexd_sock" "$broker_sock" "$thread_id" "$prepare_boot" "$prepare_hardware_uuid" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

state_file, install_root, launch_agents_dir, codex_home, workspace, label_prefix, domain, codexd_sock, broker_sock, thread_id, prepare_boot, prepare_hardware_uuid = sys.argv[1:]
payload = {
    "gate": "g6_true_reboot_resume",
    "phase": "prepared",
    "launchDomain": domain,
    "labels": {
        "prefix": label_prefix,
        "codexd": f"{label_prefix}.codexd",
        "broker": f"{label_prefix}.codex-broker",
    },
    "paths": {
        "installRoot": install_root,
        "launchAgentsDir": launch_agents_dir,
        "codexHome": codex_home,
        "workspace": workspace,
        "codexdSocket": codexd_sock,
        "brokerSocket": broker_sock,
    },
    "threadId": thread_id,
    "preparedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "prepareBootTimeSec": int(prepare_boot),
    "prepareHardwareUUID": prepare_hardware_uuid,
}
Path(state_file).parent.mkdir(parents=True, exist_ok=True)
Path(state_file).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

prepare() {
  if [[ -e "$STATE_FILE" ]]; then
    echo "FAIL: reboot gate state already exists: $STATE_FILE" >&2
    echo "Run CODEXKIT_REBOOT_PHASE=cleanup tools/e2e/g6_true_reboot_resume.sh first." >&2
    exit 1
  fi
  mkdir -p "$STATE_DIR" "$EVIDENCE_DIR"
  local label_prefix="ai.igent.codexkit.truereboot.$RANDOM.$$"
  local install_root="$STATE_DIR/install"
  local launch_agents_dir="$STATE_DIR/LaunchAgents"
  local codex_home="$STATE_DIR/home"
  local workspace="$STATE_DIR/workspace"
  local codexd_sock="$codex_home/app-server-control/app-server-control.sock"
  local broker_sock="$codex_home/broker.sock"
  mkdir -p "$workspace"

  gate_start "Build and install persistent LaunchAgents for true reboot gate"
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
  wait_for_socket "$broker_sock"
  wait_for_socket "$codexd_sock"
  local tid
  tid="$(drive_create_thread "$codexd_sock" "$workspace")"
  local prepare_boot
  prepare_boot="$(boot_sec)"
  local prepare_hardware_uuid
  prepare_hardware_uuid="$(hardware_uuid)"
  if [[ -z "$prepare_hardware_uuid" ]]; then
    echo "FAIL: could not read hardware UUID for true reboot evidence" >&2
    exit 1
  fi
  write_prepare_state "$install_root" "$launch_agents_dir" "$codex_home" "$workspace" "$label_prefix" "$codexd_sock" "$broker_sock" "$tid" "$prepare_boot" "$prepare_hardware_uuid"
  echo "Prepared true reboot gate for thread=$tid"
  echo "State: $STATE_FILE"
  echo "Reboot this Mac, then run:"
  echo "  CODEXKIT_REBOOT_PHASE=verify CODEXKIT_REBOOT_STATE_DIR=\"$STATE_DIR\" tools/e2e/g6_true_reboot_resume.sh"
}

verify() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "FAIL: missing reboot gate state: $STATE_FILE" >&2
    exit 1
  fi
  mkdir -p "$EVIDENCE_DIR"
  python3 - "$STATE_FILE" <<'PY' >"$STATE_DIR/.loaded"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    s = json.load(fh)
print(s["paths"]["codexdSocket"])
print(s["threadId"])
print(s["prepareBootTimeSec"])
print(s["labels"]["codexd"])
print(s["labels"]["broker"])
print(s["paths"]["installRoot"])
PY
  local codexd_sock
  local tid
  local prepare_boot
  codexd_sock="$(sed -n '1p' "$STATE_DIR/.loaded")"
  tid="$(sed -n '2p' "$STATE_DIR/.loaded")"
  prepare_boot="$(sed -n '3p' "$STATE_DIR/.loaded")"
  local current_boot
  current_boot="$(boot_sec)"
  if [[ "$current_boot" == "$prepare_boot" ]]; then
    echo "FAIL: kernel boot time did not change; this is not true reboot evidence" >&2
    exit 1
  fi
  if [[ "$current_boot" -le "$prepare_boot" ]]; then
    echo "FAIL: verify boot time is not later than prepare boot time" >&2
    exit 1
  fi
  local current_hardware_uuid
  current_hardware_uuid="$(hardware_uuid)"
  if [[ -z "$current_hardware_uuid" ]]; then
    echo "FAIL: could not read hardware UUID for true reboot verification" >&2
    exit 1
  fi
  wait_for_socket "$codexd_sock"
  local turn_count
  turn_count="$(drive_resume_thread "$codexd_sock" "$tid")"
  local evidence_file="$EVIDENCE_DIR/g6_true_reboot_resume-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  python3 - "$STATE_FILE" "$evidence_file" "$current_boot" "$current_hardware_uuid" "$turn_count" <<'PY'
import json, platform, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

state_file, evidence_file, current_boot, current_hardware_uuid, turn_count = sys.argv[1:]
state = json.loads(Path(state_file).read_text(encoding="utf-8"))

def sw_vers():
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}

payload = {
    "gate": "g6_true_reboot_resume",
    "result": "passed",
    "phase": "verified",
    "trueOSReboot": True,
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": current_hardware_uuid,
    },
    "labels": state["labels"],
    "paths": state["paths"],
    "threadId": state["threadId"],
    "preparedAt": state["preparedAt"],
    "verifiedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "turnCountAfterResume": int(turn_count),
    "boot": {
        "prepareBootTimeSec": state["prepareBootTimeSec"],
        "verifyBootTimeSec": int(current_boot),
        "bootTimeChanged": state["prepareBootTimeSec"] != int(current_boot),
        "verifyBootTimeAfterPrepare": int(current_boot) > state["prepareBootTimeSec"],
        "prepareHardwareUUID": state["prepareHardwareUUID"],
        "verifyHardwareUUID": current_hardware_uuid,
        "hardwareUUIDMatched": state["prepareHardwareUUID"] == current_hardware_uuid,
    },
}
assert payload["boot"]["bootTimeChanged"], payload
assert payload["boot"]["verifyBootTimeAfterPrepare"], payload
assert payload["boot"]["hardwareUUIDMatched"], payload
assert payload["turnCountAfterResume"] >= 2, payload
Path(evidence_file).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={evidence_file}")
PY
  cleanup_from_state
  echo
  echo "g6_true_reboot_resume OK"
}

case "$PHASE" in
  prepare) prepare ;;
  verify) verify ;;
  cleanup) cleanup_from_state ;;
  *)
    echo "FAIL: CODEXKIT_REBOOT_PHASE must be prepare, verify, or cleanup" >&2
    exit 2
    ;;
esac
