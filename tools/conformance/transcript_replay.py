#!/usr/bin/env python3
"""Replay deterministic app-server transcripts against Swift and Codex binaries.

The gate intentionally stays below live model behavior: it exercises the JSONL
app-server contract, deterministic request/response shapes, filesystem RPCs,
and notification ordering that can be compared without a Responses backend.
When a pinned Codex binary is supplied, every transcript is run against both
servers and normalized structural drift fails the gate.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any


Json = dict[str, Any]


TRANSCRIPTS: list[dict[str, Any]] = [
    {
        "name": "handshake-models-config",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {"id": 2, "method": "modelProvider/capabilities/read", "params": {}},
            {"id": 3, "method": "model/list", "params": {}},
            {"id": 4, "method": "config/read", "params": {}},
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": ["imageGeneration", "namespaceTools", "webSearch"]},
            3: {"resultKeys": ["data"]},
            4: {"resultKeys": ["config", "origins"]},
        },
    },
    {
        "name": "long-tail-response-shapes",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "command/exec",
                "params": {
                    "command": ["/bin/echo", "codexkit"],
                    "cwd": "{work}",
                    "sandboxPolicy": {"type": "dangerFullAccess"},
                    "timeoutMs": 5000,
                },
            },
            {"id": 3, "method": "plugin/list", "params": {}},
            {"id": 4, "method": "hooks/list", "params": {"cwd": "{work}"}},
            {"id": 5, "method": "skills/list", "params": {"cwds": ["{work}"]}},
        ],
        "expect": {
            2: {
                "resultKeys": ["exitCode", "stderr", "stdout"],
                "values": {"exitCode": 0, "stdout": "codexkit\n", "stderr": ""},
            },
            3: {"resultKeys": ["featuredPluginIds", "marketplaceLoadErrors", "marketplaces"]},
            4: {"resultKeys": ["data"]},
            5: {"resultKeys": ["data"]},
        },
    },
    {
        "name": "filesystem-behavior-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    }
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "fs/createDirectory",
                "params": {"path": "{work}/nested", "recursive": True},
            },
            {
                "id": 3,
                "method": "fs/writeFile",
                "params": {"path": "{work}/nested/note.txt", "dataBase64": "{noteBase64}"},
            },
            {
                "id": 4,
                "method": "fs/readFile",
                "params": {"path": "{work}/nested/note.txt"},
            },
            {
                "id": 5,
                "method": "fs/getMetadata",
                "params": {"path": "{work}/nested/note.txt"},
            },
            {
                "id": 6,
                "method": "fs/readDirectory",
                "params": {"path": "{work}/nested"},
            },
            {
                "id": 7,
                "method": "fs/copy",
                "params": {
                    "sourcePath": "{work}/nested/note.txt",
                    "destinationPath": "{work}/nested/copied.txt",
                },
            },
            {
                "id": 8,
                "method": "fs/readDirectory",
                "params": {"path": "{work}/nested"},
            },
            {
                "id": 9,
                "method": "fs/remove",
                "params": {"path": "{work}/nested/copied.txt", "force": False},
            },
            {
                "id": 10,
                "method": "fs/readDirectory",
                "params": {"path": "{work}/nested"},
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": []},
            3: {"resultKeys": []},
            4: {"resultKeys": ["dataBase64"], "dataBase64": "codexkit transcript\n"},
            5: {
                "resultKeys": ["createdAtMs", "isDirectory", "isFile", "isSymlink", "modifiedAtMs"],
                "values": {"isDirectory": False, "isFile": True, "isSymlink": False},
            },
            6: {"resultKeys": ["entries"], "entryNames": ["note.txt"]},
            7: {"resultKeys": []},
            8: {"resultKeys": ["entries"], "entryNames": ["copied.txt", "note.txt"]},
            9: {"resultKeys": []},
            10: {
                "resultKeys": ["entries"],
                "entryNames": ["note.txt"],
                "absentEntryNames": ["copied.txt"],
            },
        },
    },
    {
        "name": "fuzzy-search-behavior-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    }
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "fs/writeFile",
                "params": {"path": "{work}/alpha.txt", "dataBase64": "{alphaBase64}"},
            },
            {
                "id": 3,
                "method": "fs/writeFile",
                "params": {"path": "{work}/alphabet.txt", "dataBase64": "{alphaBase64}"},
            },
            {
                "id": 4,
                "method": "fs/writeFile",
                "params": {"path": "{work}/beta.txt", "dataBase64": "{betaBase64}"},
            },
            {
                "id": 5,
                "method": "fs/createDirectory",
                "params": {"path": "{work}/docs", "recursive": True},
            },
            {
                "id": 6,
                "method": "fs/writeFile",
                "params": {"path": "{work}/docs/alpine.md", "dataBase64": "{alphaBase64}"},
            },
            {
                "id": 7,
                "method": "fuzzyFileSearch",
                "params": {"query": "alp", "roots": ["{work}"]},
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": []},
            3: {"resultKeys": []},
            4: {"resultKeys": []},
            5: {"resultKeys": []},
            6: {"resultKeys": []},
            7: {
                "resultKeys": ["files"],
                "filePaths": ["alpha.txt", "alphabet.txt", "docs/alpine.md"],
                "absentFilePaths": ["beta.txt"],
                "fileResultRequiredKeys": [
                    "file_name",
                    "indices",
                    "match_type",
                    "path",
                    "root",
                    "score",
                ],
                "summaryPaths": ["result.files"],
            },
        },
    },
    {
        "name": "config-write-behavior-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    }
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "config/value/write",
                "params": {
                    "keyPath": "model",
                    "value": "gpt-4o-mini",
                    "mergeStrategy": "replace",
                },
            },
            {
                "id": 3,
                "method": "config/batchWrite",
                "params": {
                    "edits": [
                        {
                            "keyPath": "features.personality",
                            "value": True,
                            "mergeStrategy": "replace",
                        }
                    ]
                },
            },
            {"id": 4, "method": "config/read", "params": {}},
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": ["filePath", "overriddenMetadata", "status", "version"]},
            3: {"resultKeys": ["filePath", "overriddenMetadata", "status", "version"]},
            4: {
                "resultKeys": ["config", "origins"],
                "values": {
                    "config.model": "gpt-4o-mini",
                    "config.features.personality": True,
                },
            },
        },
    },
    {
        "name": "thread-state-lifecycle",
        "servers": ["swift"],
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "thread/start",
                "params": {"cwd": "{work}", "model": "gpt-4o-mini", "ephemeral": False},
                "capture": {"threadId": "result.thread.id"},
            },
            {
                "id": 3,
                "method": "thread/name/set",
                "params": {"threadId": "{threadId}", "name": "Replay State Thread"},
            },
            {
                "id": 4,
                "method": "thread/goal/set",
                "params": {
                    "threadId": "{threadId}",
                    "objective": "Prove durable state replay",
                    "status": "active",
                    "tokenBudget": 12345,
                },
            },
            {
                "id": 5,
                "method": "thread/goal/get",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 6,
                "method": "thread/memoryMode/set",
                "params": {"threadId": "{threadId}", "mode": "enabled"},
            },
            {
                "id": 7,
                "method": "thread/inject_items",
                "params": {
                    "threadId": "{threadId}",
                    "items": [
                        {
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                {"type": "output_text", "text": "codexkit injected replay note"}
                            ],
                        }
                    ],
                },
            },
            {
                "id": 8,
                "method": "thread/turns/list",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 9,
                "method": "thread/read",
                "params": {"threadId": "{threadId}", "includeTurns": True},
            },
            {
                "id": 10,
                "method": "thread/unsubscribe",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 11,
                "method": "thread/resume",
                "params": {"threadId": "{threadId}", "cwd": "{work}"},
            },
            {
                "id": 12,
                "method": "thread/goal/clear",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 13,
                "method": "thread/archive",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 14,
                "method": "thread/unarchive",
                "params": {"threadId": "{threadId}"},
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": ["thread"], "paths": ["result.thread.id"]},
            3: {"resultKeys": []},
            4: {"resultKeys": ["goal"], "values": {"goal.objective": "Prove durable state replay"}},
            5: {"resultKeys": ["goal"], "values": {"goal.objective": "Prove durable state replay"}},
            6: {"resultKeys": []},
            7: {"resultKeys": []},
            8: {"resultKeys": ["backwardsCursor", "data", "nextCursor"]},
            9: {"resultKeys": ["thread"], "values": {"thread.name": "Replay State Thread"}},
            10: {"resultKeys": ["status"]},
            11: {"resultKeys": ["thread"]},
            12: {"resultKeys": ["cleared"], "values": {"cleared": True}},
            13: {"resultKeys": []},
            14: {"resultKeys": ["thread"]},
        },
    },
    {
        "name": "mock-turn-event-stream-and-durable-readback",
        "servers": ["swift"],
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "thread/start",
                "params": {"cwd": "{work}", "model": "mock", "ephemeral": False},
                "capture": {"threadId": "result.thread.id"},
            },
            {
                "id": 3,
                "method": "turn/start",
                "params": {
                    "threadId": "{threadId}",
                    "input": [{"type": "text", "text": "Prove transcript replay turn durability"}],
                },
            },
            {
                "waitNotification": {
                    "method": "turn/started",
                    "expect": {
                        "values": {"params.threadId": "{threadId}"},
                        "paths": ["params.turn.id", "params.turn.status"],
                    },
                }
            },
            {
                "waitNotification": {
                    "method": "item/agentMessage/delta",
                    "expect": {
                        "values": {
                            "params.threadId": "{threadId}",
                            "params.delta": "Hello from codex-session (mock).",
                        },
                        "paths": ["params.turnId", "params.itemId"],
                    },
                }
            },
            {
                "waitNotification": {
                    "method": "item/completed",
                    "expect": {
                        "values": {"params.threadId": "{threadId}"},
                        "containsText": ["Hello from codex-session (mock)."],
                        "paths": ["params.turnId", "params.item.id", "params.item.type"],
                    },
                }
            },
            {
                "waitNotification": {
                    "method": "turn/completed",
                    "expect": {
                        "values": {
                            "params.threadId": "{threadId}",
                            "params.turn.status": "completed",
                        },
                        "paths": ["params.turn.id"],
                    },
                }
            },
            {
                "id": 4,
                "method": "thread/turns/list",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 5,
                "method": "thread/read",
                "params": {"threadId": "{threadId}", "includeTurns": True},
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": ["thread"], "paths": ["result.thread.id"]},
            3: {"resultKeys": ["turn"], "values": {"turn.status": "inProgress"}},
            4: {
                "resultKeys": ["backwardsCursor", "data", "nextCursor"],
                "containsText": ["Hello from codex-session (mock)."],
            },
            5: {
                "resultKeys": ["thread"],
            },
        },
    },
    {
        "name": "thread-durable-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "thread/start",
                "params": {"cwd": "{work}", "model": "gpt-4o-mini", "ephemeral": False},
                "capture": {"threadId": "result.thread.id"},
            },
            {
                "id": 3,
                "method": "thread/name/set",
                "params": {"threadId": "{threadId}", "name": "Replay Oracle Thread"},
            },
            {
                "id": 4,
                "method": "thread/metadata/update",
                "params": {
                    "threadId": "{threadId}",
                    "gitInfo": {"branch": "feature/oracle-replay", "sha": "abc123"},
                },
            },
            {
                "id": 5,
                "method": "thread/inject_items",
                "params": {
                    "threadId": "{threadId}",
                    "items": [
                        {
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                {"type": "output_text", "text": "codexkit oracle replay note"}
                            ],
                        }
                    ],
                },
            },
            {
                "id": 6,
                "method": "thread/turns/list",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 7,
                "method": "thread/read",
                "params": {"threadId": "{threadId}", "includeTurns": True},
            },
            {
                "id": 8,
                "method": "thread/unsubscribe",
                "params": {"threadId": "{threadId}"},
            },
            {
                "id": 9,
                "method": "thread/resume",
                "params": {"threadId": "{threadId}", "cwd": "{work}"},
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {"resultKeys": ["thread"], "paths": ["result.thread.id"]},
            3: {"resultKeys": []},
            4: {
                "resultKeys": ["thread"],
                "values": {
                    "thread.gitInfo.branch": "feature/oracle-replay",
                    "thread.gitInfo.sha": "abc123",
                },
            },
            5: {"resultKeys": []},
            6: {"resultKeys": ["backwardsCursor", "data", "nextCursor"]},
            7: {
                "resultKeys": ["thread"],
                "values": {"thread.gitInfo.branch": "feature/oracle-replay"},
            },
            8: {"resultKeys": ["status"]},
            9: {"resultKeys": ["thread"]},
        },
    },
    {
        "name": "error-shape-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
            {"method": "initialized"},
            {"id": 2, "method": "thread/goal/set", "params": {}},
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {
                "error": {
                    "code": -32600,
                    "message": "Invalid request: missing field `threadId`",
                }
            },
        },
    },
    {
        "name": "experimental-gating-oracle-parity",
        "steps": [
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "codexkit-transcript-replay",
                        "title": "CodexKit Transcript Replay",
                        "version": "1",
                    }
                },
            },
            {"method": "initialized"},
            {
                "id": 2,
                "method": "thread/start",
                "params": {"cwd": "{work}", "runtimeWorkspaceRoots": []},
            },
            {
                "id": 3,
                "method": "turn/start",
                "params": {
                    "threadId": "thread_00000000000000000000000000",
                    "input": [],
                    "runtimeWorkspaceRoots": [],
                },
            },
            {
                "id": 4,
                "method": "thread/memoryMode/set",
                "params": {
                    "threadId": "thread_00000000000000000000000000",
                    "mode": "enabled",
                },
            },
        ],
        "expect": {
            1: {"resultKeys": ["codexHome", "platformFamily", "platformOs", "userAgent"]},
            2: {
                "error": {
                    "code": -32600,
                    "message": "thread/start.runtimeWorkspaceRoots requires experimentalApi capability",
                }
            },
            3: {
                "error": {
                    "code": -32600,
                    "message": "turn/start.runtimeWorkspaceRoots requires experimentalApi capability",
                }
            },
            4: {
                "error": {
                    "code": -32600,
                    "message": "thread/memoryMode/set requires experimentalApi capability",
                }
            },
        },
    },
]


class AppServer:
    def __init__(self, name: str, argv: list[str], env: dict[str, str]) -> None:
        self.name = name
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self.messages: "queue.Queue[Json]" = queue.Queue()
        self.pending_notifications: deque[Json] = deque()
        self.stderr_lines: list[str] = []
        self.errors: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            try:
                self.messages.put(json.loads(line))
            except Exception as exc:
                self.errors.append(f"invalid JSON from {self.name}: {line[:200]} ({exc})")

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_lines.append(line.rstrip())

    def send(self, payload: Json) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def request(self, payload: Json, timeout: float = 20) -> Json:
        rid = payload["id"]
        self.send(payload)
        deadline = time.time() + timeout
        notifications: list[Json] = []
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} exited early with {self.proc.returncode}")
            try:
                msg = self.messages.get(timeout=0.05)
            except queue.Empty:
                continue
            if msg.get("id") == rid:
                if notifications:
                    msg["_notificationsBeforeResponse"] = notifications
                return msg
            notifications.append(msg)
            if "method" in msg:
                self.pending_notifications.append(msg)
        raise TimeoutError(f"timeout waiting for {self.name} response id {rid}")

    def wait_notification(self, method: str, timeout: float = 20) -> Json:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} exited early with {self.proc.returncode}")
            while self.pending_notifications:
                msg = self.pending_notifications.popleft()
                if msg.get("method") == method:
                    return msg
            try:
                msg = self.messages.get(timeout=0.05)
            except queue.Empty:
                continue
            if msg.get("method") == method:
                return msg
        raise TimeoutError(f"timeout waiting for {self.name} notification {method}")

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def deep_format(value: Any, variables: dict[str, str]) -> Any:
    if isinstance(value, str):
        return value.format(**variables)
    if isinstance(value, list):
        return [deep_format(v, variables) for v in value]
    if isinstance(value, dict):
        return {k: deep_format(v, variables) for k, v in value.items()}
    return value


def result_keys(response: Json) -> list[str]:
    result = response.get("result")
    if not isinstance(result, dict):
        return []
    return sorted(result.keys())


def value_at_path(root: Any, path: str) -> Any:
    current = root
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            raise KeyError(path)
    return current


def compact_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {"type": "object", "keys": sorted(value.keys())}
    if isinstance(value, list):
        return {"type": "array", "count": len(value)}
    return value


def validate_response(server: str, transcript: str, response: Json, expect: Json) -> Json:
    if "error" in expect:
        error = response.get("error")
        if not isinstance(error, dict):
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} expected error, got {response}"
            )
        expected_error = expect["error"]
        for key, expected in expected_error.items():
            actual = error.get(key)
            if actual != expected:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} error {key} drift: "
                    f"expected={expected!r} actual={actual!r}"
                )
        return {
            "id": response.get("id"),
            "error": {key: error.get(key) for key in sorted(expected_error.keys())},
        }
    if "error" in response:
        raise AssertionError(f"{server}/{transcript} id={response.get('id')} error: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise AssertionError(f"{server}/{transcript} id={response.get('id')} result is not object")

    expected_keys = sorted(expect.get("resultKeys", []))
    actual_keys = result_keys(response)
    missing = sorted(set(expected_keys) - set(actual_keys))
    if missing:
        raise AssertionError(
            f"{server}/{transcript} id={response.get('id')} missing result keys: "
            f"missing={missing} actual={actual_keys}"
        )
    for key, expected in (expect.get("values") or {}).items():
        try:
            actual = value_at_path(result, key)
        except KeyError:
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} missing value path {key}"
            ) from None
        if actual != expected:
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} value drift for {key}: "
                f"expected={expected!r} actual={actual!r}"
            )
    for path in expect.get("paths", []):
        try:
            value_at_path(response, path)
        except KeyError:
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} missing response path {path}"
            ) from None
    if "dataBase64" in expect:
        decoded = base64.b64decode(result.get("dataBase64", "")).decode("utf-8")
        if decoded != expect["dataBase64"]:
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} dataBase64 drift: "
                f"expected={expect['dataBase64']!r} actual={decoded!r}"
            )
    if "entryNames" in expect:
        entries = result.get("entries")
        if not isinstance(entries, list):
            raise AssertionError(f"{server}/{transcript} id={response.get('id')} entries is not list")
        names = sorted(e.get("fileName") for e in entries if isinstance(e, dict))
        for name in expect["entryNames"]:
            if name not in names:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} missing directory entry {name!r}: {names}"
                )
    if "absentEntryNames" in expect:
        entries = result.get("entries")
        if not isinstance(entries, list):
            raise AssertionError(f"{server}/{transcript} id={response.get('id')} entries is not list")
        names = sorted(e.get("fileName") for e in entries if isinstance(e, dict))
        for name in expect["absentEntryNames"]:
            if name in names:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} unexpected directory entry {name!r}: {names}"
                )
    if "filePaths" in expect or "absentFilePaths" in expect or "fileResultRequiredKeys" in expect:
        files = result.get("files")
        if not isinstance(files, list):
            raise AssertionError(f"{server}/{transcript} id={response.get('id')} files is not list")
        paths = [f.get("path") for f in files if isinstance(f, dict)]
        for path in expect.get("filePaths", []):
            if path not in paths:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} missing fuzzy result {path!r}: {paths}"
                )
        for path in expect.get("absentFilePaths", []):
            if path in paths:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} unexpected fuzzy result {path!r}: {paths}"
                )
        required = set(expect.get("fileResultRequiredKeys", []))
        for file_result in files:
            if not isinstance(file_result, dict):
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} fuzzy result is not object"
                )
            missing_file_keys = sorted(required - set(file_result.keys()))
            if missing_file_keys:
                raise AssertionError(
                    f"{server}/{transcript} id={response.get('id')} fuzzy result missing keys "
                    f"{missing_file_keys}: {file_result}"
                )
    for needle in expect.get("containsText", []):
        text = json.dumps(result, sort_keys=True)
        if needle not in text:
            raise AssertionError(
                f"{server}/{transcript} id={response.get('id')} result missing text {needle!r}: {text[:1000]}"
            )
    summary: Json = {"id": response.get("id"), "resultKeys": expected_keys}
    if expect.get("summaryPaths"):
        summary["summary"] = {
            path: compact_value(value_at_path(response, path))
            for path in expect["summaryPaths"]
        }
    return summary


def validate_notification(server: str, transcript: str, message: Json, expect: Json) -> Json:
    for key, expected in (expect.get("values") or {}).items():
        try:
            actual = value_at_path(message, key)
        except KeyError:
            raise AssertionError(
                f"{server}/{transcript} notification {message.get('method')} missing value path {key}"
            ) from None
        if actual != expected:
            raise AssertionError(
                f"{server}/{transcript} notification {message.get('method')} value drift for {key}: "
                f"expected={expected!r} actual={actual!r}"
            )
    for path in expect.get("paths", []):
        try:
            value_at_path(message, path)
        except KeyError:
            raise AssertionError(
                f"{server}/{transcript} notification {message.get('method')} missing path {path}"
            ) from None
    for needle in expect.get("containsText", []):
        text = json.dumps(message.get("params") or {}, sort_keys=True)
        if needle not in text:
            raise AssertionError(
                f"{server}/{transcript} notification {message.get('method')} missing text {needle!r}: "
                f"{text[:1000]}"
            )
    return {
        "notification": message.get("method"),
        "paths": sorted(expect.get("paths", [])),
        "valueKeys": sorted((expect.get("values") or {}).keys()),
    }


def capture_response_values(response: Json, capture: dict[str, str], variables: dict[str, str]) -> None:
    for name, path in capture.items():
        try:
            value = value_at_path(response, path)
        except KeyError:
            raise AssertionError(f"capture path missing: {path}") from None
        if not isinstance(value, str):
            raise AssertionError(f"capture path {path} did not resolve to a string: {value!r}")
        variables[name] = value


def replay(name: str, argv: list[str], transcript: dict[str, Any], root: Path) -> list[Json]:
    work = root / f"{name}-{transcript['name']}-work"
    home = root / f"{name}-{transcript['name']}-home"
    work.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)
    variables = {
        "work": str(work),
        "noteBase64": base64.b64encode(b"codexkit transcript\n").decode("ascii"),
        "alphaBase64": base64.b64encode(b"alpha transcript\n").decode("ascii"),
        "betaBase64": base64.b64encode(b"beta transcript\n").decode("ascii"),
    }
    env = os.environ.copy()
    env["CODEX_HOME"] = str(home)
    env.setdefault("RUST_LOG", "error")
    if name == "swift":
        env["CODEXKIT_MOCK"] = "1"

    server = AppServer(name, argv, env)
    summaries: list[Json] = []
    try:
        for raw in transcript["steps"]:
            payload = deep_format(raw, variables)
            if "waitNotification" in payload:
                spec = payload["waitNotification"]
                message = server.wait_notification(spec["method"])
                summaries.append(validate_notification(
                    name, transcript["name"], message, spec.get("expect") or {}))
                continue
            if "id" not in payload:
                server.send(payload)
                continue
            response = server.request(payload)
            expect = transcript["expect"].get(payload["id"])
            if expect is not None:
                summaries.append(validate_response(name, transcript["name"], response, expect))
            elif "error" in response:
                raise AssertionError(
                    f"{name}/{transcript['name']} id={response.get('id')} error: {response['error']}"
                )
            if raw.get("capture"):
                capture_response_values(response, raw["capture"], variables)
        if server.errors:
            raise AssertionError("; ".join(server.errors[:3]))
        return summaries
    finally:
        server.close()


def transcript_runs_on(transcript: dict[str, Any], server_name: str) -> bool:
    servers = transcript.get("servers")
    return servers is None or server_name in servers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-bin", required=True)
    parser.add_argument("--codex-bin")
    parser.add_argument("--work-root")
    args = parser.parse_args()

    swift_bin = Path(args.swift_bin)
    if not swift_bin.exists():
        raise SystemExit(f"Swift binary not found: {swift_bin}")
    codex_bin = Path(args.codex_bin) if args.codex_bin else None
    if codex_bin is not None and not codex_bin.exists():
        raise SystemExit(f"Codex oracle binary not found: {codex_bin}")

    owned_tmp = None
    if args.work_root:
        root = Path(args.work_root)
        root.mkdir(parents=True, exist_ok=True)
    else:
        owned_tmp = tempfile.TemporaryDirectory(prefix="codexkit-transcript-replay-")
        root = Path(owned_tmp.name)

    report: dict[str, Any] = {"transcripts": []}
    try:
        for transcript in TRANSCRIPTS:
            if not transcript_runs_on(transcript, "swift"):
                continue
            swift = replay("swift", [str(swift_bin)], transcript, root)
            entry: dict[str, Any] = {"name": transcript["name"], "swift": swift}
            if codex_bin is not None:
                if transcript_runs_on(transcript, "codex"):
                    codex = replay("codex", [str(codex_bin), "app-server", "--listen", "stdio://"], transcript, root)
                    if swift != codex:
                        raise AssertionError(
                            f"{transcript['name']} normalized drift:\n"
                            f"swift={json.dumps(swift, sort_keys=True)}\n"
                            f"codex={json.dumps(codex, sort_keys=True)}"
                        )
                    entry["codex"] = codex
                else:
                    entry["codex"] = "skipped-by-transcript-server-filter"
            report["transcripts"].append(entry)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    finally:
        if owned_tmp is not None:
            owned_tmp.cleanup()


if __name__ == "__main__":
    sys.exit(main())
