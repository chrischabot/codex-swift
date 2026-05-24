#!/usr/bin/env python3
"""Audit strict macOS release readiness without running the release rehearsal.

This is a preflight/audit companion to `g9_final_rehearsal.sh`. It never
manufactures evidence and never downgrades strict requirements; it only reports
which external inputs and evidence artifacts are already strong enough for the
strict verifier to consider.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import verify_release_evidence as verifier


Json = dict[str, Any]


def parse_utc_timestamp(value: Any) -> datetime | None:
    return verifier.parse_utc_timestamp(value)


def load_json(path: Path) -> Json:
    return json.loads(path.read_text(encoding="utf-8"))


def result(item_id: str, label: str, status: str, detail: str) -> Json:
    return {"id": item_id, "label": label, "status": status, "detail": detail}


def short_detail(value: Any, limit: int = 600) -> str:
    text = str(value)
    if len(text) <= limit:
        return text
    return text[:limit] + f"... [truncated {len(text) - limit} chars]"


def check_int_env(env: dict[str, str], name: str, minimum: int, label: str) -> Json:
    raw = env.get(name)
    if raw is None or raw == "":
        return result(name, label, "failed", f"{name} is not set")
    try:
        value = int(raw)
    except ValueError:
        return result(name, label, "failed", f"{name} must be an integer >= {minimum}")
    if value < minimum:
        return result(name, label, "failed", f"{name}={value}, expected >= {minimum}")
    return result(name, label, "passed", f"{name}={value}")


def check_attestation(env: dict[str, str]) -> Json:
    raw = env.get("CODEXKIT_CLEAN_MACHINE_ATTESTATION")
    label = "true clean-machine attestation JSON"
    if not raw:
        return result(
            "cleanMachineAttestation",
            label,
            "failed",
            "CODEXKIT_CLEAN_MACHINE_ATTESTATION is not set; generate one with tools/e2e/clean_machine_attestation.py on the clean release target",
        )
    path = Path(raw)
    if not path.is_file():
        return result("cleanMachineAttestation", label, "failed", f"attestation file does not exist: {path}")
    try:
        payload = load_json(path)
    except Exception as exc:
        return result("cleanMachineAttestation", label, "failed", f"attestation JSON is unreadable: {exc}")
    if payload.get("trueCleanMachine") is not True:
        return result("cleanMachineAttestation", label, "failed", "attestation trueCleanMachine is not true")
    if not payload.get("operator"):
        return result("cleanMachineAttestation", label, "failed", "attestation operator is missing")
    if parse_utc_timestamp(payload.get("timestamp")) is None:
        return result("cleanMachineAttestation", label, "failed", "attestation timestamp is not valid timezone-aware UTC")
    assertions = payload.get("assertions")
    if not isinstance(assertions, dict) or not assertions:
        return result("cleanMachineAttestation", label, "failed", "attestation assertions are missing")
    failed = [k for k, v in assertions.items() if v is not True]
    if failed:
        return result("cleanMachineAttestation", label, "failed", f"attestation assertions failed: {', '.join(sorted(failed))}")
    hardware_uuid = (payload.get("host") or {}).get("hardwareUUID")
    if not hardware_uuid:
        return result("cleanMachineAttestation", label, "failed", "attestation host.hardwareUUID is missing")
    return result("cleanMachineAttestation", label, "passed", f"{path} hardwareUUID={hardware_uuid}")


def check_notary_profile(env: dict[str, str], *, require_live_check: bool) -> Json:
    profile = env.get("CODEXKIT_NOTARY_PROFILE")
    label = "CODEXKIT_NOTARY_PROFILE for notarytool"
    if not profile:
        return result("notaryProfile", label, "failed", "CODEXKIT_NOTARY_PROFILE is not set")
    if env.get("CODEXKIT_NOTARY_PROFILE_LIVE_CHECK") != "1":
        if require_live_check:
            return result(
                "notaryProfile",
                label,
                "failed",
                "release certification requires CODEXKIT_NOTARY_PROFILE_LIVE_CHECK=1 so the saved keychain profile is validated before the release run",
            )
        return result(
            "notaryProfile",
            label,
            "passed",
            "CODEXKIT_NOTARY_PROFILE is set; set CODEXKIT_NOTARY_PROFILE_LIVE_CHECK=1 to validate the saved keychain profile before the release run",
        )
    proc = subprocess.run(
        ["python3", "tools/e2e/notary_profile_readiness.py", "--profile", profile],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=False,
    )
    if proc.returncode != 0:
        return result("notaryProfile", label, "failed", (proc.stderr or proc.stdout).strip())
    return result("notaryProfile", label, "passed", proc.stdout.strip())


def check_physical_footprint(env: dict[str, str], *, require_live_check: bool) -> Json:
    label = "kernel-enforced physical-footprint cap"
    if env.get("CODEXKIT_FOOTPRINT_LIVE_CHECK") != "1":
        if require_live_check:
            return result(
                "physicalFootprint",
                label,
                "failed",
                "release certification requires CODEXKIT_FOOTPRINT_LIVE_CHECK=1 so the enforced physical-footprint readiness probe runs before the release rehearsal",
            )
        return result(
            "physicalFootprint",
            label,
            "not_checked",
            "set CODEXKIT_FOOTPRINT_LIVE_CHECK=1 to run the enforced physical-footprint readiness probe before the release rehearsal",
        )
    proc = subprocess.run(
        ["python3", "tools/e2e/physical_footprint_readiness.py"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=150,
        check=False,
    )
    if proc.returncode != 0:
        return result("physicalFootprint", label, "failed", (proc.stderr or proc.stdout).strip())
    return result("physicalFootprint", label, "passed", proc.stdout.strip())


def check_true_reboot_evidence(env: dict[str, str]) -> Json:
    raw = env.get("CODEXKIT_TRUE_REBOOT_EVIDENCE")
    label = "verified true reboot evidence JSON"
    if not raw:
        return result("trueRebootEvidence", label, "failed", "CODEXKIT_TRUE_REBOOT_EVIDENCE is not set")
    path = Path(raw)
    if not path.is_file():
        return result("trueRebootEvidence", label, "failed", f"true reboot evidence file does not exist: {path}")
    try:
        payload = load_json(path)
    except Exception as exc:
        return result("trueRebootEvidence", label, "failed", f"true reboot JSON is unreadable: {exc}")
    checks = [
        (payload.get("gate") == "g6_true_reboot_resume", "gate is not g6_true_reboot_resume"),
        (payload.get("result") == "passed", "result is not passed"),
        (payload.get("phase") == "verified", "phase is not verified"),
        (payload.get("trueOSReboot") is True, "trueOSReboot is not true"),
    ]
    for ok, message in checks:
        if not ok:
            return result("trueRebootEvidence", label, "failed", message)
    boot = payload.get("boot") or {}
    if boot.get("bootTimeChanged") is not True:
        return result("trueRebootEvidence", label, "failed", "bootTimeChanged is not true")
    if boot.get("verifyBootTimeAfterPrepare") is not True:
        return result("trueRebootEvidence", label, "failed", "verifyBootTimeAfterPrepare is not true")
    if not isinstance(boot.get("prepareBootTimeSec"), int) or not isinstance(boot.get("verifyBootTimeSec"), int):
        return result("trueRebootEvidence", label, "failed", "boot time fields are missing")
    if boot["verifyBootTimeSec"] <= boot["prepareBootTimeSec"]:
        return result("trueRebootEvidence", label, "failed", "verify boot time is not later than prepare boot time")
    if boot.get("hardwareUUIDMatched") is not True:
        return result("trueRebootEvidence", label, "failed", "hardwareUUIDMatched is not true")
    prepared_at = parse_utc_timestamp(payload.get("preparedAt"))
    verified_at = parse_utc_timestamp(payload.get("verifiedAt"))
    if prepared_at is None or verified_at is None or verified_at <= prepared_at:
        return result("trueRebootEvidence", label, "failed", "preparedAt/verifiedAt timestamps are invalid or non-monotonic")
    evidence_hw = (payload.get("host") or {}).get("hardwareUUID")
    prepare_hw = boot.get("prepareHardwareUUID")
    verify_hw = boot.get("verifyHardwareUUID")
    if not evidence_hw or evidence_hw != prepare_hw or evidence_hw != verify_hw:
        return result("trueRebootEvidence", label, "failed", "hardware UUIDs are missing or mismatched")
    if (payload.get("turnCountAfterResume") or 0) < 2:
        return result("trueRebootEvidence", label, "failed", "turnCountAfterResume is below 2")
    return result("trueRebootEvidence", label, "passed", f"{path} hardwareUUID={evidence_hw}")


def check_strict_bundle(evidence_dir: Path | None, *, require_evidence: bool, env: dict[str, str]) -> Json:
    label = "strict final evidence bundle"
    if evidence_dir is None:
        status = "failed" if require_evidence else "not_checked"
        detail = "no evidence directory provided"
        return result("strictEvidenceBundle", label, status, detail)
    if not evidence_dir.is_dir():
        return result("strictEvidenceBundle", label, "failed", f"evidence directory does not exist: {evidence_dir}")
    try:
        report = verifier.verify(
            evidence_dir,
            strict=True,
            openai_key=env.get("OPENAI_API_KEY"),
            notary_profile=env.get("CODEXKIT_NOTARY_PROFILE"),
        )
    except verifier.EvidenceError as exc:
        return result("strictEvidenceBundle", label, "failed", short_detail(exc))
    checks = report.get("checks") or {}
    return result("strictEvidenceBundle", label, "passed", json.dumps(checks, sort_keys=True))


def fail_unchecked_for_certification(checks: list[Json]) -> list[Json]:
    normalized: list[Json] = []
    for item in checks:
        if item["status"] != "not_checked":
            normalized.append(item)
            continue
        updated = dict(item)
        updated["status"] = "failed"
        updated["detail"] = f"release certification requires this check to run; {item['detail']}"
        normalized.append(updated)
    return normalized


def audit(
    env: dict[str, str],
    evidence_dir: Path | None,
    *,
    require_evidence: bool,
    release_certification: bool = False,
) -> Json:
    checks: list[Json] = []
    checks.append(result(
        "openaiKey",
        "OPENAI_API_KEY for live OpenAI tests",
        "passed" if env.get("OPENAI_API_KEY") else "failed",
        "OPENAI_API_KEY is set" if env.get("OPENAI_API_KEY") else "OPENAI_API_KEY is not set",
    ))
    checks.append(check_notary_profile(env, require_live_check=release_certification))
    checks.append(result(
        "trueCleanMachineFlag",
        "CODEXKIT_TRUE_CLEAN_MACHINE=1",
        "passed" if env.get("CODEXKIT_TRUE_CLEAN_MACHINE") == "1" else "failed",
        f"CODEXKIT_TRUE_CLEAN_MACHINE={env.get('CODEXKIT_TRUE_CLEAN_MACHINE')!r}",
    ))
    checks.append(check_attestation(env))
    checks.append(check_true_reboot_evidence(env))
    checks.extend([
        check_int_env(env, "CODEXKIT_SOAK_SECONDS", 86400, "24-hour mock/noisy soak duration"),
        check_int_env(env, "CODEXKIT_SOAK_SESSIONS", 50, "50-session mock/noisy soak width"),
        check_int_env(env, "CODEXKIT_SOAK_TURNS", 1, "mock/noisy soak turns per session"),
    ])
    live_enabled = env.get("CODEXKIT_SOAK_LIVE", "auto") != "0"
    checks.append(result(
        "soakLiveEnabled",
        "live soak enabled",
        "passed" if live_enabled else "failed",
        f"CODEXKIT_SOAK_LIVE={env.get('CODEXKIT_SOAK_LIVE', 'auto')!r}",
    ))
    checks.extend([
        check_int_env(env, "CODEXKIT_SOAK_LIVE_SECONDS", 1, "live soak measured duration"),
        check_int_env(env, "CODEXKIT_SOAK_LIVE_SESSIONS", 2, "multi-session live soak width"),
        check_int_env(env, "CODEXKIT_SOAK_LIVE_TURNS", 2, "multi-turn live soak depth"),
    ])
    live_coding_enabled = env.get("CODEXKIT_SOAK_LIVE_CODING", "1") != "0"
    checks.append(result(
        "liveCodingEnabled",
        "release-binary live coding enabled",
        "passed" if live_coding_enabled else "failed",
        f"CODEXKIT_SOAK_LIVE_CODING={env.get('CODEXKIT_SOAK_LIVE_CODING', '1')!r}",
    ))
    checks.extend([
        check_int_env(env, "CODEXKIT_LIVE_CODING_SESSIONS", 2, "multi-session live coding width"),
        check_int_env(env, "CODEXKIT_LIVE_CODING_TURNS", 3, "complex multi-turn live coding depth"),
    ])
    checks.append(check_physical_footprint(env, require_live_check=release_certification))
    checks.append(check_strict_bundle(evidence_dir, require_evidence=require_evidence or release_certification, env=env))
    if release_certification:
        checks = fail_unchecked_for_certification(checks)
    failed = [item for item in checks if item["status"] == "failed"]
    return {
        "result": "failed" if failed else "passed",
        "checks": checks,
        "failedCount": len(failed),
        "notCheckedCount": sum(1 for item in checks if item["status"] == "not_checked"),
        "releaseCertification": release_certification,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--require-evidence", action="store_true")
    parser.add_argument(
        "--release-certification",
        action="store_true",
        help="Require live notary and physical-footprint probes, require a strict evidence bundle, and fail any skipped check.",
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()
    report = audit(
        os.environ.copy(),
        args.evidence_dir,
        require_evidence=args.require_evidence,
        release_certification=args.release_certification,
    )
    if args.json_output:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for item in report["checks"]:
            print(f"{item['status'].upper():11} {item['id']}: {item['detail']}")
        print(f"result={report['result']} failed={report['failedCount']} not_checked={report['notCheckedCount']}")
    raise SystemExit(0 if report["result"] == "passed" else 1)


if __name__ == "__main__":
    main()
