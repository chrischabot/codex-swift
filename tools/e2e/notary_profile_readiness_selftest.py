#!/usr/bin/env python3
"""Self-test notary profile readiness helper with a mocked xcrun."""

from __future__ import annotations

import importlib.util
import os
import stat
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "e2e" / "notary_profile_readiness.py"


def load_module():
    spec = importlib.util.spec_from_file_location("notary_profile_readiness", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_xcrun(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def main() -> None:
    module = load_module()
    old_path = os.environ.get("PATH", "")
    with tempfile.TemporaryDirectory(prefix="codexkit-notary-profile-") as raw:
        temp = Path(raw)
        xcrun = temp / "xcrun"
        os.environ["PATH"] = f"{temp}:{old_path}"

        write_xcrun(
            xcrun,
            'printf \'{"history":[{"id":"abc"}]}\\n\'\n',
        )
        ok = module.validate_profile("selftest-profile", timeout=5)
        assert ok["authenticated"] is True, ok
        assert ok["historyCount"] == 1, ok

        write_xcrun(
            xcrun,
            'echo "invalid profile" >&2\nexit 2\n',
        )
        try:
            module.validate_profile("bad-profile", timeout=5)
        except SystemExit as exc:
            assert "notary profile validation failed" in str(exc), exc
            assert "invalid profile" in str(exc), exc
        else:
            raise AssertionError("failed notarytool command was accepted")

        write_xcrun(
            xcrun,
            "printf 'not-json\\n'\n",
        )
        try:
            module.validate_profile("bad-json", timeout=5)
        except SystemExit as exc:
            assert "did not return JSON" in str(exc), exc
        else:
            raise AssertionError("non-JSON notarytool output was accepted")

    os.environ["PATH"] = old_path
    print("notary_profile_readiness_selftest OK")


if __name__ == "__main__":
    main()
