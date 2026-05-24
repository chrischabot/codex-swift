#!/usr/bin/env python3
"""Self-test strict release readiness auditing."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "e2e" / "strict_release_readiness.py"


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


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
        "operator": "selftest",
        "timestamp": "2026-05-20T00:00:00Z",
        "host": {"hardwareUUID": "SELFTEST-HW"},
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
        "host": {"hardwareUUID": "SELFTEST-HW"},
        "threadId": "thr-selftest",
        "turnCountAfterResume": 2,
        "boot": {
            "bootTimeChanged": True,
            "prepareBootTimeSec": 1779235200,
            "verifyBootTimeSec": 1779235700,
            "verifyBootTimeAfterPrepare": True,
            "prepareHardwareUUID": "SELFTEST-HW",
            "verifyHardwareUUID": "SELFTEST-HW",
            "hardwareUUIDMatched": True,
        },
    }


def base_env(temp: Path) -> dict[str, str]:
    attestation = temp / "attestation.json"
    reboot = temp / "true-reboot.json"
    write_json(attestation, good_attestation())
    write_json(reboot, good_true_reboot())
    env = os.environ.copy()
    env.update(
        {
            "OPENAI_API_KEY": "sk-selftest-readiness",
            "CODEXKIT_NOTARY_PROFILE": "selftest-notary-profile",
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


def run_readiness(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(SCRIPT), *args],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )


def assert_rejects(env: dict[str, str], expected: str, *args: str) -> None:
    proc = run_readiness(env, *args)
    if proc.returncode == 0:
        raise AssertionError(f"readiness unexpectedly passed; stdout={proc.stdout!r}")
    if expected not in proc.stdout and expected not in proc.stderr:
        raise AssertionError(f"expected {expected!r}; stdout={proc.stdout!r}; stderr={proc.stderr!r}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="codexkit-readiness-selftest-") as raw:
        temp = Path(raw)
        env = base_env(temp)
        proc = run_readiness(env, "--json")
        if proc.returncode != 0:
            raise AssertionError(f"readiness env-only pass failed: {proc.stdout!r} {proc.stderr!r}")
        report = json.loads(proc.stdout)
        if report["result"] != "passed" or report["notCheckedCount"] != 2 or report["releaseCertification"] is not False:
            raise AssertionError(f"unexpected readiness report: {report!r}")

        proc = run_readiness(env, "--release-certification", "--json")
        if proc.returncode == 0:
            raise AssertionError(f"release certification unexpectedly passed; stdout={proc.stdout!r}")
        report = json.loads(proc.stdout)
        if report["result"] != "failed" or report["notCheckedCount"] != 0 or report["releaseCertification"] is not True:
            raise AssertionError(f"unexpected release certification report: {report!r}")
        details = "\n".join(item["detail"] for item in report["checks"])
        for expected in [
            "CODEXKIT_NOTARY_PROFILE_LIVE_CHECK=1",
            "CODEXKIT_FOOTPRINT_LIVE_CHECK=1",
            "no evidence directory provided",
        ]:
            if expected not in details:
                raise AssertionError(f"release certification did not report {expected!r}: {report!r}")

        bad = dict(env)
        bad.pop("CODEXKIT_NOTARY_PROFILE")
        assert_rejects(bad, "CODEXKIT_NOTARY_PROFILE is not set")

        bad = dict(env)
        bad["CODEXKIT_SOAK_SECONDS"] = "86399"
        assert_rejects(bad, "expected >= 86400")

        bad_attestation = temp / "bad-attestation.json"
        payload = good_attestation()
        payload["assertions"]["codexHomePurged"] = False
        write_json(bad_attestation, payload)
        bad = dict(env)
        bad["CODEXKIT_CLEAN_MACHINE_ATTESTATION"] = str(bad_attestation)
        assert_rejects(bad, "attestation assertions failed")

        bad_reboot = temp / "bad-reboot.json"
        reboot = good_true_reboot()
        reboot["boot"]["hardwareUUIDMatched"] = False
        write_json(bad_reboot, reboot)
        bad = dict(env)
        bad["CODEXKIT_TRUE_REBOOT_EVIDENCE"] = str(bad_reboot)
        assert_rejects(bad, "hardwareUUIDMatched is not true")

        assert_rejects(env, "no evidence directory provided", "--require-evidence")

    print("strict_release_readiness_selftest OK")


if __name__ == "__main__":
    main()
