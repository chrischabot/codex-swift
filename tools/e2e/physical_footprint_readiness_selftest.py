#!/usr/bin/env python3
"""Self-test physical-footprint readiness helper with mocked gate scripts."""

from __future__ import annotations

import importlib.util
import json
import stat
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "e2e" / "physical_footprint_readiness.py"


def load_module():
    spec = importlib.util.spec_from_file_location("physical_footprint_readiness", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_script(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def strict_payload(*, enforced: bool = True) -> dict:
    return {
        "gate": "g6_physical_footprint",
        "result": "passed" if enforced else "degraded",
        "host": {"hardwareUUID": "SELFTEST-HW"},
        "configuration": {"capMib": 64, "allocMib": 256, "expectEnforced": True},
        "probe": {
            "startedAt": "2026-05-20T00:00:00Z",
            "finishedAt": "2026-05-20T00:00:01Z",
            "returncode": 137 if enforced else 42,
            "setOk": enforced,
            "setFailed": not enforced,
            "survivedAllocation": False,
            "allocationFailed": False,
            "signalTerminated": enforced,
            "terminatedAfterSet": enforced,
            "maxAllocatedMib": 96 if enforced else 0,
            "exceededCap": enforced,
            "enforced": enforced,
            "output": "SET_OK old=0 cap_mib=64\nALLOCATED mib=96\n" if enforced else "SET_FAILED kr=8 old=0\n",
        },
    }


def main() -> None:
    module = load_module()
    with tempfile.TemporaryDirectory(prefix="codexkit-footprint-readiness-selftest-") as raw:
        temp = Path(raw)
        ok_script = temp / "ok.sh"
        ok_payload = json.dumps(strict_payload()).replace("'", "'\"'\"'")
        write_script(
            ok_script,
            f"printf '%s\\n' '{ok_payload}' > \"$CODEXKIT_EVIDENCE_DIR/g6_physical_footprint-000.json\"\n",
        )
        result = module.check(ok_script, timeout=5)
        assert result["enforced"] is True, result
        assert result["capMib"] == 64, result
        assert result["maxAllocatedMib"] == 96, result

        degraded_script = temp / "degraded.sh"
        bad_payload = json.dumps(strict_payload(enforced=False)).replace("'", "'\"'\"'")
        write_script(
            degraded_script,
            f"printf '%s\\n' '{bad_payload}' > \"$CODEXKIT_EVIDENCE_DIR/g6_physical_footprint-000.json\"\n",
        )
        try:
            module.check(degraded_script, timeout=5)
        except Exception as exc:
            assert "strict release requires physical-footprint probe to pass" in str(exc), exc
        else:
            raise AssertionError("degraded physical-footprint evidence was accepted")

        failing_script = temp / "failing.sh"
        write_script(failing_script, "echo probe failed >&2\nexit 7\n")
        try:
            module.check(failing_script, timeout=5)
        except SystemExit as exc:
            assert "physical-footprint enforced probe failed" in str(exc), exc
        else:
            raise AssertionError("failing physical-footprint script was accepted")

    print("physical_footprint_readiness_selftest OK")


if __name__ == "__main__":
    main()
