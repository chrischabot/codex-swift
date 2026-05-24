#!/usr/bin/env python3
"""Drive codexd through noisy multi-session soak turns.

The driver intentionally talks to the release `codexd` binary over stdio so it
exercises the same spawned-worker path as production. It is configurable enough
for a short local gate or a 24-hour release soak.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import socket
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * p)))
    return ordered[idx]


def process_metrics(pid: int) -> dict[str, int]:
    rss_kb = 0
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()
        rss_kb = int(out or "0")
    except Exception:
        pass

    fd_count = 0
    try:
        out = subprocess.check_output(
            ["lsof", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL
        )
        fd_count = max(0, len(out.splitlines()) - 1)
    except Exception:
        pass

    workers = 0
    try:
        out = subprocess.check_output(["ps", "-axo", "ppid=,comm="], text=True)
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0] == str(pid) and parts[1].endswith("/codex-session"):
                workers += 1
    except Exception:
        pass

    return {"rss_kb": rss_kb, "fd_count": fd_count, "workers": workers}


def summarize_resource_trend(
    samples: list[dict],
    *,
    sessions: int,
    fd_growth_limit: int,
    rss_growth_limit_kb: int,
) -> dict:
    if not samples:
        raise AssertionError("resource trend has no samples")
    first = samples[0]["metrics"]
    fd_values = [sample["metrics"].get("fd_count", 0) for sample in samples]
    rss_values = [sample["metrics"].get("rss_kb", 0) for sample in samples]
    worker_values = [sample["metrics"].get("workers", 0) for sample in samples]
    fd_baseline = first.get("fd_count", 0)
    rss_baseline = first.get("rss_kb", 0)
    max_fd_growth = max(fd_values) - fd_baseline if fd_baseline else 0
    max_rss_growth_kb = max(rss_values) - rss_baseline if rss_baseline else 0
    max_workers = max(worker_values)
    summary = {
        "sampleCount": len(samples),
        "fdGrowthLimit": fd_growth_limit,
        "rssGrowthLimitKiB": rss_growth_limit_kb,
        "workerLimit": sessions,
        "start": first,
        "end": samples[-1]["metrics"],
        "max": {
            "fd_count": max(fd_values),
            "rss_kb": max(rss_values),
            "workers": max_workers,
        },
        "growth": {
            "fd_count": max_fd_growth,
            "rss_kb": max_rss_growth_kb,
        },
        "assertions": {
            "sampledMultipleTimes": len(samples) >= 3,
            "fdTrendFlat": max_fd_growth <= fd_growth_limit,
            "rssTrendFlat": max_rss_growth_kb <= rss_growth_limit_kb,
            "workerCountBounded": max_workers <= sessions,
        },
    }
    assertions = summary["assertions"]
    if not assertions["sampledMultipleTimes"]:
        raise AssertionError(f"resource trend did not sample enough points: {summary}")
    if not assertions["fdTrendFlat"]:
        raise AssertionError(f"fd trend exceeded limit: {summary}")
    if not assertions["rssTrendFlat"]:
        raise AssertionError(f"RSS trend exceeded limit: {summary}")
    if not assertions["workerCountBounded"]:
        raise AssertionError(f"worker trend exceeded session count: {summary}")
    return summary


def probe_durable_thread(home: Path, thread_id: str) -> dict[str, float | int | str]:
    """Verify a completed turn is durable in both SQLite and rollout JSONL.

    `SessionEngine.finishTurn` must fsync the rollout and advance SQLite before
    `turn/completed` is emitted. The soak driver checks that contract from the
    client side instead of trusting in-process counters.
    """
    t0 = time.time()
    db_path = home / "state.sqlite3"
    rollout_path = home / "sessions" / f"{thread_id}.rollout.jsonl"
    if not db_path.exists():
        raise AssertionError(f"state database missing after completed turn: {db_path}")
    if not rollout_path.exists():
        raise AssertionError(f"rollout missing after completed turn: {rollout_path}")

    with sqlite3.connect(str(db_path), timeout=5) as db:
        row = db.execute(
            "SELECT last_committed_seq, rollout_path FROM threads WHERE id=?",
            (thread_id,),
        ).fetchone()
    if row is None:
        raise AssertionError(f"thread {thread_id} missing from state database")
    committed_seq, db_rollout_path = int(row[0]), str(row[1])
    if Path(db_rollout_path) != rollout_path:
        raise AssertionError(
            f"state database rollout path drift for {thread_id}: "
            f"db={db_rollout_path} expected={rollout_path}"
        )

    line_count = 0
    completed_boundaries = 0
    trailing_partial = False
    with rollout_path.open("rb") as fh:
        for raw in fh:
            if not raw.endswith(b"\n"):
                trailing_partial = True
                continue
            line_count += 1
            try:
                rec = json.loads(raw)
            except Exception as exc:
                raise AssertionError(f"invalid rollout JSON for {thread_id}: {exc}") from exc
            if rec.get("t") == "turnBoundary" and rec.get("status") == "completed":
                completed_boundaries += 1

    if trailing_partial:
        raise AssertionError(f"rollout has trailing partial record after completed turn: {rollout_path}")
    if committed_seq != line_count:
        raise AssertionError(
            f"rollout/SQLite flush drift for {thread_id}: "
            f"last_committed_seq={committed_seq} lines={line_count}"
        )
    if completed_boundaries < 1:
        raise AssertionError(f"no completed turn boundary found in durable rollout for {thread_id}")

    return {
        "threadId": thread_id,
        "seconds": time.time() - t0,
        "records": line_count,
        "completedBoundaries": completed_boundaries,
    }


def write_mcp_churn_fixture(home: Path) -> None:
    home.mkdir(parents=True, exist_ok=True)
    server = home / "soak_mcp_server.py"
    server.write_text(
        r'''#!/usr/bin/env python3
import json
import sys

def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    mid = msg.get("id")
    meth = msg.get("method")
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "soak-mcp", "version": "1"},
        }})
    elif meth == "notifications/initialized":
        continue
    elif meth == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "ping",
            "description": "Return a deterministic soak pong.",
            "inputSchema": {"type": "object", "additionalProperties": True},
        }]}})
    elif meth == "tools/call":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": "soak-pong"}],
            "isError": False,
        }})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown"}})
''',
        encoding="utf-8",
    )
    server.chmod(0o755)
    (home / "mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "soak": {
                        "command": "python3",
                        "args": ["-u", str(server)],
                    }
                }
            },
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )


def run_slow_client_probe(root: Path, *, slow_clients: int, hold_seconds: float) -> dict[str, int | str]:
    work = Path(tempfile.mkdtemp(prefix="codexkit-slow-client-"))
    env = os.environ.copy()
    env["CODEX_HOME"] = str(work / "home")
    env["CODEXKIT_MOCK"] = "1"
    proc = subprocess.Popen(
        [str(root / ".build" / "release" / "codexd"), "--listen", "ws://127.0.0.1:0"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    assert proc.stderr is not None
    port: int | None = None
    stderr_lines: list[str] = []
    deadline = time.time() + 15
    while time.time() < deadline:
        line = proc.stderr.readline()
        if line:
            stderr_lines.append(line.rstrip())
            marker = "codexd listening ws://127.0.0.1:"
            if marker in line:
                port = int(line.rsplit(":", 1)[1].strip())
                break
        if proc.poll() is not None:
            raise RuntimeError(f"slow-client probe codexd exited early: {proc.returncode}")
    if port is None:
        proc.kill()
        proc.wait(timeout=5)
        raise TimeoutError(f"slow-client probe did not expose a port; stderr={stderr_lines[-5:]}")

    slow_sockets: list[socket.socket] = []
    try:
        for _ in range(slow_clients):
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            s.sendall(b"GET /ws HTTP/1.1\r\nHost: slow-client\r\n")
            slow_sockets.append(s)

        time.sleep(hold_seconds)

        healthy = socket.create_connection(("127.0.0.1", port), timeout=5)
        try:
            healthy.settimeout(10)
            request = {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "slow-client-probe",
                        "title": "Slow Client Probe",
                        "version": "1",
                    }
                },
            }
            healthy.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
            line = b""
            while not line.endswith(b"\n"):
                chunk = healthy.recv(4096)
                if not chunk:
                    break
                line += chunk
            response = json.loads(line.decode("utf-8"))
            if "error" in response:
                raise AssertionError(f"healthy client initialize failed under slow-client pressure: {response}")
            result = response.get("result") or {}
            for key in ["codexHome", "platformFamily", "platformOs", "userAgent"]:
                if key not in result:
                    raise AssertionError(f"healthy initialize missing {key}: {response}")
        finally:
            healthy.close()

        return {"slowClients": slow_clients, "port": port}
    finally:
        for s in slow_sockets:
            try:
                s.close()
            except Exception:
                pass
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def wait_for_unix_socket(path: Path, timeout: float = 10) -> None:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        if path.exists():
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    sock.settimeout(1)
                    sock.connect(str(path))
                    return
                finally:
                    sock.close()
            except Exception as exc:
                last_error = exc
        time.sleep(0.05)
    raise TimeoutError(f"broker Unix socket did not become ready: {path} last_error={last_error}")


def send_broker_jsonl(socket_path: Path, requests: list[dict], timeout: float = 20) -> list[dict]:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(str(socket_path))
        payload = b"".join(
            json.dumps(request, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
            for request in requests
        )
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()
    responses: list[dict] = []
    for raw in b"".join(chunks).splitlines():
        if raw.strip():
            responses.append(json.loads(raw.decode("utf-8")))
    return responses


def run_broker_stats_probe(root: Path, *, storm_requests: int, delay_ms: int) -> dict:
    broker = root / ".build" / "release" / "codex-broker"
    if not broker.is_file():
        raise AssertionError(f"codex-broker release binary missing: {broker}")
    work = Path(tempfile.mkdtemp(prefix="codexkit-broker-stats-"))
    socket_path = work / "broker.sock"
    env = os.environ.copy()
    env["CODEX_BROKER_AUTH_STORE"] = str(work / "broker-auth.json")
    proc = subprocess.Popen(
        [str(broker), "--listen", f"unix://{socket_path}"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    try:
        wait_for_unix_socket(socket_path)
        requests = [
            {
                "id": i,
                "method": "auth/refresh",
                "params": {
                    "account": "soak",
                    "token": "soak-token",
                    "delayMs": delay_ms,
                },
            }
            for i in range(1, storm_requests + 1)
        ]
        responses = send_broker_jsonl(socket_path, requests)
        if len(responses) != storm_requests:
            raise AssertionError(f"broker refresh storm response count mismatch: {len(responses)} != {storm_requests}")
        bad = [response for response in responses if response.get("ok") is not True]
        if bad:
            raise AssertionError(f"broker refresh storm returned errors: {bad[:3]}")
        if any((response.get("result") or {}).get("accessToken") != "soak-token" for response in responses):
            raise AssertionError(f"broker refresh storm returned unexpected tokens: {responses[:3]}")

        stats_responses = send_broker_jsonl(socket_path, [{"id": storm_requests + 1, "method": "broker/stats"}])
        stats = (stats_responses[0].get("result") if stats_responses else None) or {}
        expected_coalesced = storm_requests - 1
        if stats.get("authRefreshes") != 1:
            raise AssertionError(f"broker stats did not prove single upstream refresh: {stats}")
        if stats.get("authCoalesced", 0) < expected_coalesced:
            raise AssertionError(f"broker stats did not prove coalesced refresh storm: {stats}")

        auth_store = work / "broker-auth.json"
        mode = auth_store.stat().st_mode & 0o777 if auth_store.exists() else 0
        if mode != 0o600:
            raise AssertionError(f"broker auth store permissions not owner-only: {oct(mode)}")
        if proc.poll() is not None:
            raise AssertionError(f"broker exited after client EOF: returncode={proc.returncode}")
        return {
            "enabled": True,
            "stormRequests": storm_requests,
            "delayMs": delay_ms,
            "responses": len(responses),
            "stats": stats,
            "authStoreModeOctal": oct(mode),
            "residentAfterClientEOF": proc.poll() is None,
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


class CodexDriver:
    def __init__(self, *, root: Path, mode: str, mcp_churn: bool, mock_scenario: str | None) -> None:
        self.work = Path(tempfile.mkdtemp(prefix=f"codexkit-soak-{mode}-"))
        self.home = self.work / "home"
        if mcp_churn:
            write_mcp_churn_fixture(self.home)
        env = os.environ.copy()
        env["CODEX_HOME"] = str(self.home)
        if mode == "mock":
            env["CODEXKIT_MOCK"] = "1"
            if mock_scenario:
                env["CODEXKIT_MOCK_SCENARIO"] = mock_scenario

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
        self.events: queue.Queue[dict] = queue.Queue()
        self.responses: dict[int, dict] = {}
        self.completed: dict[str, int] = {}
        self.deltas: dict[str, int] = {}
        self.delta_chars: dict[str, int] = {}
        self.compactions = 0
        self.tool_completions = 0
        self.errors: list[str] = []
        self.stderr_lines: list[str] = []
        self._send_lock = threading.Lock()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            try:
                obj = json.loads(line)
            except Exception as exc:
                self.errors.append(f"invalid json line: {line[:200]} ({exc})")
                continue
            if "id" in obj:
                self.responses[obj["id"]] = obj
            method = obj.get("method")
            if method == "turn/completed":
                tid = obj.get("params", {}).get("threadId")
                if tid:
                    self.completed[tid] = self.completed.get(tid, 0) + 1
            elif method == "item/agentMessage/delta":
                params = obj.get("params", {})
                tid = params.get("threadId")
                if tid:
                    self.deltas[tid] = self.deltas.get(tid, 0) + 1
                    delta = params.get("delta")
                    if isinstance(delta, str):
                        self.delta_chars[tid] = self.delta_chars.get(tid, 0) + len(delta)
            elif method == "error":
                self.errors.append(str(obj))
            elif method == "thread/compacted":
                self.compactions += 1
            elif method == "item/completed":
                item = obj.get("params", {}).get("item", {})
                if isinstance(item, dict) and item.get("type") == "commandExecution":
                    self.tool_completions += 1
            self.events.put(obj)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip())

    def send(self, method: str, params: dict | None = None, timeout: float = 30) -> dict:
        with self._send_lock:
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
        raise TimeoutError(f"timeout waiting for {method} response id {rid}")

    def notify_initialized(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps({"method": "initialized"}, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def wait_completed(self, tid: str, target: int, timeout: float) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.completed.get(tid, 0) >= target:
                return
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.05)
        raise TimeoutError(
            f"timeout waiting for {target} completions on {tid}; "
            f"have {self.completed.get(tid, 0)}"
        )

    def wait_delta(self, tid: str, previous: int, timeout: float) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.deltas.get(tid, 0) > previous:
                return
            if self.proc.poll() is not None:
                raise RuntimeError(f"codexd exited early with {self.proc.returncode}")
            time.sleep(0.01)
        raise TimeoutError(
            f"timeout waiting for streamed delta on {tid}; "
            f"have {self.deltas.get(tid, 0)} previous={previous}"
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


def run(args: argparse.Namespace) -> None:
    root = Path(args.root)
    run_started_at = time.time()
    run_started_at_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(run_started_at))
    slow_probe: dict[str, int | str] | None = None
    if args.slow_client_probe and args.mode == "mock":
        slow_probe = run_slow_client_probe(
            root,
            slow_clients=args.slow_clients,
            hold_seconds=args.slow_client_hold,
        )
    broker_stats_probe: dict | None = None
    if args.broker_stats_probe and args.mode == "mock":
        broker_stats_probe = run_broker_stats_probe(
            root,
            storm_requests=args.broker_stats_requests,
            delay_ms=args.broker_stats_delay_ms,
        )

    mock_scenario = "tool-loop-compact" if args.tool_loop_compaction_probe and args.mode == "mock" else None
    driver = CodexDriver(
        root=root,
        mode=args.mode,
        mcp_churn=args.mcp_churn,
        mock_scenario=mock_scenario,
    )
    try:
        driver.send("initialize", {"clientInfo": {"name": f"soak-{args.mode}"}}, timeout=20)
        driver.notify_initialized()
        mcp_status_probes = 0
        if args.mcp_churn:
            status = driver.send("mcpServerStatus/list", {"detail": "toolsAndAuthOnly"}, timeout=20)
            data = status.get("result", {}).get("data", [])
            if not any(isinstance(item, dict) and item.get("name") == "soak" for item in data):
                raise AssertionError(f"mcpServerStatus/list did not include soak fixture: {status}")
            mcp_status_probes += 1

        threads: list[str] = []
        workspaces: dict[str, str] = {}
        for i in range(args.sessions):
            cwd = driver.work / f"workspace-{i}"
            cwd.mkdir(parents=True, exist_ok=True)
            resp = driver.send(
                "thread/start",
                {
                    "cwd": str(cwd),
                    "model": "mock" if args.mode == "mock" else args.model,
                    "developerInstructions": (
                        "You are in a severe macOS soak test. Keep responses concise. "
                        "For coding prompts, reason about file edits and edge cases "
                        "without asking for more input."
                    ),
                },
                timeout=30,
            )
            tid = resp["result"]["thread"]["id"]
            threads.append(tid)
            workspaces[tid] = str(cwd)

        start_metric = process_metrics(driver.proc.pid)
        resource_samples: list[dict] = [
            {"label": "start", "elapsedSeconds": round(time.time() - run_started_at, 3), "metrics": start_metric}
        ]

        def record_resource_sample(label: str) -> None:
            resource_samples.append({
                "label": label,
                "elapsedSeconds": round(time.time() - run_started_at, 3),
                "metrics": process_metrics(driver.proc.pid),
            })

        latencies: list[float] = []
        ttfts: list[float] = []
        output_rates: list[float] = []
        durability_probe_seconds: list[float] = []
        durability_probe_records = 0
        durability_lock = threading.Lock()
        prompts = [
            "Create a compact plan for adding a CLI flag, include two edge cases.",
            "Review this pseudo-code for race conditions: shared counter, two workers, delayed flush.",
            "Design a small Swift function that validates a Unix socket path and list tests.",
            "Given a failing macOS launchd service, identify root-cause checks in order.",
            "Summarize how to avoid leaking secrets into process argv during a model call.",
        ]

        def run_turn(tid: str, text: str, *, timeout: float) -> dict[str, float]:
            nonlocal durability_probe_records
            before = driver.completed.get(tid, 0)
            before_deltas = driver.deltas.get(tid, 0)
            before_chars = driver.delta_chars.get(tid, 0)

            t0 = time.time()
            driver.send(
                "turn/start",
                {"threadId": tid, "input": [{"type": "text", "text": text}]},
                timeout=30,
            )
            driver.wait_delta(tid, before_deltas, timeout=min(timeout, args.delta_timeout))
            first_delta_at = time.time()
            driver.wait_completed(tid, before + 1, timeout=timeout)
            completed_at = time.time()
            if args.durability_probe:
                durability = probe_durable_thread(driver.home, tid)
                with durability_lock:
                    durability_probe_seconds.append(float(durability["seconds"]))
                    durability_probe_records = max(durability_probe_records, int(durability["records"]))
            produced = max(1, driver.delta_chars.get(tid, 0) - before_chars)
            duration_after_first = max(0.001, completed_at - first_delta_at)
            return {
                "latency": completed_at - t0,
                "ttft": first_delta_at - t0,
                "outputRate": produced / duration_after_first,
            }

        turn_count = 0
        deadline = time.time() + args.seconds
        if args.quiet_slo:
            quiet = threads[0]
            quiet_prompt = (
                "Quiet probe: answer with one concise sentence about validating a "
                "macOS daemon health check."
            )
            baseline = [
                run_turn(
                    quiet,
                    quiet_prompt,
                    timeout=args.live_turn_timeout if args.mode == "live" else 20,
                )
                for _ in range(args.quiet_probes)
            ]
            turn_count += len(baseline)

            stop_noisy = threading.Event()
            noisy_errors: list[str] = []

            def noisy_worker(index: int, tid: str) -> None:
                local_turn = 0
                while not stop_noisy.is_set():
                    text = (
                        prompts[(index + local_turn) % len(prompts)]
                        + "\n"
                        + ("large-output-marker " * args.noisy_multiplier)
                    )
                    try:
                        run_turn(
                            tid,
                            text,
                            timeout=args.live_turn_timeout if args.mode == "live" else 20,
                        )
                    except Exception as exc:
                        noisy_errors.append(f"noisy thread {index}: {exc}")
                        stop_noisy.set()
                        return
                    local_turn += 1

            noisy_threads = []
            for index, tid in enumerate(threads[1:], start=1):
                worker = threading.Thread(target=noisy_worker, args=(index, tid), daemon=True)
                worker.start()
                noisy_threads.append(worker)

            try:
                time.sleep(args.noisy_warmup)
                record_resource_sample("quiet-pressure-start")
                pressured = [
                    run_turn(
                        quiet,
                        quiet_prompt,
                        timeout=args.live_turn_timeout if args.mode == "live" else 20,
                    )
                    for _ in range(args.quiet_probes)
                ]
                record_resource_sample("quiet-pressure-end")
                turn_count += len(pressured)
            finally:
                stop_noisy.set()
                for worker in noisy_threads:
                    worker.join(timeout=10)

            if noisy_errors:
                raise AssertionError("; ".join(noisy_errors[:3]))

            baseline_ttft = percentile([m["ttft"] for m in baseline], 0.99)
            pressured_ttft = percentile([m["ttft"] for m in pressured], 0.99)
            allowed_ttft = max(args.slo_ttft_slack_ms / 1000, baseline_ttft * args.slo_multiplier)
            ttft_degradation = pressured_ttft - baseline_ttft
            if ttft_degradation > allowed_ttft:
                raise AssertionError(
                    "quiet TTFT p99 degraded too much under noisy pressure: "
                    f"baseline={baseline_ttft:.3f}s pressured={pressured_ttft:.3f}s "
                    f"allowed_delta={allowed_ttft:.3f}s"
                )

            baseline_rate = statistics.median([m["outputRate"] for m in baseline])
            pressured_rate = statistics.median([m["outputRate"] for m in pressured])
            min_rate = baseline_rate / args.slo_multiplier
            if pressured_rate < min_rate:
                raise AssertionError(
                    "quiet output rate degraded too much under noisy pressure: "
                    f"baseline={baseline_rate:.1f} chars/s pressured={pressured_rate:.1f} chars/s "
                    f"minimum={min_rate:.1f} chars/s"
                )

            latencies.extend(m["latency"] for m in baseline + pressured)
            ttfts.extend(m["ttft"] for m in baseline + pressured)
            output_rates.extend(m["outputRate"] for m in baseline + pressured)

        turn_target = args.sessions * args.turns
        while time.time() < deadline or turn_count < turn_target:
            tid = threads[turn_count % len(threads)]
            text = prompts[turn_count % len(prompts)]
            if turn_count % 3 == 1:
                text += "\n" + ("large-output-marker " * 400)

            metrics = run_turn(
                tid,
                text,
                timeout=args.live_turn_timeout if args.mode == "live" else 20,
            )
            latencies.append(metrics["latency"])
            ttfts.append(metrics["ttft"])
            output_rates.append(metrics["outputRate"])
            turn_count += 1
            record_resource_sample(f"turn-{turn_count}")

            if turn_count % max(1, len(threads) // 2) == 0:
                driver.send("thread/list", {"limit": 100}, timeout=20)
                probe = threads[turn_count % len(threads)]
                driver.send("thread/read", {"threadId": probe}, timeout=20)
                driver.send("thread/resume", {"threadId": probe}, timeout=20)
                if args.mcp_churn:
                    driver.send("mcpServerStatus/list", {"detail": "toolsAndAuthOnly"}, timeout=20)
                    mcp_status_probes += 1

        if args.mcp_churn:
            driver.send("mcpServerStatus/list", {"detail": "toolsAndAuthOnly"}, timeout=20)
            mcp_status_probes += 1

        for tid in threads:
            if driver.completed.get(tid, 0) < 1:
                raise AssertionError(f"thread {tid} never completed a turn")
        if not driver.deltas:
            raise AssertionError("no streamed assistant deltas observed")
        if not any("codexd workerMode=spawned" in line for line in driver.stderr_lines):
            raise AssertionError("codexd did not use spawned worker mode")
        if not any("codex-session worker ready" in line for line in driver.stderr_lines):
            raise AssertionError("codex-session worker did not start")
        if args.mcp_churn and mcp_status_probes < 2:
            raise AssertionError(f"expected repeated MCP status churn probes, saw {mcp_status_probes}")
        if mock_scenario == "tool-loop-compact":
            expected = max(1, turn_count)
            if driver.tool_completions < expected * 2:
                raise AssertionError(
                    f"tool-loop compaction probe missed tool completions: "
                    f"toolCompletions={driver.tool_completions} expected>={expected * 2}"
                )
            if driver.compactions < expected * 2:
                raise AssertionError(
                    f"tool-loop compaction probe missed compactions: "
                    f"compactions={driver.compactions} expected>={expected * 2}"
                )
        if args.durability_probe:
            expected_probes = max(1, turn_count)
            if len(durability_probe_seconds) < expected_probes:
                raise AssertionError(
                    f"durability probes missed turns: probes={len(durability_probe_seconds)} "
                    f"turns={turn_count}"
                )
            durability_p99 = percentile(durability_probe_seconds, 0.99)
            if durability_p99 > args.durability_probe_p99_seconds:
                raise AssertionError(
                    "durability probe p99 exceeded limit: "
                    f"p99={durability_p99:.3f}s limit={args.durability_probe_p99_seconds:.3f}s"
                )

        end_metric = process_metrics(driver.proc.pid)
        resource_samples.append({
            "label": "end",
            "elapsedSeconds": round(time.time() - run_started_at, 3),
            "metrics": end_metric,
        })
        resource_trend = summarize_resource_trend(
            resource_samples,
            sessions=args.sessions,
            fd_growth_limit=args.fd_growth_limit,
            rss_growth_limit_kb=args.rss_growth_limit_mib * 1024,
        )
        if end_metric["fd_count"] and start_metric["fd_count"]:
            fd_growth = end_metric["fd_count"] - start_metric["fd_count"]
            if fd_growth > max(32, args.sessions * 3):
                raise AssertionError(
                    f"fd growth too high: start={start_metric['fd_count']} "
                    f"end={end_metric['fd_count']}"
                )
        if end_metric["workers"] > args.sessions:
            raise AssertionError(
                f"worker count exceeds session count: "
                f"workers={end_metric['workers']} sessions={args.sessions}"
            )

        run_ended_at = time.time()
        payload = {
            "mode": args.mode,
            "secondsRequested": args.seconds,
            "startedAt": run_started_at_iso,
            "endedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(run_ended_at)),
            "elapsedSeconds": round(run_ended_at - run_started_at, 3),
            "sessions": args.sessions,
            "turnsRequestedPerSession": args.turns,
            "turnsCompleted": turn_count,
            "sessionDetails": [
                {
                    "threadId": tid,
                    "workspace": workspaces[tid],
                    "turnsCompleted": driver.completed.get(tid, 0),
                    "deltaEvents": driver.deltas.get(tid, 0),
                    "outputChars": driver.delta_chars.get(tid, 0),
                }
                for tid in threads
            ],
            "latencySeconds": {
                "min": round(min(latencies), 3),
                "median": round(statistics.median(latencies), 3),
                "p95": round(percentile(latencies, 0.95), 3),
                "max": round(max(latencies), 3),
            },
            "ttftSeconds": {
                "median": round(statistics.median(ttfts), 3),
                "p95": round(percentile(ttfts, 0.95), 3),
                "p99": round(percentile(ttfts, 0.99), 3),
            },
            "outputCharsPerSecond": {
                "median": round(statistics.median(output_rates), 1),
                "p05": round(percentile(output_rates, 0.05), 1),
            },
            "durabilityProbeSeconds": {
                "count": len(durability_probe_seconds),
                "median": round(statistics.median(durability_probe_seconds), 4)
                    if durability_probe_seconds else 0,
                "p95": round(percentile(durability_probe_seconds, 0.95), 4),
                "p99": round(percentile(durability_probe_seconds, 0.99), 4),
                "max": round(max(durability_probe_seconds), 4)
                    if durability_probe_seconds else 0,
                "maxRecords": durability_probe_records,
            },
            "startMetric": start_metric,
            "endMetric": end_metric,
            "resourceTrend": resource_trend,
            "mcpStatusProbes": mcp_status_probes,
            "slowClientProbe": slow_probe,
            "brokerStatsProbe": broker_stats_probe,
            "toolLoopCompactionProbe": {
                "enabled": mock_scenario == "tool-loop-compact",
                "toolCompletions": driver.tool_completions,
                "compactions": driver.compactions,
            },
        }
        encoded = json.dumps(payload, sort_keys=True)
        print(encoded)
        if args.evidence_file:
            Path(args.evidence_file).write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    finally:
        driver.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(Path.cwd()))
    parser.add_argument("--mode", choices=["mock", "live"], required=True)
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--sessions", type=int, required=True)
    parser.add_argument("--turns", type=int, required=True)
    parser.add_argument("--model", default="gpt-4o-mini")
    parser.add_argument("--live-turn-timeout", type=int, default=120)
    parser.add_argument("--delta-timeout", type=int, default=20)
    parser.add_argument("--quiet-slo", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--quiet-probes", type=int, default=3)
    parser.add_argument("--noisy-warmup", type=float, default=0.25)
    parser.add_argument("--noisy-multiplier", type=int, default=800)
    parser.add_argument("--slo-multiplier", type=float, default=1.05)
    parser.add_argument("--slo-ttft-slack-ms", type=float, default=50)
    parser.add_argument("--mcp-churn", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--slow-client-probe", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--slow-clients", type=int, default=6)
    parser.add_argument("--slow-client-hold", type=float, default=0.25)
    parser.add_argument("--broker-stats-probe", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--broker-stats-requests", type=int, default=200)
    parser.add_argument("--broker-stats-delay-ms", type=int, default=30)
    parser.add_argument("--durability-probe", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--durability-probe-p99-seconds", type=float, default=1.0)
    parser.add_argument("--fd-growth-limit", type=int, default=32)
    parser.add_argument("--rss-growth-limit-mib", type=int, default=512)
    parser.add_argument("--tool-loop-compaction-probe", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--evidence-file")
    args = parser.parse_args()

    if args.mode == "live" and not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("OPENAI_API_KEY is required for live soak mode")
    if args.sessions < 2:
        raise SystemExit("--sessions must be at least 2")
    if args.turns < 1:
        raise SystemExit("--turns must be at least 1")
    if args.seconds < 5:
        raise SystemExit("--seconds must be at least 5")
    if args.quiet_slo and args.sessions < 3:
        raise SystemExit("--quiet-slo requires at least 3 sessions")
    if args.quiet_probes < 1:
        raise SystemExit("--quiet-probes must be at least 1")
    if args.slow_clients < 1:
        raise SystemExit("--slow-clients must be at least 1")
    if args.broker_stats_requests < 2:
        raise SystemExit("--broker-stats-requests must be at least 2")
    if args.broker_stats_delay_ms < 0:
        raise SystemExit("--broker-stats-delay-ms must be non-negative")
    if args.durability_probe_p99_seconds <= 0:
        raise SystemExit("--durability-probe-p99-seconds must be positive")
    args.fd_growth_limit = max(args.fd_growth_limit, args.sessions * 3)
    if args.rss_growth_limit_mib <= 0:
        raise SystemExit("--rss-growth-limit-mib must be positive")

    run(args)


if __name__ == "__main__":
    main()
