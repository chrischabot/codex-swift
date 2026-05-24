#!/usr/bin/env python3
"""Prove quiet spawned workers survive a blue/green codex-session swap.

The test starts release `codexd` with CODEXKIT_SESSION_BIN pointing at a stable
symlink. The symlink initially targets a "blue" wrapper around the real
codex-session. After one quiet loaded session has completed a turn, the symlink
is atomically switched to a "green" wrapper. The loaded session must still
complete another turn, while a newly spawned session must launch through green.
"""

from __future__ import annotations

import json
import os
import stat
import argparse
import platform
import subprocess
import tempfile
import threading
import textwrap
import time
from datetime import datetime, timezone
from pathlib import Path


class Driver:
    def __init__(self, codexd_bin: Path, session_bin: Path) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="codexkit-bluegreen-"))
        env = os.environ.copy()
        env["CODEX_HOME"] = str(self.work / "home")
        env["CODEXKIT_MOCK"] = "1"
        env["CODEXKIT_SESSION_BIN"] = str(session_bin)
        self.proc = subprocess.Popen(
            [str(codexd_bin)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self.next_id = 1
        self.responses: dict[int, dict] = {}
        self.completed: dict[str, int] = {}
        self.stderr_lines: list[str] = []
        self.stdout_lines: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.stdout_lines.append(line.rstrip())
            obj = json.loads(line)
            if "id" in obj:
                self.responses[obj["id"]] = obj
            if obj.get("method") == "turn/completed":
                tid = obj.get("params", {}).get("threadId")
                if tid:
                    self.completed[tid] = self.completed.get(tid, 0) + 1

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip())

    def send(self, method: str, params: dict | None = None, timeout: float = 20) -> dict:
        rid = self.next_id
        self.next_id += 1
        msg: dict = {"id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(msg, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            if rid in self.responses:
                resp = self.responses.pop(rid)
                if "error" in resp:
                    raise RuntimeError(f"{method} returned error: {resp['error']}")
                return resp
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.02)
        raise TimeoutError(f"timeout waiting for {method} response")

    def initialized(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps({"method": "initialized"}, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def wait_completed(self, thread_id: str, target: int, timeout: float = 20) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.completed.get(thread_id, 0) >= target:
                return
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.02)
        raise TimeoutError(
            f"timeout waiting for completion {target} on {thread_id}; "
            f"have {self.completed.get(thread_id, 0)}"
        )

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=10)


def make_wrapper(path: Path, generation: str, real_session: Path) -> None:
    path.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            echo 'codex-session generation={generation}' >&2
            exec '{real_session}' "$@"
            """
        )
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def marker_count(lines: list[str], generation: str) -> int:
    return sum(1 for line in lines if f"codex-session generation={generation}" in line)


def start_thread(driver: Driver, cwd: Path) -> str:
    cwd.mkdir(parents=True, exist_ok=True)
    resp = driver.send(
        "thread/start",
        {"cwd": str(cwd), "model": "mock", "developerInstructions": "blue/green swap test"},
    )
    return resp["result"]["thread"]["id"]


def turn(driver: Driver, thread_id: str, text: str) -> None:
    before = driver.completed.get(thread_id, 0)
    driver.send("turn/start", {"threadId": thread_id, "input": [{"type": "text", "text": text}]})
    driver.wait_completed(thread_id, before + 1)


def promote_worker(root: Path, release: str) -> None:
    subprocess.check_call(
        [
            "scripts/codexkit-lifecycle.sh",
            "promote-worker",
            "--install-root",
            str(root),
            "--release",
            release,
        ]
    )


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


def sw_vers() -> dict[str, str]:
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codexd-bin", default=".build/release/codexd")
    parser.add_argument("--real-session", default=".build/release/codex-session")
    parser.add_argument("--install-root")
    parser.add_argument("--evidence-file", type=Path)
    args = parser.parse_args()

    codexd_bin = Path(args.codexd_bin).resolve()
    real_session = Path(args.real_session).resolve()
    if not real_session.exists():
        raise SystemExit("missing .build/release/codex-session; run swift build -c release first")

    if args.install_root:
        install_root = Path(args.install_root).resolve()
        current = install_root / "bin" / "codex-session"
        codexd_bin = install_root / "bin" / "codexd"
        promote_worker(install_root, "blue")
    else:
        work = Path(tempfile.mkdtemp(prefix="codexkit-bluegreen-bin-"))
        blue = work / "codex-session-blue"
        green = work / "codex-session-green"
        current = work / "codex-session-current"
        make_wrapper(blue, "blue", real_session)
        make_wrapper(green, "green", real_session)
        current.symlink_to(blue)

    driver = Driver(codexd_bin=codexd_bin, session_bin=current)
    try:
        driver.send("initialize", {"clientInfo": {"name": "blue-green"}})
        driver.initialized()

        blue_thread = start_thread(driver, driver.work / "blue-workspace")
        turn(driver, blue_thread, "First quiet blue turn.")
        if marker_count(driver.stderr_lines, "blue") != 1:
            raise AssertionError(f"expected exactly one blue worker launch, stderr={driver.stderr_lines}")
        if marker_count(driver.stderr_lines, "green") != 0:
            raise AssertionError(f"green launched before swap, stderr={driver.stderr_lines}")

        if args.install_root:
            promote_worker(Path(args.install_root).resolve(), "green")
        else:
            tmp = current.parent / "codex-session-next"
            tmp.symlink_to(green)
            tmp.replace(current)

        # The already-loaded quiet session must continue on the blue worker; no
        # new green launch should be needed for this turn.
        turn(driver, blue_thread, "Second turn after symlink swap; existing worker should survive.")
        if marker_count(driver.stderr_lines, "blue") != 1:
            raise AssertionError("loaded blue session was unexpectedly respawned")
        if marker_count(driver.stderr_lines, "green") != 0:
            raise AssertionError("green launched while reusing already-loaded blue session")

        green_thread = start_thread(driver, driver.work / "green-workspace")
        turn(driver, green_thread, "New session after swap should use green worker.")
        if marker_count(driver.stderr_lines, "green") != 1:
            raise AssertionError(f"expected exactly one green worker launch, stderr={driver.stderr_lines}")

        # The original session should still be healthy after green is live.
        turn(driver, blue_thread, "Final blue session health check after green launch.")

        if args.install_root:
            promote_worker(Path(args.install_root).resolve(), "blue")
            rollback_thread = start_thread(driver, driver.work / "rollback-workspace")
            turn(driver, rollback_thread, "New session after rollback should use blue worker.")
            if marker_count(driver.stderr_lines, "blue") != 2:
                raise AssertionError(
                    f"expected blue worker launch after rollback, stderr={driver.stderr_lines}"
                )
        else:
            rollback_thread = None

        blue_launches = marker_count(driver.stderr_lines, "blue")
        green_launches = marker_count(driver.stderr_lines, "green")
        rollback_completions = driver.completed.get(rollback_thread, 0) if rollback_thread else 0
        result = {
            "blueThread": blue_thread,
            "greenThread": green_thread,
            "rollbackThread": rollback_thread,
            "blueLaunches": blue_launches,
            "greenLaunches": green_launches,
            "blueCompletions": driver.completed.get(blue_thread, 0),
            "greenCompletions": driver.completed.get(green_thread, 0),
            "rollbackCompletions": rollback_completions,
        }
        print(json.dumps(result, sort_keys=True))
        if args.evidence_file:
            threads = {
                "blue": blue_thread,
                "green": green_thread,
                "rollback": rollback_thread,
            }
            completions = {
                "blue": driver.completed.get(blue_thread, 0),
                "green": driver.completed.get(green_thread, 0),
                "rollback": rollback_completions,
            }
            assertions = {
                "loadedBlueSessionSurvivedPromotion": completions["blue"] >= 3,
                "greenSessionUsedAfterPromotion": green_launches == 1 and completions["green"] >= 1,
                "rollbackSessionUsedBlue": bool(rollback_thread) and blue_launches == 2 and rollback_completions >= 1,
                "noExtraBlueRespawnDuringPromotion": blue_launches == 2 if rollback_thread else blue_launches == 1,
                "threadsAreDistinct": len({tid for tid in threads.values() if tid}) == len([tid for tid in threads.values() if tid]),
                "daemonSurvivedPromotionAndRollback": driver.proc.poll() is None,
            }
            payload = {
                "gate": "g6_blue_green",
                "result": "passed",
                "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "host": {
                    "uname": platform.platform(),
                    "sw_vers": sw_vers(),
                    "hardwareUUID": hardware_uuid(),
                },
                "paths": {
                    "codexd": str(codexd_bin),
                    "sessionSymlink": str(current),
                    "installRoot": str(Path(args.install_root).resolve()) if args.install_root else None,
                    "codexHome": str(driver.work / "home"),
                },
                "threads": threads,
                "completions": completions,
                "launches": {
                    "blue": blue_launches,
                    "green": green_launches,
                },
                "daemon": {
                    "pid": driver.proc.pid,
                    "survivedPromotionAndRollback": driver.proc.poll() is None,
                },
                "assertions": assertions,
            }
            args.evidence_file.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(f"evidence={args.evidence_file}")
    finally:
        if driver.proc.poll() not in (None, 0):
            print("codexd stderr:", "\n".join(driver.stderr_lines[-40:]))
            print("codexd stdout:", "\n".join(driver.stdout_lines[-40:]))
        driver.close()


if __name__ == "__main__":
    main()
