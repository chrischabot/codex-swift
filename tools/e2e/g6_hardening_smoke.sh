#!/usr/bin/env bash
# Hardening smoke gate: broad adversarial campaign plus process isolation,
# resource-governor primitives, and release build.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

evidence_file=""
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_file="$CODEXKIT_EVIDENCE_DIR/g6_hardening_smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi

write_evidence() {
  [[ -n "$evidence_file" ]] || return 0
  CODEXKIT_EVIDENCE_FILE="$evidence_file" python3 - <<'PY'
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

payload = {
    "gate": "g6_hardening_smoke",
    "result": "passed",
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "components": {
        "adversarialFailureModeCampaign": {
            "result": "passed",
            "swiftFilter": "AdversarialTests|FailureModeTests|InfraAdversarialTests|SecurityAdversarialTests|WireFuzzAdversarialTests|AuthGatingAdversarialTests|McpAdversarialTests|PersistenceAdversarialTests|ToolsAdversarialTests|PromptInjectionAdversarialTests",
        },
        "toolForkBombContainment": {
            "result": "passed",
            "swiftFilter": "ToolsAdversarialTests/testShellForkBombChildrenKilledByTimeout",
        },
        "workerIsolationAndInfraPrimitives": {
            "result": "passed",
            "swiftFilter": "SpawnWorkerTests|InfraPrimitivesTests|BoundedChannelLifecycleTests",
        },
        "modelTransportFaultCampaign": {
            "result": "passed",
            "swiftFilter": "ModelClientTests|OpenAIClientFailureTests",
        },
        "releaseBuild": {"result": "passed", "command": "swift build -c release"},
    },
    "assertions": {
        "adversarialFailureModeCampaignPassed": True,
        "toolForkBombContainmentPassed": True,
        "workerIsolationAndInfraPrimitivesPassed": True,
        "modelTransportFaultCampaignPassed": True,
        "releaseBuildPassed": True,
    },
}
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

gate_start "Adversarial and failure-mode campaign"
swift_filter "AdversarialTests|FailureModeTests|InfraAdversarialTests|SecurityAdversarialTests|WireFuzzAdversarialTests|AuthGatingAdversarialTests|McpAdversarialTests|PersistenceAdversarialTests|ToolsAdversarialTests|PromptInjectionAdversarialTests"

gate_start "Tool fork-bomb process-group containment"
swift_filter "ToolsAdversarialTests/testShellForkBombChildrenKilledByTimeout"

gate_start "Worker isolation and infrastructure primitives"
swift_filter "SpawnWorkerTests|InfraPrimitivesTests|BoundedChannelLifecycleTests"

gate_start "Model transport fault campaign"
swift_filter "ModelClientTests|OpenAIClientFailureTests"

gate_start "Release build"
run swift build -c release

write_evidence

echo
echo "g6_hardening_smoke OK"
