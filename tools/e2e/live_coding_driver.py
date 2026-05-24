#!/usr/bin/env python3
"""Drive release codexd through live multi-session coding workspaces.

This intentionally exercises the production executable and spawned
`codex-session` workers with the real OpenAI API. It verifies not just that the
model streamed text, but that live tool calls left independently testable code
in multiple session workspaces, including an iterative debug/fix turn and a
fresh `codexd` process resume from durable rollout state.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import collections
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any


Json = dict[str, Any]


class CodexRPC:
    def __init__(self, root: Path, home: Path) -> None:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(home)
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
        self.responses: dict[Any, Json] = {}
        self.messages: "queue.Queue[Json]" = queue.Queue()
        self.recent_messages: "collections.deque[Json]" = collections.deque(maxlen=80)
        self.stderr_lines: list[str] = []
        self.errors: list[str] = []
        self.tool_completions = 0
        self.tool_completions_by_thread: dict[str, int] = {}
        self.tool_invocations_by_name: dict[str, int] = {}
        self.tool_invocations_by_thread_name: dict[str, dict[str, int]] = {}
        self._send_lock = threading.Lock()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _write(self, obj: Json) -> None:
        with self._send_lock:
            assert self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(obj, separators=(",", ":")) + "\n")
            self.proc.stdin.flush()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            try:
                obj = json.loads(line)
            except Exception as exc:
                self.errors.append(f"invalid JSON from codexd: {line[:200]} ({exc})")
                continue
            if "id" in obj and "method" not in obj:
                self.responses[obj["id"]] = obj
            elif "id" in obj and obj.get("method", "").endswith("/requestApproval"):
                self._write({"id": obj["id"], "result": {"decision": "acceptForSession"}})
            if obj.get("method") == "item/completed":
                params = obj.get("params") or {}
                item = params.get("item") or {}
                if isinstance(item, dict) and item.get("type") == "commandExecution":
                    self.tool_completions += 1
                    command = item.get("command")
                    name = command[0] if isinstance(command, list) and command else "<unknown>"
                    self.tool_invocations_by_name[name] = self.tool_invocations_by_name.get(name, 0) + 1
                    tid = params.get("threadId")
                    if isinstance(tid, str) and tid:
                        self.tool_completions_by_thread[tid] = self.tool_completions_by_thread.get(tid, 0) + 1
                        by_name = self.tool_invocations_by_thread_name.setdefault(tid, {})
                        by_name[name] = by_name.get(name, 0) + 1
            self.messages.put(obj)
            self.recent_messages.append(obj)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip())

    def request(self, method: str, params: Json | None = None, timeout: float = 60) -> Json:
        rid = self.next_id
        self.next_id += 1
        payload: Json = {"id": rid, "method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)

        deadline = time.time() + timeout
        while time.time() < deadline:
            if rid in self.responses:
                resp = self.responses.pop(rid)
                if "error" in resp:
                    raise RuntimeError(f"{method} failed: {resp['error']}")
                return resp
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.02)
        raise TimeoutError(f"timeout waiting for {method} response id={rid}")

    def notify(self, method: str, params: Json | None = None) -> None:
        payload: Json = {"method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)

    def wait_turn_completed(self, thread_id: str, timeout: float) -> Json:
        deadline = time.time() + timeout
        last: Json | None = None
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            try:
                msg = self.messages.get(timeout=0.05)
            except queue.Empty:
                continue
            method = msg.get("method")
            params = msg.get("params") or {}
            if method == "turn/completed" and params.get("threadId") == thread_id:
                last = msg
                return msg
        recent = []
        for m in list(self.recent_messages)[-20:]:
            item = (m.get("params") or {}).get("item") or {}
            recent.append({
                "id": m.get("id"),
                "method": m.get("method"),
                "itemType": item.get("type") if isinstance(item, dict) else None,
                "status": item.get("status") if isinstance(item, dict) else None,
                "command": item.get("command") if isinstance(item, dict) else None,
                "output": (item.get("aggregatedOutput") or "")[:200] if isinstance(item, dict) else "",
                "hasResult": "result" in m,
                "hasError": "error" in m,
            })
        stderr = self.stderr_lines[-20:]
        raise TimeoutError(
            f"timeout waiting for live turn completion on {thread_id}; "
            f"last={last} recent={recent} stderr={stderr}"
        )

    def drain_thread_events(self, thread_id: str, seconds: float = 0.1) -> list[Json]:
        out: list[Json] = []
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                msg = self.messages.get(timeout=0.02)
            except queue.Empty:
                continue
            params = msg.get("params") or {}
            if params.get("threadId") == thread_id:
                out.append(msg)
        return out

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


def run_check(work: Path, command: str) -> str:
    cp = subprocess.run(
        command,
        cwd=work,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
    )
    if cp.returncode != 0:
        raise AssertionError(f"check failed in {work}: {command}\n{cp.stdout}")
    return cp.stdout


def run_check_result(work: Path, command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=work,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
    )


def turn_script(idx: int, tag: str, turn: int) -> str:
    if turn == 1:
        marker = f"{tag}_TURN1_OK"
        calc = (
            f'"def add(a, b):"+chr(10)+"    return a + b"+chr(10)+chr(10)'
            f'+"def sub(a, b):"+chr(10)+"    return a - b"+chr(10)'
        )
        test = (
            f'"from calc_{idx} import add, sub"+chr(10)'
            f'+"assert add(8, 5) == 13"+chr(10)'
            f'+"assert sub(8, 5) == 3"+chr(10)'
            f'+"print(\\"{marker}\\")"+chr(10)'
        )
        return (
            f"python3 -c 'open(\"calc_{idx}.py\",\"w\").write({calc}); "
            f"open(\"test_calc_{idx}.py\",\"w\").write({test})' "
            f"&& python3 test_calc_{idx}.py"
        )

    if turn == 2:
        marker = f"{tag}_TURN2_OK"
        calc = (
            f'"def add(a, b):"+chr(10)+"    return a + b"+chr(10)+chr(10)'
            f'+"def sub(a, b):"+chr(10)+"    return a - b"+chr(10)+chr(10)'
            f'+"def mul(a, b):"+chr(10)+"    return a * b"+chr(10)'
        )
        test = (
            f'"from calc_{idx} import add, sub, mul"+chr(10)'
            f'+"assert add(8, 5) == 13"+chr(10)'
            f'+"assert sub(8, 5) == 3"+chr(10)'
            f'+"assert mul(6, 7) == 42"+chr(10)'
            f'+"print(\\"{marker}\\")"+chr(10)'
        )
        return (
            f"python3 -c 'open(\"calc_{idx}.py\",\"w\").write({calc}); "
            f"open(\"test_calc_{idx}.py\",\"w\").write({test})' "
            f"&& python3 test_calc_{idx}.py"
        )

    marker = f"{tag}_TURN3_OK"
    trace = f"debug_trace_{idx}.json"
    debug = (
        f'import json, pathlib, subprocess, sys; '
        f'p=pathlib.Path("calc_{idx}.py"); '
        f't=p.read_text(); '
        f'p.write_text(t+chr(10)+chr(10)+"def div(a, b):"+chr(10)+"    return a // b"+chr(10)); '
        f'bad=pathlib.Path("test_bug_{idx}.py"); '
        f'bad.write_text("from calc_{idx} import div"+chr(10)+"assert div(7, 2) == 3.5"+chr(10)); '
        f'r=subprocess.run([sys.executable, str(bad)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT); '
        f'assert r.returncode != 0, r.stdout; '
        f'p.write_text(p.read_text().replace("return a // b", "return a / b")); '
        f'good=pathlib.Path("test_calc_{idx}.py"); '
        f'good.write_text("from calc_{idx} import add, sub, mul, div"+chr(10)'
        f'+"assert add(8, 5) == 13"+chr(10)'
        f'+"assert sub(8, 5) == 3"+chr(10)'
        f'+"assert mul(6, 7) == 42"+chr(10)'
        f'+"assert div(7, 2) == 3.5"+chr(10)'
        f'+"print(\\\"{marker}\\\")"+chr(10)); '
        f'after=subprocess.run([sys.executable, str(good)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT); '
        f'pathlib.Path("{trace}").write_text(json.dumps({{"bugReturncode": r.returncode, "fixedReturncode": after.returncode, "marker": "{marker}"}}, sort_keys=True)+chr(10)); '
        f'sys.stdout.write(after.stdout); '
        f'assert after.returncode == 0, after.stdout'
    )
    return f"python3 -c '{debug}'"


def expected_marker(tag: str, turn: int) -> str:
    return f"{tag}_TURN{min(turn, 3)}_OK"


def code_mode_source(shell_command: str) -> str:
    """Return JavaScriptCore source that executes exactly one nested shell call."""
    return (
        'return callTool("shell", '
        + json.dumps({"command": shell_command, "timeoutMs": 60_000}, sort_keys=True)
        + ");"
    )


def verify_rollout(home: Path, thread_id: str, expected_user_turns: int) -> int:
    rollout = home / "sessions" / f"{thread_id}.rollout.jsonl"
    if not rollout.exists():
        raise AssertionError(f"missing rollout for {thread_id}: {rollout}")
    completed = 0
    users = 0
    with rollout.open("rb") as fh:
        for raw in fh:
            if not raw.endswith(b"\n"):
                raise AssertionError(f"partial trailing rollout line for {thread_id}")
            rec = json.loads(raw)
            if rec.get("t") == "turnBoundary" and rec.get("status") == "completed":
                completed += 1
            if rec.get("t") == "userInput":
                users += 1
    if completed < expected_user_turns:
        raise AssertionError(f"thread {thread_id} completed={completed}, expected>={expected_user_turns}")
    if users < expected_user_turns:
        raise AssertionError(f"thread {thread_id} userInput={users}, expected>={expected_user_turns}")
    return completed


def verify_debug_trace(work: Path, idx: int, marker: str) -> Json:
    trace_path = work / f"debug_trace_{idx}.json"
    if not trace_path.exists():
        raise AssertionError(f"missing debug/fix trace: {trace_path}")
    payload = json.loads(trace_path.read_text(encoding="utf-8"))
    if payload.get("bugReturncode") == 0:
        raise AssertionError(f"debug/fix trace did not observe failing regression: {payload}")
    if payload.get("fixedReturncode") != 0:
        raise AssertionError(f"debug/fix trace did not observe repaired test pass: {payload}")
    if payload.get("marker") != marker:
        raise AssertionError(f"debug/fix trace marker mismatch: {payload}, expected={marker}")
    bug_after_fix = run_check_result(work, f"python3 test_bug_{idx}.py")
    if bug_after_fix.returncode != 0:
        raise AssertionError(
            f"debug regression test does not pass after repair in {work}: {bug_after_fix.stdout}"
        )
    return payload


def run(args: argparse.Namespace) -> None:
    root = Path(args.root)
    home = Path(tempfile.mkdtemp(prefix="codexkit-live-coding-home-"))
    work_root = Path(tempfile.mkdtemp(prefix="codexkit-live-coding-work-"))
    rpc = CodexRPC(root, home)
    try:
        rpc.request(
            "initialize",
            {
                "clientInfo": {"name": "live-coding-driver"},
                "capabilities": {"experimentalApi": True},
            },
            timeout=30,
        )
        rpc.notify("initialized")
        sessions: list[dict[str, Any]] = []
        for idx in range(args.sessions):
            work = work_root / f"workspace-{idx}"
            work.mkdir(parents=True, exist_ok=True)
            tag = f"LIVE_SESSION_{idx}_{int(time.time() * 1000) % 1_000_000}"
            (work / "seed.txt").write_text(tag + "\n", encoding="utf-8")
            resp = rpc.request(
                "thread/start",
                {
                    "cwd": str(work),
                    "model": args.model,
                    "developerInstructions": (
                        "You are in a release-binary live coding verification. "
                        "When the user provides exact JavaScriptCore code-mode source, "
                        "call the code tool exactly once with that source and timeoutMs=60000. "
                        "The source will call the shell tool through callTool; do not paste "
                        "the shell command directly into the code tool."
                    ),
                },
                timeout=45,
            )
            sessions.append({"idx": idx, "tag": tag, "work": work, "threadId": resp["result"]["thread"]["id"]})

        turn_completions: dict[str, int] = {s["threadId"]: 0 for s in sessions}
        turn_attempts: dict[str, int] = {s["threadId"]: 0 for s in sessions}
        correction_turns: dict[str, int] = {s["threadId"]: 0 for s in sessions}
        for turn in range(1, args.turns + 1):
            for session in sessions:
                script = turn_script(session["idx"], session["tag"], min(turn, 3))
                js_source = code_mode_source(script)
                tid = session["threadId"]
                expected = expected_marker(session["tag"], turn)
                last_error = ""
                for attempt in range(1, args.max_attempts + 1):
                    turn_attempts[tid] += 1
                    if attempt == 1:
                        prompt = (
                            "Use exactly one code tool call for this live coding session. "
                            "Set timeoutMs to 60000 and use this exact JavaScript source:\n"
                            + js_source
                            + "\nDo not run the shell command as JavaScript. The JavaScript "
                            "source above calls the shell tool through callTool. "
                            "After the tool returns, give a concise final answer."
                        )
                    else:
                        correction_turns[tid] += 1
                        prompt = (
                            "The previous live turn did not leave the required verified "
                            f"workspace marker {expected}. You must now call the code tool "
                            "exactly once with timeoutMs=60000 and this exact JavaScript source:\n"
                            + js_source
                            + "\nDo not paste a python3 command into the code tool as JavaScript; "
                            "use the JavaScript source above so code-mode calls shell through "
                            "callTool. After it succeeds, give a concise final answer."
                        )
                    rpc.request(
                        "turn/start",
                        {"threadId": tid, "input": [{"type": "text", "text": prompt}]},
                        timeout=45,
                    )
                    rpc.wait_turn_completed(tid, timeout=args.turn_timeout)
                    turn_completions[tid] += 1
                    rpc.drain_thread_events(tid)
                    check = run_check_result(session["work"], f"python3 test_calc_{session['idx']}.py")
                    if check.returncode == 0 and expected in check.stdout:
                        break
                    last_error = check.stdout
                else:
                    recent = list(rpc.recent_messages)[-20:]
                    raise AssertionError(
                        f"missing live coding marker {expected} after {args.max_attempts} attempts; "
                        f"last_check={last_error!r}; recent={recent}"
                    )

        total_tool_completions = rpc.tool_completions
        tool_completions_by_thread = dict(rpc.tool_completions_by_thread)
        tool_invocations_by_name = dict(rpc.tool_invocations_by_name)
        tool_invocations_by_thread_name = {
            tid: dict(counts) for tid, counts in rpc.tool_invocations_by_thread_name.items()
        }
        rpc.close()
        rpc = CodexRPC(root, home)
        rpc.request(
            "initialize",
            {
                "clientInfo": {"name": "live-coding-driver-resume"},
                "capabilities": {"experimentalApi": True},
            },
            timeout=30,
        )
        rpc.notify("initialized")

        for session in sessions:
            tid = session["threadId"]
            resumed = rpc.request("thread/resume", {"threadId": tid}, timeout=45)
            if resumed.get("result", {}).get("thread", {}).get("id") != tid:
                raise AssertionError(f"thread/resume returned wrong thread for {tid}: {resumed}")
            rpc.request("thread/read", {"threadId": tid}, timeout=30)
            turns = rpc.request("thread/turns/list", {"threadId": tid}, timeout=30)
            data = turns.get("result", {}).get("data", [])
            if len(data) < args.turns:
                raise AssertionError(f"thread/turns/list too short for {tid}: {len(data)}")
            completed = verify_rollout(home, tid, args.turns)
            final = run_check(session["work"], "test -f seed.txt && cat seed.txt && find . -maxdepth 1 -type f | sort")
            if session["tag"] not in final:
                raise AssertionError(f"seed marker missing from isolated workspace: {final}")
            latest = run_check(session["work"], f"python3 test_calc_{session['idx']}.py")
            if expected_marker(session["tag"], args.turns) not in latest:
                raise AssertionError(f"latest live coding marker missing after resume for {tid}: {latest}")
            debug_trace = verify_debug_trace(
                session["work"], session["idx"], expected_marker(session["tag"], min(args.turns, 3))
            )
            session["rolloutCompletedTurns"] = completed
            session["turnAttempts"] = turn_attempts[tid]
            session["correctionTurns"] = correction_turns[tid]
            session["debugRepairVerified"] = True
            session["debugTrace"] = debug_trace

        total_tool_completions += rpc.tool_completions
        for tid, count in rpc.tool_completions_by_thread.items():
            tool_completions_by_thread[tid] = tool_completions_by_thread.get(tid, 0) + count
        for name, count in rpc.tool_invocations_by_name.items():
            tool_invocations_by_name[name] = tool_invocations_by_name.get(name, 0) + count
        for tid, counts in rpc.tool_invocations_by_thread_name.items():
            merged = tool_invocations_by_thread_name.setdefault(tid, {})
            for name, count in counts.items():
                merged[name] = merged.get(name, 0) + count
        expected_tool_completions = args.sessions * args.turns
        if total_tool_completions < expected_tool_completions:
            raise AssertionError(
                f"expected at least {expected_tool_completions} live tool completions, "
                f"saw {total_tool_completions}"
            )
        for session in sessions:
            tid = session["threadId"]
            per_session_tools = tool_completions_by_thread.get(tid, 0)
            if per_session_tools < args.turns:
                raise AssertionError(
                    f"live session {tid} observed too few tool completions: "
                    f"{per_session_tools} expected>={args.turns}"
                )
            per_session_names = tool_invocations_by_thread_name.get(tid, {})
            code_mode_calls = per_session_names.get("code", 0)
            if code_mode_calls < args.turns:
                raise AssertionError(
                    f"live session {tid} observed too few code-mode tool completions: "
                    f"{code_mode_calls} expected>={args.turns}; names={per_session_names}"
                )
        if not any("codexd workerMode=spawned" in line for line in rpc.stderr_lines):
            raise AssertionError("release codexd did not use spawned worker mode")
        if not any("codex-session worker ready" in line for line in rpc.stderr_lines):
            raise AssertionError("spawned codex-session worker did not start")

        payload = {
            "sessions": [
                {
                    "threadId": s["threadId"],
                    "workspace": str(s["work"]),
                    "tag": s["tag"],
                    "rolloutCompletedTurns": s["rolloutCompletedTurns"],
                    "toolCompletionEventsObserved": tool_completions_by_thread.get(s["threadId"], 0),
                    "toolInvocationKindsObserved": tool_invocations_by_thread_name.get(s["threadId"], {}),
                    "turnAttempts": s["turnAttempts"],
                    "correctionTurns": s["correctionTurns"],
                    "debugRepairVerified": s["debugRepairVerified"],
                    "debugTrace": s["debugTrace"],
                    "resumedAfterCodexdRestart": True,
                }
                for s in sessions
            ],
            "turnsPerSession": args.turns,
            "maxAttemptsPerTurn": args.max_attempts,
            "correctionTurnsObserved": sum(s["correctionTurns"] for s in sessions),
            "toolCompletionEventsObserved": total_tool_completions,
            "toolInvocationKindsObserved": tool_invocations_by_name,
            "codexHome": str(home),
            "freshCodexdResumeVerified": True,
            "debugRepairVerified": True,
        }
        encoded = json.dumps(payload, sort_keys=True)
        print(encoded)
        if args.evidence_file:
            Path(args.evidence_file).write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    finally:
        rpc.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(Path.cwd()))
    parser.add_argument("--sessions", type=int, default=2)
    parser.add_argument("--turns", type=int, default=3)
    parser.add_argument("--model", default="gpt-4o-mini")
    parser.add_argument("--turn-timeout", type=int, default=240)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--evidence-file")
    args = parser.parse_args()

    if not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("OPENAI_API_KEY is required for live coding driver")
    if args.sessions < 2:
        raise SystemExit("--sessions must be at least 2")
    if args.turns < 3:
        raise SystemExit("--turns must be at least 3 for the iterative debug/fix turn")
    if args.max_attempts < 1:
        raise SystemExit("--max-attempts must be at least 1")
    run(args)


if __name__ == "__main__":
    main()
