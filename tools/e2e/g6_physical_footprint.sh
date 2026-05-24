#!/usr/bin/env bash
# Physical-footprint enforcement probe.
#
# Local developer machines may legitimately reject task_set_phys_footprint_limit
# for the current signing/entitlement shape. This gate records that as explicit
# degradation. Strict release rehearsals set CODEXKIT_FOOTPRINT_EXPECT_ENFORCED=1
# and fail unless the kernel actually terminates a process that exceeds the cap.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: physical-footprint probe requires macOS"
  exit 0
fi

require_tool clang
require_tool python3

CAP_MIB="${CODEXKIT_FOOTPRINT_CAP_MIB:-64}"
ALLOC_MIB="${CODEXKIT_FOOTPRINT_ALLOC_MIB:-256}"
EXPECT_ENFORCED="${CODEXKIT_FOOTPRINT_EXPECT_ENFORCED:-0}"
EVIDENCE_DIR="${CODEXKIT_EVIDENCE_DIR:-}"
EVIDENCE_FILE=""
if [[ -n "$EVIDENCE_DIR" ]]; then
  mkdir -p "$EVIDENCE_DIR"
  EVIDENCE_FILE="$EVIDENCE_DIR/g6_physical_footprint-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi

WORK="$(mktemp -d /tmp/codexkit-footprint.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/footprint_probe.c" <<'C'
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: footprint_probe <cap_mib> <alloc_mib>\n");
        return 2;
    }
    int cap_mib = atoi(argv[1]);
    int alloc_mib = atoi(argv[2]);
    if (cap_mib <= 0 || alloc_mib <= 0) {
        fprintf(stderr, "cap_mib and alloc_mib must be positive\n");
        return 2;
    }
    int old_limit = 0;
    kern_return_t kr = task_set_phys_footprint_limit(mach_task_self(), cap_mib, &old_limit);
    if (kr != KERN_SUCCESS) {
        printf("SET_FAILED kr=%d old=%d\n", kr, old_limit);
        fflush(stdout);
        return 42;
    }
    printf("SET_OK old=%d cap_mib=%d\n", old_limit, cap_mib);
    fflush(stdout);

    const size_t chunk = 1024 * 1024;
    for (int i = 0; i < alloc_mib; i++) {
        void *p = malloc(chunk);
        if (p == NULL) {
            printf("ALLOC_FAILED mib=%d\n", i);
            fflush(stdout);
            return 3;
        }
        memset(p, 0xA5, chunk);
        if ((i + 1) % 16 == 0 || (i + 1) > cap_mib) {
            printf("ALLOCATED mib=%d\n", i + 1);
            fflush(stdout);
        }
        usleep(1000);
    }
    printf("SURVIVED alloc_mib=%d\n", alloc_mib);
    fflush(stdout);
    return 0;
}
C

gate_start "Build physical-footprint probe"
run clang "$WORK/footprint_probe.c" -o "$WORK/footprint_probe"

if command -v codesign >/dev/null 2>&1; then
  identity="${CODEXKIT_FOOTPRINT_SIGN_IDENTITY:--}"
  gate_start "Sign physical-footprint probe"
  run codesign --force --options runtime --sign "$identity" "$WORK/footprint_probe"
fi

gate_start "Run physical-footprint probe"
PROBE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
"$WORK/footprint_probe" "$CAP_MIB" "$ALLOC_MIB" >"$WORK/probe.out" 2>&1
PROBE_RC=$?
set -e
PROBE_FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat "$WORK/probe.out"

CODEXKIT_EVIDENCE_FILE="$EVIDENCE_FILE" \
CODEXKIT_WORK="$WORK" \
CODEXKIT_CAP_MIB="$CAP_MIB" \
CODEXKIT_ALLOC_MIB="$ALLOC_MIB" \
CODEXKIT_EXPECT_ENFORCED="$EXPECT_ENFORCED" \
CODEXKIT_PROBE_RC="$PROBE_RC" \
CODEXKIT_PROBE_STARTED_AT="$PROBE_STARTED_AT" \
CODEXKIT_PROBE_FINISHED_AT="$PROBE_FINISHED_AT" \
python3 - <<'PY'
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

work = Path(os.environ["CODEXKIT_WORK"])
output = (work / "probe.out").read_text(encoding="utf-8", errors="replace")
rc = int(os.environ["CODEXKIT_PROBE_RC"])
set_ok = "SET_OK" in output
set_failed = "SET_FAILED" in output
survived = "SURVIVED" in output
allocation_failed = "ALLOC_FAILED" in output
allocated_mib = [int(m.group(1)) for m in re.finditer(r"ALLOCATED mib=([0-9]+)", output)]
max_allocated_mib = max(allocated_mib) if allocated_mib else 0
cap_mib = int(os.environ["CODEXKIT_CAP_MIB"])
alloc_mib = int(os.environ["CODEXKIT_ALLOC_MIB"])
signal_terminated = rc >= 128
terminated = rc != 0 and set_ok and not survived
exceeded_cap = max_allocated_mib > cap_mib
enforced = bool(set_ok and terminated and signal_terminated and exceeded_cap and not allocation_failed)

kr = None
m = re.search(r"SET_FAILED kr=([-0-9]+)", output)
if m:
    kr = int(m.group(1))

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

payload = {
    "gate": "g6_physical_footprint",
    "result": "passed" if enforced else "degraded",
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "configuration": {
        "capMib": cap_mib,
        "allocMib": alloc_mib,
        "expectEnforced": os.environ["CODEXKIT_EXPECT_ENFORCED"] == "1",
    },
    "probe": {
        "startedAt": os.environ["CODEXKIT_PROBE_STARTED_AT"],
        "finishedAt": os.environ["CODEXKIT_PROBE_FINISHED_AT"],
        "returncode": rc,
        "setOk": set_ok,
        "setFailed": set_failed,
        "kernReturn": kr,
        "survivedAllocation": survived,
        "allocationFailed": allocation_failed,
        "signalTerminated": signal_terminated,
        "terminatedAfterSet": terminated,
        "maxAllocatedMib": max_allocated_mib,
        "exceededCap": exceeded_cap,
        "enforced": enforced,
        "output": output[-4000:],
    },
}

if os.environ["CODEXKIT_EVIDENCE_FILE"]:
    Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
else:
    print(json.dumps(payload, indent=2, sort_keys=True))

if payload["configuration"]["expectEnforced"] and not enforced:
    print("FAIL: physical-footprint enforcement was expected but not observed", file=sys.stderr)
    raise SystemExit(1)
PY

echo
echo "g6_physical_footprint OK"
