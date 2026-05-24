#!/usr/bin/env python3
"""Spawned-worker poison containment gate.

Runs release `codexd` with CODEXKIT_SESSION_BIN pointing at a stable symlink.
The symlink starts at the real codex-session, then switches to a poison worker
that exits immediately. The poisoned session must not kill codexd or an already
loaded quiet session. After restoring the symlink, new sessions must work again.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import queue
import stat
import subprocess
import tempfile
import threading
import textwrap
import time
from pathlib import Path
from datetime import datetime, timezone


class Driver:
    def __init__(self, root: Path, session_bin: Path) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="codexkit-poison-worker-"))
        env = os.environ.copy()
        env["CODEX_HOME"] = str(self.work / "home")
        env["CODEXKIT_MOCK"] = "1"
        env["CODEXKIT_SESSION_BIN"] = str(session_bin)
        self.proc = subprocess.Popen(
            [str(root / ".build" / "release" / "codexd")],
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
        self.errors: queue.Queue[dict] = queue.Queue()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            msg = json.loads(line)
            if "id" in msg:
                self.responses[msg["id"]] = msg
            if msg.get("method") == "turn/completed":
                tid = msg.get("params", {}).get("threadId")
                if tid:
                    self.completed[tid] = self.completed.get(tid, 0) + 1
            if msg.get("method") == "error":
                self.errors.put(msg)

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
                return resp
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.02)
        raise TimeoutError(f"timeout waiting for {method}")

    def notify_initialized(self) -> None:
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
        raise TimeoutError(f"timeout waiting for completion on {thread_id}")

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


def write_wrapper(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def swap_symlink(link: Path, target: Path) -> None:
    tmp = link.with_name(link.name + ".next")
    try:
        tmp.unlink()
    except FileNotFoundError:
        pass
    tmp.symlink_to(target)
    tmp.replace(link)


def start_thread(driver: Driver, name: str) -> str:
    cwd = driver.work / name
    cwd.mkdir(parents=True, exist_ok=True)
    resp = driver.send("thread/start", {"cwd": str(cwd), "model": "mock"})
    if "error" in resp:
        raise AssertionError(resp)
    return resp["result"]["thread"]["id"]


def turn(driver: Driver, tid: str, text: str, timeout: float = 20) -> None:
    before = driver.completed.get(tid, 0)
    resp = driver.send(
        "turn/start",
        {"threadId": tid, "input": [{"type": "text", "text": text}]},
        timeout=timeout,
    )
    if "error" in resp:
        raise AssertionError(resp)
    driver.wait_completed(tid, before + 1, timeout=timeout)


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
    parser.add_argument("--evidence-file", type=Path)
    args = parser.parse_args()

    root = Path.cwd()
    real_session = root / ".build" / "release" / "codex-session"
    if not real_session.exists():
        raise SystemExit("missing .build/release/codex-session; run swift build -c release first")

    bin_root = Path(tempfile.mkdtemp(prefix="codexkit-poison-bin-"))
    real_wrapper = bin_root / "codex-session-real"
    poison = bin_root / "codex-session-poison"
    current = bin_root / "codex-session-current"
    write_wrapper(
        real_wrapper,
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            echo 'codex-session generation=healthy' >&2
            exec '{real_session}' "$@"
            """
        ),
    )
    write_wrapper(
        poison,
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            echo 'codex-session generation=poison exiting immediately' >&2
            exit 42
            """
        ),
    )
    current.symlink_to(real_wrapper)

    driver = Driver(root, current)
    try:
        init = driver.send("initialize", {"clientInfo": {"name": "poison-worker"}})
        assert "result" in init, init
        driver.notify_initialized()

        quiet = start_thread(driver, "quiet")
        turn(driver, quiet, "quiet first turn")

        swap_symlink(current, poison)
        poisoned = start_thread(driver, "poisoned")
        poison_resp = driver.send(
            "turn/start",
            {"threadId": poisoned, "input": [{"type": "text", "text": "this worker exits"}]},
            timeout=5,
        )
        poison_turn_errored = "error" in poison_resp
        poison_unexpected_completion = False
        if "error" not in poison_resp:
            # If the ack raced before the relay noticed process exit, require no
            # false successful completion from the poisoned session.
            try:
                driver.wait_completed(poisoned, 1, timeout=2)
            except TimeoutError:
                pass
            else:
                poison_unexpected_completion = True
                raise AssertionError("poisoned worker unexpectedly completed a turn")

        daemon_survived_poison = driver.proc.poll() is None
        assert daemon_survived_poison, "codexd died with poisoned worker"
        turn(driver, quiet, "quiet survives poison")

        swap_symlink(current, real_wrapper)
        recovered = start_thread(driver, "recovered")
        turn(driver, recovered, "new session after poison recovers")

        healthy_launches = sum("generation=healthy" in line for line in driver.stderr_lines)
        poison_launches = sum("generation=poison" in line for line in driver.stderr_lines)
        assert healthy_launches >= 2, driver.stderr_lines
        assert poison_launches == 1, driver.stderr_lines
        result = {
            "quietThread": quiet,
            "poisonedThread": poisoned,
            "recoveredThread": recovered,
            "quietCompletions": driver.completed.get(quiet, 0),
            "poisonedCompletions": driver.completed.get(poisoned, 0),
            "recoveredCompletions": driver.completed.get(recovered, 0),
            "healthyLaunches": healthy_launches,
            "poisonLaunches": poison_launches,
            "daemonPid": driver.proc.pid,
            "daemonSurvivedPoison": daemon_survived_poison,
            "poisonTurnErrored": poison_turn_errored,
        }
        print(json.dumps(result, sort_keys=True))
        if args.evidence_file:
            assertions = {
                "daemonSurvivedPoison": daemon_survived_poison,
                "quietSessionSurvivedPoison": driver.completed.get(quiet, 0) >= 2,
                "poisonWorkerLaunchedOnce": poison_launches == 1,
                "poisonedTurnDidNotComplete": driver.completed.get(poisoned, 0) == 0 and not poison_unexpected_completion,
                "healthyWorkerLaunchedBeforeAndAfterPoison": healthy_launches >= 2,
                "recoveredSessionCompleted": driver.completed.get(recovered, 0) >= 1,
                "threadsAreDistinct": len({quiet, poisoned, recovered}) == 3,
            }
            payload = {
                "gate": "g6_poison_worker",
                "result": "passed",
                "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "host": {
                    "uname": platform.platform(),
                    "sw_vers": sw_vers(),
                    "hardwareUUID": hardware_uuid(),
                },
                "paths": {
                    "codexHome": str(driver.work / "home"),
                    "realSession": str(real_session),
                    "realWrapper": str(real_wrapper),
                    "poisonWorker": str(poison),
                    "sessionSymlink": str(current),
                },
                "threads": {
                    "quiet": quiet,
                    "poisoned": poisoned,
                    "recovered": recovered,
                },
                "completions": {
                    "quiet": driver.completed.get(quiet, 0),
                    "poisoned": driver.completed.get(poisoned, 0),
                    "recovered": driver.completed.get(recovered, 0),
                },
                "launches": {
                    "healthy": healthy_launches,
                    "poison": poison_launches,
                },
                "daemon": {
                    "pid": driver.proc.pid,
                    "survivedPoison": daemon_survived_poison,
                },
                "poisonTurn": {
                    "errored": poison_turn_errored,
                    "unexpectedCompletion": poison_unexpected_completion,
                },
                "assertions": assertions,
            }
            args.evidence_file.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(f"evidence={args.evidence_file}")
    finally:
        driver.close()


if __name__ == "__main__":
    main()
