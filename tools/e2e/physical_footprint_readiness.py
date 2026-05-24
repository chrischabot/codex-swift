#!/usr/bin/env python3
"""Run the physical-footprint gate as an optional strict-release preflight."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import verify_release_evidence as verifier


def check(script: Path, *, timeout: int = 120) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="codexkit-footprint-readiness-") as raw:
        evidence_dir = Path(raw)
        env = os.environ.copy()
        env["CODEXKIT_EVIDENCE_DIR"] = str(evidence_dir)
        env["CODEXKIT_FOOTPRINT_EXPECT_ENFORCED"] = "1"
        proc = subprocess.run(
            [str(script)],
            cwd=Path(__file__).resolve().parents[2],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout).strip()
            raise SystemExit(f"physical-footprint enforced probe failed: {detail}")
        payload = verifier.verify_physical_footprint(evidence_dir, strict=True)
        return {
            "enforced": True,
            "capMib": (payload.get("configuration") or {}).get("capMib"),
            "maxAllocatedMib": (payload.get("probe") or {}).get("maxAllocatedMib"),
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, default=Path("tools/e2e/g6_physical_footprint.sh"))
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    print(json.dumps(check(args.script, timeout=args.timeout), sort_keys=True))


if __name__ == "__main__":
    main()
