#!/usr/bin/env bash
# Fault-containment certification entrypoint.
#
# Combines the adversarial/resource-governor campaign, production spawned-worker
# poison containment, and real user-domain launchd SIGKILL restart smoke. This
# keeps the fault gate rooted in executable evidence rather than a dashboard-only
# observation.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

evidence_file=""
before_file=""
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_file="$CODEXKIT_EVIDENCE_DIR/g6_fault-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  before_file="$(mktemp /tmp/codexkit-fault-before.XXXXXX)"
  find "$CODEXKIT_EVIDENCE_DIR" -maxdepth 1 -type f -name '*.json' -print | sort > "$before_file"
fi

cleanup_fault() {
  if [[ -n "$before_file" ]]; then
    rm -f "$before_file"
  fi
}
trap cleanup_fault EXIT

write_evidence() {
  [[ -n "$evidence_file" ]] || return 0
  CODEXKIT_EVIDENCE_FILE="$evidence_file" \
  CODEXKIT_EVIDENCE_DIR="$CODEXKIT_EVIDENCE_DIR" \
  CODEXKIT_BEFORE_FILE="$before_file" \
  python3 - <<'PY'
import json, os, platform, subprocess
from datetime import datetime, timezone
from pathlib import Path

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

evidence_dir = Path(os.environ["CODEXKIT_EVIDENCE_DIR"])
before = {
    str(Path(line).resolve())
    for line in Path(os.environ["CODEXKIT_BEFORE_FILE"]).read_text(encoding="utf-8").splitlines()
    if line.strip()
}
created = sorted(
    p
    for p in evidence_dir.glob("*.json")
    if str(p.resolve()) not in before and p.resolve() != Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).resolve()
)
by_gate = {}
for path in created:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    gate = payload.get("gate")
    if isinstance(gate, str) and gate:
        by_gate[gate] = path.name
required = {"g6_hardening_smoke", "g6_poison_worker", "g6_launchd_smoke"}
payload = {
    "gate": "g6_fault",
    "result": "passed",
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "components": {
        "hardeningSmoke": {"result": "passed", "evidenceFile": by_gate.get("g6_hardening_smoke")},
        "poisonWorker": {"result": "passed", "evidenceFile": by_gate.get("g6_poison_worker")},
        "launchdSmoke": {"result": "passed", "evidenceFile": by_gate.get("g6_launchd_smoke")},
    },
    "evidenceFiles": [p.name for p in created],
    "assertions": {
        "hardeningSmokePassed": True,
        "hardeningSmokeEvidenceCaptured": bool(by_gate.get("g6_hardening_smoke")),
        "poisonWorkerEvidenceCaptured": bool(by_gate.get("g6_poison_worker")),
        "launchdSmokeEvidenceCaptured": bool(by_gate.get("g6_launchd_smoke")),
    },
}
missing = required - set(by_gate)
if missing:
    raise SystemExit(f"missing child evidence for fault gate: {sorted(missing)}")
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

gate_start "Hardening fault campaign"
run tools/e2e/g6_hardening_smoke.sh

gate_start "Spawned-worker poison containment"
run tools/e2e/g6_poison_worker.sh

gate_start "launchd SIGKILL restart and cleanup fault smoke"
run tools/e2e/g6_launchd_smoke.sh

write_evidence

echo
echo "g6_fault OK"
