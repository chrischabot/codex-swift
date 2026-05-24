#!/usr/bin/env python3
"""Self-test clean-machine attestation generation."""

from __future__ import annotations

import argparse
import importlib.util
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "e2e" / "clean_machine_attestation.py"


def load_module():
    spec = importlib.util.spec_from_file_location("clean_machine_attestation", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def good_args(module, output: Path | None = None) -> argparse.Namespace:
    values = {"operator": "selftest", "output": output}
    for key, _, _ in module.ASSERTION_FLAGS:
        values[key] = True
    return argparse.Namespace(**values)


def main() -> None:
    module = load_module()
    payload = module.build_payload(good_args(module), host_hardware_uuid="SELFTEST-HW")
    assert payload["trueCleanMachine"] is True, payload
    assert payload["operator"] == "selftest", payload
    assert payload["host"]["hardwareUUID"] == "SELFTEST-HW", payload
    assert set(payload["assertions"]) == {key for key, _, _ in module.ASSERTION_FLAGS}, payload
    assert all(v is True for v in payload["assertions"].values()), payload
    assert payload["timestamp"].endswith("Z"), payload

    bad = good_args(module)
    setattr(bad, module.ASSERTION_FLAGS[0][0], False)
    try:
        module.build_payload(bad, host_hardware_uuid="SELFTEST-HW")
    except SystemExit as exc:
        assert module.ASSERTION_FLAGS[0][1] in str(exc), exc
    else:
        raise AssertionError("missing assertion flag was accepted")

    blank_operator = good_args(module)
    blank_operator.operator = " "
    try:
        module.build_payload(blank_operator, host_hardware_uuid="SELFTEST-HW")
    except SystemExit as exc:
        assert "--operator is required" in str(exc), exc
    else:
        raise AssertionError("blank operator was accepted")

    with tempfile.TemporaryDirectory(prefix="codexkit-clean-attestation-") as raw:
        out = Path(raw) / "attestation.json"
        args = good_args(module, output=out)
        encoded = module.build_payload(args, host_hardware_uuid="SELFTEST-HW")
        out.write_text(__import__("json").dumps(encoded, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        assert out.exists(), out

    print("clean_machine_attestation_selftest OK")


if __name__ == "__main__":
    main()
