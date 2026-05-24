#!/usr/bin/env bash
# Clean-machine-shaped lifecycle gate.
#
# Uses empty temp install/LaunchAgents/CODEX_HOME roots, runs a first initialize
# + turn through real launchd-managed services, then uninstalls with explicit
# CODEX_HOME purge and verifies no install/plist/socket/state files remain.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool launchctl
require_tool python3
require_tool rg

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: clean-machine smoke requires macOS"
  exit 0
fi

uid="$(id -u)"
domain="gui/$uid"
work="$(mktemp -d /tmp/codexkit-clean.XXXXXX)"
label_prefix="ai.igent.codexkit.clean.$RANDOM.$$"
install_root="$work/install"
launch_agents_dir="$work/LaunchAgents"
codex_home="$work/home"
workspace="$work/workspace"
thread_file="$work/thread-id.txt"
spawned_worker_file="$work/spawned-worker-logged.txt"
worker_ready_file="$work/worker-ready-logged.txt"
evidence_file=""
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_file="$CODEXKIT_EVIDENCE_DIR/g6_clean_machine-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi
codexd_label="$label_prefix.codexd"
broker_label="$label_prefix.codex-broker"
codexd_sock="$codex_home/app-server-control/app-server-control.sock"
broker_sock="$codex_home/broker.sock"

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

wait_for_socket() {
  local path="$1"
  for _ in $(seq 1 80); do
    if [[ -S "$path" ]]; then return 0; fi
    sleep 0.25
  done
  echo "FAIL: timed out waiting for socket $path" >&2
  return 1
}

preflight_true_clean_attestation() {
  [[ "${CODEXKIT_TRUE_CLEAN_MACHINE:-0}" == "1" ]] || return 0
  CODEXKIT_CLEAN_MACHINE_ATTESTATION="${CODEXKIT_CLEAN_MACHINE_ATTESTATION:-}" \
  python3 - <<'PY'
import json, subprocess
import os
from datetime import datetime, timezone
from pathlib import Path

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
        pass
    return None

path = os.environ.get("CODEXKIT_CLEAN_MACHINE_ATTESTATION", "")
if not path:
    raise SystemExit("CODEXKIT_TRUE_CLEAN_MACHINE=1 requires CODEXKIT_CLEAN_MACHINE_ATTESTATION")
payload = json.loads(Path(path).read_text(encoding="utf-8"))
if payload.get("trueCleanMachine") is not True:
    raise SystemExit("clean-machine attestation must set trueCleanMachine=true")
assertions = payload.get("assertions")
if not isinstance(assertions, dict) or not assertions:
    raise SystemExit("clean-machine attestation assertions missing")
failed = {k: v for k, v in assertions.items() if v is not True}
if failed:
    raise SystemExit(f"clean-machine attestation failed assertions: {failed}")
if not payload.get("operator"):
    raise SystemExit("clean-machine attestation missing operator")
if not payload.get("timestamp"):
    raise SystemExit("clean-machine attestation missing timestamp")
timestamp = str(payload.get("timestamp"))
if timestamp.endswith("Z"):
    timestamp = timestamp[:-1] + "+00:00"
try:
    parsed = datetime.fromisoformat(timestamp)
except ValueError as exc:
    raise SystemExit(f"clean-machine attestation timestamp is not ISO-8601: {payload.get('timestamp')}") from exc
if parsed.tzinfo is None or parsed.astimezone(timezone.utc).year < 2024:
    raise SystemExit(f"clean-machine attestation timestamp is not a valid UTC timestamp: {payload.get('timestamp')}")
attested_hw = (payload.get("host") or {}).get("hardwareUUID")
if not attested_hw:
    raise SystemExit("clean-machine attestation missing host.hardwareUUID")
current_hw = hardware_uuid()
if not current_hw:
    raise SystemExit("clean-machine evidence could not read host hardware UUID")
if current_hw != attested_hw:
    raise SystemExit(f"clean-machine attestation hardware UUID mismatch: evidence={current_hw} attestation={attested_hw}")
PY
}

probe_first_turn() {
  python3 - "$codexd_sock" "$workspace" "$codex_home" "$thread_file" <<'PY'
import json, os, socket, stat, sys, time
sock_path, cwd, codex_home, thread_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
mode = stat.S_IMODE(os.stat(sock_path).st_mode)
assert mode == 0o600, oct(mode)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(8)
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

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "clean-machine"}}})
init = read_until(lambda m: m.get("id") == 1)
assert init["result"]["codexHome"] == codex_home, init
send({"method": "initialized"})
send({"id": 2, "method": "thread/list", "params": {"limit": 50}})
initial = read_until(lambda m: m.get("id") == 2)
assert initial["result"]["data"] == [], initial
send({"id": 3, "method": "thread/start", "params": {"cwd": cwd, "model": "mock"}})
start = read_until(lambda m: m.get("id") == 3)
tid = start["result"]["thread"]["id"]
send({
    "id": 4,
    "method": "turn/start",
    "params": {
        "threadId": tid,
        "input": [{"type": "text", "text": "first clean-machine turn"}],
    },
})
read_until(lambda m: m.get("id") == 4)
read_until(lambda m: m.get("method") == "turn/completed")
send({"id": 5, "method": "thread/list", "params": {"limit": 50}})
after = read_until(lambda m: m.get("id") == 5)
assert len(after["result"]["data"]) == 1, after
open(thread_file, "w", encoding="utf-8").write(tid)
print(f"clean-machine first turn completed thread={tid}")
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
  CODEXKIT_BROKER_SOCK="$broker_sock" \
  CODEXKIT_THREAD_FILE="$thread_file" \
  CODEXKIT_SPAWNED_WORKER_FILE="$spawned_worker_file" \
  CODEXKIT_WORKER_READY_FILE="$worker_ready_file" \
  CODEXKIT_TRUE_CLEAN_MACHINE="${CODEXKIT_TRUE_CLEAN_MACHINE:-0}" \
  CODEXKIT_CLEAN_MACHINE_ATTESTATION="${CODEXKIT_CLEAN_MACHINE_ATTESTATION:-}" \
  python3 - <<'PY'
import json, os, platform, subprocess
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
        pass
    return None

def load_attestation():
    if os.environ["CODEXKIT_TRUE_CLEAN_MACHINE"] != "1":
        return None
    path = os.environ.get("CODEXKIT_CLEAN_MACHINE_ATTESTATION", "")
    if not path:
        raise SystemExit("CODEXKIT_TRUE_CLEAN_MACHINE=1 requires CODEXKIT_CLEAN_MACHINE_ATTESTATION")
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if payload.get("trueCleanMachine") is not True:
        raise SystemExit("clean-machine attestation must set trueCleanMachine=true")
    assertions = payload.get("assertions")
    if not isinstance(assertions, dict) or not assertions:
        raise SystemExit("clean-machine attestation assertions missing")
    failed = {k: v for k, v in assertions.items() if v is not True}
    if failed:
        raise SystemExit(f"clean-machine attestation failed assertions: {failed}")
    if not payload.get("operator"):
        raise SystemExit("clean-machine attestation missing operator")
    if not payload.get("timestamp"):
        raise SystemExit("clean-machine attestation missing timestamp")
    attested_hw = (payload.get("host") or {}).get("hardwareUUID")
    if not attested_hw:
        raise SystemExit("clean-machine attestation missing host.hardwareUUID")
    current_hw = hardware_uuid()
    if not current_hw:
        raise SystemExit("clean-machine evidence could not read host hardware UUID")
    if current_hw != attested_hw:
        raise SystemExit(f"clean-machine attestation hardware UUID mismatch: evidence={current_hw} attestation={attested_hw}")
    return payload

work = Path(os.environ["CODEXKIT_WORK"])
install_root = Path(os.environ["CODEXKIT_INSTALL_ROOT"])
codex_home = Path(os.environ["CODEXKIT_CODEX_HOME"])
thread_id = read(os.environ["CODEXKIT_THREAD_FILE"]).strip() or None
codexd_log = install_root / "logs" / "codexd.err.log"
attestation = load_attestation()
payload = {
    "gate": "g6_clean_machine",
    "result": "passed",
    "trueCleanMachine": os.environ["CODEXKIT_TRUE_CLEAN_MACHINE"] == "1",
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "cleanMachineAttestation": attestation,
    "paths": {
        "work": str(work),
        "installRoot": os.environ["CODEXKIT_INSTALL_ROOT"],
        "launchAgentsDir": os.environ["CODEXKIT_LAUNCH_AGENTS_DIR"],
        "codexHome": os.environ["CODEXKIT_CODEX_HOME"],
        "workspace": os.environ["CODEXKIT_WORKSPACE"],
        "codexdSocket": os.environ["CODEXKIT_CODEXD_SOCK"],
        "brokerSocket": os.environ["CODEXKIT_BROKER_SOCK"],
    },
    "labels": {
        "prefix": os.environ["CODEXKIT_LABEL_PREFIX"],
        "codexd": os.environ["CODEXKIT_CODEXD_LABEL"],
        "broker": os.environ["CODEXKIT_BROKER_LABEL"],
    },
    "threadId": thread_id,
    "statusLoaded": read(work / "status.loaded"),
    "statusUninstalled": read(work / "status.uninstalled"),
    "assertions": {
        "firstThreadCreated": bool(thread_id),
        "spawnedWorkerLogged": read(os.environ["CODEXKIT_SPAWNED_WORKER_FILE"]).strip() == "true",
        "workerReadyLogged": read(os.environ["CODEXKIT_WORKER_READY_FILE"]).strip() == "true",
        "installRootRemoved": not install_root.exists(),
        "launchAgentsPlistsRemoved": not (Path(os.environ["CODEXKIT_LAUNCH_AGENTS_DIR"]) / f"{os.environ['CODEXKIT_CODEXD_LABEL']}.plist").exists()
            and not (Path(os.environ["CODEXKIT_LAUNCH_AGENTS_DIR"]) / f"{os.environ['CODEXKIT_BROKER_LABEL']}.plist").exists(),
        "codexHomePurged": not codex_home.exists(),
    },
}
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

preflight_true_clean_attestation

gate_start "Assert clean roots before install"
test ! -e "$install_root"
test ! -e "$launch_agents_dir"
test ! -e "$codex_home"
mkdir -p "$workspace"

gate_start "Build and install from empty roots"
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
  --codex-home "$codex_home" \
  --label-prefix "$label_prefix" \
  --launch-domain "$domain" | tee "$work/status.loaded"
rg -q 'installed=yes' "$work/status.loaded"
rg -q "$broker_label=loaded" "$work/status.loaded"
rg -q "$codexd_label=loaded" "$work/status.loaded"

wait_for_socket "$broker_sock"
wait_for_socket "$codexd_sock"
probe_first_turn
test -d "$codex_home/sessions"
test -S "$codexd_sock"
test -S "$broker_sock"
rg -q 'codexd workerMode=spawned' "$install_root/logs/codexd.err.log"
printf 'true\n' > "$spawned_worker_file"
rg -q 'codex-session worker ready' "$install_root/logs/codexd.err.log"
printf 'true\n' > "$worker_ready_file"

gate_start "Uninstall and purge clean-machine roots"
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
test ! -e "$install_root"
test ! -e "$codex_home"
test ! -e "$launch_agents_dir/$codexd_label.plist"
test ! -e "$launch_agents_dir/$broker_label.plist"
write_evidence

echo
echo "g6_clean_machine OK"
