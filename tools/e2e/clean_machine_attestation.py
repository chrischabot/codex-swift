#!/usr/bin/env python3
"""Generate strict clean-machine attestation JSON for release evidence.

The script deliberately requires every clean-machine claim as an explicit flag.
It does not inspect the machine and infer release cleanliness; the operator is
attesting to the release environment, and the output is bound to this host's
hardware UUID for later verifier matching.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ASSERTION_FLAGS = [
    ("firstThreadCreated", "--assert-first-thread-created", "The clean install created and completed the first thread."),
    ("spawnedWorkerLogged", "--assert-spawned-worker-logged", "The run logged spawned-worker mode."),
    ("workerReadyLogged", "--assert-worker-ready-logged", "The spawned worker logged ready."),
    ("installRootRemoved", "--assert-install-root-removed", "The install root was removed after uninstall."),
    ("launchAgentsPlistsRemoved", "--assert-launch-agents-plists-removed", "LaunchAgent plists were removed after uninstall."),
    ("codexHomePurged", "--assert-codex-home-purged", "CODEX_HOME was purged after uninstall."),
]


def hardware_uuid() -> str:
    try:
        out = subprocess.check_output(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception as exc:
        raise SystemExit(f"failed to read host hardware UUID: {exc}") from exc
    for line in out.splitlines():
        if '"IOPlatformUUID"' in line and "=" in line:
            value = line.split("=", 1)[1].strip().strip('"')
            if value:
                return value
    raise SystemExit("failed to parse host hardware UUID from ioreg output")


def build_payload(args: argparse.Namespace, *, host_hardware_uuid: str) -> dict[str, Any]:
    missing = [flag for key, flag, _ in ASSERTION_FLAGS if not getattr(args, key)]
    if missing:
        raise SystemExit("missing required clean-machine assertion flags: " + ", ".join(missing))
    if not args.operator.strip():
        raise SystemExit("--operator is required")
    return {
        "trueCleanMachine": True,
        "operator": args.operator.strip(),
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "host": {"hardwareUUID": host_hardware_uuid},
        "assertions": {key: True for key, _, _ in ASSERTION_FLAGS},
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--operator", required=True, help="Release operator name or handle.")
    p.add_argument("--output", type=Path, help="Write attestation JSON to this path; stdout if omitted.")
    for key, flag, help_text in ASSERTION_FLAGS:
        p.add_argument(flag, dest=key, action="store_true", help=help_text)
    return p


def main() -> None:
    args = parser().parse_args()
    payload = build_payload(args, host_hardware_uuid=hardware_uuid())
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
        print(args.output)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
