#!/usr/bin/env python3
"""Write the g9 final rehearsal manifest.

The manifest is an integrity index for the current rehearsal run. When a caller
reuses CODEXKIT_EVIDENCE_DIR, JSON files that were already present before the
run are deliberately excluded so stale artifacts cannot satisfy release proof.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def sw_vers() -> dict[str, str]:
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}


def hardware_uuid() -> str | None:
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


def read_initial_files(initial_evidence_list: Path) -> set[str]:
    if not initial_evidence_list.exists():
        return set()
    return {
        str(Path(line).resolve())
        for line in initial_evidence_list.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def preserved_initial_files() -> set[str]:
    preserved = set()
    clean_attestation = os.environ.get("CODEXKIT_CLEAN_MACHINE_ATTESTATION")
    if clean_attestation:
        preserved.add(str(Path(clean_attestation).resolve()))
    true_reboot_evidence = os.environ.get("CODEXKIT_TRUE_REBOOT_EVIDENCE")
    if true_reboot_evidence:
        preserved.add(str(Path(true_reboot_evidence).resolve()))
    return preserved


def evidence_files(evidence_dir: Path, manifest: Path, initial_files: set[str], preserved: set[str]) -> list[str]:
    return sorted(
        str(p)
        for p in evidence_dir.glob("*.json")
        if p.resolve() != manifest.resolve()
        and (
            str(p.resolve()) not in initial_files
            or str(p.resolve()) in preserved
        )
    )


def manifest_payload(evidence_dir: Path, *, strict: bool, initial_evidence_list: Path) -> dict:
    manifest = evidence_dir / "g9_final_rehearsal.manifest.json"
    files = evidence_files(
        evidence_dir,
        manifest,
        read_initial_files(initial_evidence_list),
        preserved_initial_files(),
    )
    hashes = {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in files}
    payload = {
        "gate": "g9_final_rehearsal",
        "result": "passed",
        "strict": strict,
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "host": {
            "uname": platform.platform(),
            "sw_vers": sw_vers(),
            "hardwareUUID": hardware_uuid(),
        },
        "configuration": {
            "openAIKeyConfigured": bool(os.environ.get("OPENAI_API_KEY")),
            "notaryProfileConfigured": bool(os.environ.get("CODEXKIT_NOTARY_PROFILE")),
            "trueCleanMachine": os.environ.get("CODEXKIT_TRUE_CLEAN_MACHINE") == "1",
            "cleanMachineAttestation": os.environ.get("CODEXKIT_CLEAN_MACHINE_ATTESTATION"),
            "trueRebootEvidence": os.environ.get("CODEXKIT_TRUE_REBOOT_EVIDENCE"),
            "physicalFootprintExpectedEnforced": strict,
            "soakSeconds": int(os.environ.get("CODEXKIT_SOAK_SECONDS", "45")),
            "soakSessions": int(os.environ.get("CODEXKIT_SOAK_SESSIONS", "8")),
            "soakTurns": int(os.environ.get("CODEXKIT_SOAK_TURNS", "3")),
            "soakLiveEnabled": os.environ.get("CODEXKIT_SOAK_LIVE", "auto") != "0",
            "soakLiveSeconds": int(os.environ.get("CODEXKIT_SOAK_LIVE_SECONDS", "60")),
            "soakLiveSessions": int(os.environ.get("CODEXKIT_SOAK_LIVE_SESSIONS", "2")),
            "soakLiveTurns": int(os.environ.get("CODEXKIT_SOAK_LIVE_TURNS", "2")),
            "liveCodingEnabled": os.environ.get("CODEXKIT_SOAK_LIVE_CODING", "1") != "0",
            "liveCodingSessions": int(os.environ.get("CODEXKIT_LIVE_CODING_SESSIONS", "2")),
            "liveCodingTurns": int(os.environ.get("CODEXKIT_LIVE_CODING_TURNS", "3")),
        },
        "evidenceFiles": files,
        "evidenceFileHashes": hashes,
    }
    if strict:
        assert payload["configuration"]["openAIKeyConfigured"], payload
        assert payload["configuration"]["notaryProfileConfigured"], payload
        assert payload["configuration"]["trueCleanMachine"], payload
        assert payload["configuration"]["cleanMachineAttestation"], payload
        assert payload["configuration"]["trueRebootEvidence"], payload
        assert payload["configuration"]["soakSeconds"] >= 86400, payload
        assert payload["configuration"]["soakSessions"] >= 50, payload
        assert payload["configuration"]["soakTurns"] >= 1, payload
        assert payload["configuration"]["soakLiveEnabled"], payload
        assert payload["configuration"]["soakLiveSeconds"] >= 1, payload
        assert payload["configuration"]["soakLiveSessions"] >= 2, payload
        assert payload["configuration"]["soakLiveTurns"] >= 2, payload
        assert payload["configuration"]["liveCodingEnabled"], payload
        assert payload["configuration"]["liveCodingSessions"] >= 2, payload
        assert payload["configuration"]["liveCodingTurns"] >= 3, payload
    return payload


def write_manifest(evidence_dir: Path, *, strict: bool, initial_evidence_list: Path) -> Path:
    manifest = evidence_dir / "g9_final_rehearsal.manifest.json"
    payload = manifest_payload(evidence_dir, strict=strict, initial_evidence_list=initial_evidence_list)
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: write_final_rehearsal_manifest.py <evidence-dir> <strict:0|1> <initial-evidence-list>",
            file=sys.stderr,
        )
        return 2
    evidence_dir = Path(argv[1])
    strict = argv[2] == "1"
    initial_evidence_list = Path(argv[3])
    manifest = write_manifest(evidence_dir, strict=strict, initial_evidence_list=initial_evidence_list)
    print(f"evidence={manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
