#!/usr/bin/env python3
"""Self-test strict final rehearsal preflight failures.

These cases must fail before the final rehearsal reaches release build,
signing, install, or live OpenAI work.
"""

from __future__ import annotations

import os
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "e2e" / "g9_final_rehearsal.sh"


def good_attestation() -> dict:
    assertions = {
        "firstThreadCreated": True,
        "spawnedWorkerLogged": True,
        "workerReadyLogged": True,
        "installRootRemoved": True,
        "launchAgentsPlistsRemoved": True,
        "codexHomePurged": True,
    }
    return {
        "trueCleanMachine": True,
        "operator": "preflight-selftest",
        "timestamp": "2026-05-20T00:00:00Z",
        "host": {"hardwareUUID": "PREFLIGHT-HW"},
        "assertions": assertions,
    }


def good_true_reboot() -> dict:
    return {
        "gate": "g6_true_reboot_resume",
        "result": "passed",
        "phase": "verified",
        "trueOSReboot": True,
        "preparedAt": "2026-05-20T00:00:10Z",
        "verifiedAt": "2026-05-20T00:10:10Z",
        "host": {"hardwareUUID": "PREFLIGHT-HW"},
        "threadId": "thr-preflight",
        "turnCountAfterResume": 2,
        "boot": {
            "bootTimeChanged": True,
            "prepareBootTimeSec": 1779235200,
            "verifyBootTimeSec": 1779235700,
            "verifyBootTimeAfterPrepare": True,
            "prepareHardwareUUID": "PREFLIGHT-HW",
            "verifyHardwareUUID": "PREFLIGHT-HW",
            "hardwareUUIDMatched": True,
        },
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def base_env(temp: Path) -> dict[str, str]:
    attestation = temp / "attestation.json"
    reboot = temp / "true-reboot.json"
    write_json(attestation, good_attestation())
    write_json(reboot, good_true_reboot())
    env = os.environ.copy()
    env.update(
        {
            "CODEXKIT_FINAL_STRICT": "1",
            "OPENAI_API_KEY": "sk-test-preflight",
            "CODEXKIT_NOTARY_PROFILE": "preflight-profile",
            "CODEXKIT_TRUE_CLEAN_MACHINE": "1",
            "CODEXKIT_CLEAN_MACHINE_ATTESTATION": str(attestation),
            "CODEXKIT_TRUE_REBOOT_EVIDENCE": str(reboot),
            "CODEXKIT_SOAK_SECONDS": "86400",
            "CODEXKIT_SOAK_SESSIONS": "50",
            "CODEXKIT_SOAK_TURNS": "1",
            "CODEXKIT_SOAK_LIVE": "1",
            "CODEXKIT_SOAK_LIVE_SECONDS": "1",
            "CODEXKIT_SOAK_LIVE_SESSIONS": "2",
            "CODEXKIT_SOAK_LIVE_TURNS": "2",
            "CODEXKIT_SOAK_LIVE_CODING": "1",
            "CODEXKIT_LIVE_CODING_SESSIONS": "2",
            "CODEXKIT_LIVE_CODING_TURNS": "3",
        }
    )
    return env


def assert_preflight_rejects(
    overrides: dict[str, str],
    expected: str,
    setup: Callable[[Path, dict[str, str]], None] | None = None,
) -> None:
    with tempfile.TemporaryDirectory(prefix="codexkit-g9-preflight-") as raw:
        temp = Path(raw)
        env = base_env(temp)
        if setup is not None:
            setup(temp, env)
        env.update(overrides)
        proc = subprocess.run(
            [str(SCRIPT)],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        if proc.returncode == 0:
            raise AssertionError(f"preflight unexpectedly passed for {overrides!r}")
        if expected not in proc.stderr:
            raise AssertionError(
                f"expected {expected!r} in stderr for {overrides!r}; got {proc.stderr!r}"
            )


def main() -> None:
    assert_preflight_rejects(
        {"CODEXKIT_SOAK_SECONDS": "abc"},
        "CODEXKIT_SOAK_SECONDS to be an integer >=86400",
    )
    assert_preflight_rejects(
        {"CODEXKIT_SOAK_SESSIONS": "49"},
        "CODEXKIT_SOAK_SESSIONS>=50",
    )
    assert_preflight_rejects(
        {"CODEXKIT_SOAK_LIVE_SESSIONS": "1"},
        "CODEXKIT_SOAK_LIVE_SESSIONS>=2",
    )
    assert_preflight_rejects(
        {"CODEXKIT_SOAK_LIVE_TURNS": "1"},
        "CODEXKIT_SOAK_LIVE_TURNS>=2",
    )
    assert_preflight_rejects(
        {"CODEXKIT_LIVE_CODING_SESSIONS": "1"},
        "CODEXKIT_LIVE_CODING_SESSIONS>=2",
    )
    assert_preflight_rejects(
        {"CODEXKIT_LIVE_CODING_TURNS": "2"},
        "CODEXKIT_LIVE_CODING_TURNS>=3",
    )
    assert_preflight_rejects(
        {},
        "attestation assertions failed",
        setup=lambda temp, env: write_json(
            Path(env["CODEXKIT_CLEAN_MACHINE_ATTESTATION"]),
            {
                **good_attestation(),
                "assertions": {**good_attestation()["assertions"], "codexHomePurged": False},
            },
        ),
    )
    assert_preflight_rejects(
        {},
        "hardwareUUIDMatched is not true",
        setup=lambda temp, env: write_json(
            Path(env["CODEXKIT_TRUE_REBOOT_EVIDENCE"]),
            {
                **good_true_reboot(),
                "boot": {**good_true_reboot()["boot"], "hardwareUUIDMatched": False},
            },
        ),
    )
    print("g9_strict_preflight_selftest OK")


if __name__ == "__main__":
    main()
