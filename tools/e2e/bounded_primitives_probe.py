#!/usr/bin/env python3
"""Run bounded queue/ring saturation proofs and emit release evidence.

The soak gate needs machine-readable proof that the C1/C2/C3/C4 bounded
primitives still reject, block, coalesce, or overwrite under hostile load. This
probe intentionally runs the Swift adversarial tests for the actual
implementations instead of reimplementing a parallel Python model.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TESTS = [
    {
        "id": "boundedChannelBlockingStorm",
        "filter": "InfraAdversarialTests/testBoundedChannelBlockingStormNoLossNoDeadlock",
        "proof": "blocking channel preserves every item and never exceeds capacity under a 4000-item storm",
    },
    {
        "id": "boundedChannelRejectNewestStorm",
        "filter": "InfraAdversarialTests/testBoundedChannelRejectNewestStormAccountsRejections",
        "proof": "reject-newest data channel returns overload and accounts exact rejection count under a 200000-send storm",
    },
    {
        "id": "coalescingRingFlood",
        "filter": "InfraAdversarialTests/testCoalescingRingFloodBoundedTerminalOnce",
        "proof": "stream-delta coalescing ring stays byte-bounded under a 1000000-delta flood and delivers terminal once",
    },
    {
        "id": "overwriteRingConcurrentPush",
        "filter": "InfraAdversarialTests/testOverwriteRingConcurrentPushBounded",
        "proof": "telemetry overwrite ring stays fixed-capacity under 32-way concurrent pushes and records drops",
    },
    {
        "id": "headTailBufferAdversarialSizes",
        "filter": "InfraAdversarialTests/testHeadTailBufferAdversarialSizesAndUnicode",
        "proof": "tool-output head/tail buffer truncates huge and multibyte payloads without unbounded growth or traps",
    },
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def run_test(root: Path, test: dict[str, str], timeout: int) -> dict[str, Any]:
    started = time.time()
    proc = subprocess.run(
        ["swift", "test", "--filter", test["filter"]],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    output = proc.stdout or ""
    return {
        "id": test["id"],
        "filter": test["filter"],
        "proof": test["proof"],
        "returncode": proc.returncode,
        "passed": proc.returncode == 0 and "0 failures" in output,
        "durationSeconds": round(time.time() - started, 3),
        "outputTail": output[-4000:],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--evidence-file", type=Path)
    args = parser.parse_args()

    started = utc_now()
    results = [run_test(args.root, test, args.timeout) for test in TESTS]
    failed = [item for item in results if not item["passed"]]
    payload = {
        "gate": "bounded_primitives_probe",
        "result": "failed" if failed else "passed",
        "createdAt": started,
        "finishedAt": utc_now(),
        "tests": results,
        "assertions": {
            "allTestsPassed": not failed,
            "boundedChannelBlockingStorm": any(
                item["id"] == "boundedChannelBlockingStorm" and item["passed"] for item in results
            ),
            "boundedChannelRejectNewestStorm": any(
                item["id"] == "boundedChannelRejectNewestStorm" and item["passed"] for item in results
            ),
            "coalescingRingFlood": any(item["id"] == "coalescingRingFlood" and item["passed"] for item in results),
            "overwriteRingConcurrentPush": any(
                item["id"] == "overwriteRingConcurrentPush" and item["passed"] for item in results
            ),
            "headTailBufferAdversarialSizes": any(
                item["id"] == "headTailBufferAdversarialSizes" and item["passed"] for item in results
            ),
        },
    }
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.evidence_file:
        args.evidence_file.parent.mkdir(parents=True, exist_ok=True)
        args.evidence_file.write_text(encoded, encoding="utf-8")
    print(json.dumps(payload, sort_keys=True))
    raise SystemExit(0 if payload["result"] == "passed" else 1)


if __name__ == "__main__":
    main()
