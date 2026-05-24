#!/usr/bin/env python3
"""Self-test current-run-only final rehearsal manifest indexing."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path

import write_final_rehearsal_manifest as writer


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def snapshot(evidence_dir: Path, path: Path) -> None:
    entries = sorted(str(p) for p in evidence_dir.glob("*.json"))
    path.write_text("\n".join(entries) + ("\n" if entries else ""), encoding="utf-8")


def load_manifest(evidence_dir: Path) -> dict:
    return json.loads((evidence_dir / "g9_final_rehearsal.manifest.json").read_text(encoding="utf-8"))


def assert_hashes_match(payload: dict) -> None:
    files = payload["evidenceFiles"]
    hashes = payload["evidenceFileHashes"]
    assert set(files) == set(hashes), payload
    for path, expected in hashes.items():
        actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        assert actual == expected, {"path": path, "expected": expected, "actual": actual}


def test_reused_directory_excludes_stale_json() -> None:
    with tempfile.TemporaryDirectory(prefix="codexkit-g9-current-run-") as raw:
        evidence_dir = Path(raw)
        stale = evidence_dir / "stale-old.json"
        write_json(stale, {"stale": True})
        initial = evidence_dir / ".g9-initial.txt"
        snapshot(evidence_dir, initial)

        current = evidence_dir / "g6_soak-000.manifest.json"
        write_json(current, {"result": "passed"})
        writer.write_manifest(evidence_dir, strict=False, initial_evidence_list=initial)

        payload = load_manifest(evidence_dir)
        resolved = {str(Path(path).resolve()) for path in payload["evidenceFiles"]}
        assert str(stale.resolve()) not in resolved, payload
        assert str(current.resolve()) in resolved, payload
        assert str((evidence_dir / "g9_final_rehearsal.manifest.json").resolve()) not in resolved, payload
        assert_hashes_match(payload)


def test_strict_true_reboot_can_preserve_preexisting_release_input() -> None:
    with tempfile.TemporaryDirectory(prefix="codexkit-g9-current-run-") as raw:
        evidence_dir = Path(raw)
        attestation = evidence_dir / "g6_clean_machine_attestation-000.json"
        write_json(attestation, {"trueCleanMachine": True})
        reboot = evidence_dir / "g6_true_reboot_resume-000.json"
        write_json(reboot, {"result": "passed", "phase": "verified"})
        stale = evidence_dir / "stale-old.json"
        write_json(stale, {"stale": True})
        initial = evidence_dir / ".g9-initial.txt"
        snapshot(evidence_dir, initial)

        current = evidence_dir / "g6_soak-000.manifest.json"
        write_json(current, {"result": "passed"})
        old_env = os.environ.copy()
        try:
            os.environ.update(
                {
                    "OPENAI_API_KEY": "sk-test",
                    "CODEXKIT_NOTARY_PROFILE": "profile",
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
            writer.write_manifest(evidence_dir, strict=True, initial_evidence_list=initial)
        finally:
            os.environ.clear()
            os.environ.update(old_env)

        payload = load_manifest(evidence_dir)
        resolved = {str(Path(path).resolve()) for path in payload["evidenceFiles"]}
        assert str(attestation.resolve()) in resolved, payload
        assert str(reboot.resolve()) in resolved, payload
        assert str(current.resolve()) in resolved, payload
        assert str(stale.resolve()) not in resolved, payload
        assert_hashes_match(payload)


def main() -> None:
    test_reused_directory_excludes_stale_json()
    test_strict_true_reboot_can_preserve_preexisting_release_input()
    print("g9_manifest_current_run_selftest OK")


if __name__ == "__main__":
    main()
