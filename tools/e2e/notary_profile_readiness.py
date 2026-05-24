#!/usr/bin/env python3
"""Validate that a saved notarytool keychain profile can authenticate.

This intentionally performs only the cheapest Apple notary API probe available
through `notarytool history`; it does not submit or notarize an artifact. Use it
before a strict release run to catch a missing/expired keychain profile before
build, signing, soak, or packaging work.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from typing import Any


def validate_profile(profile: str, *, timeout: int = 60) -> dict[str, Any]:
    if not profile.strip():
        raise SystemExit("--profile is required")
    cmd = [
        "xcrun",
        "notarytool",
        "history",
        "--keychain-profile",
        profile,
        "--output-format",
        "json",
    ]
    proc = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise SystemExit(f"notary profile validation failed for {profile!r}: {detail}")
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"notarytool history did not return JSON: {exc}") from exc
    history = payload.get("history")
    if history is not None and not isinstance(history, list):
        raise SystemExit("notarytool history JSON has non-list 'history' field")
    return {
        "profile": profile,
        "authenticated": True,
        "historyCount": len(history) if isinstance(history, list) else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    print(json.dumps(validate_profile(args.profile, timeout=args.timeout), sort_keys=True))


if __name__ == "__main__":
    main()
