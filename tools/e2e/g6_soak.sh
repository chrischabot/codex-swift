#!/usr/bin/env bash
# Configurable macOS soak/noisy-neighbor gate for the real codexd executable.
#
# Defaults are short enough for local verification. Release certification should
# raise CODEXKIT_SOAK_SECONDS=86400 and CODEXKIT_SOAK_SESSIONS=50. When
# OPENAI_API_KEY is set, a small live multi-turn coding-session pass runs unless
# CODEXKIT_SOAK_LIVE=0.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool python3
require_tool ps

gate_start "Build release binary for soak"
run swift build -c release

SOAK_SECONDS="${CODEXKIT_SOAK_SECONDS:-45}"
SOAK_SESSIONS="${CODEXKIT_SOAK_SESSIONS:-8}"
SOAK_TURNS="${CODEXKIT_SOAK_TURNS:-3}"
SOAK_MODEL="${CODEXKIT_SOAK_MODEL:-gpt-4o-mini}"
SOAK_LIVE="${CODEXKIT_SOAK_LIVE:-auto}"
EVIDENCE_DIR="${CODEXKIT_EVIDENCE_DIR:-}"
EVIDENCE_PREFIX=""
if [[ -n "$EVIDENCE_DIR" ]]; then
  mkdir -p "$EVIDENCE_DIR"
  EVIDENCE_PREFIX="$EVIDENCE_DIR/g6_soak-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

if [[ "$SOAK_LIVE" == "auto" ]]; then
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    SOAK_LIVE=1
  else
    SOAK_LIVE=0
  fi
fi

evidence_arg() {
  local suffix="$1"
  if [[ -n "$EVIDENCE_PREFIX" ]]; then
    printf '%s\n' "$EVIDENCE_PREFIX.$suffix.json"
  fi
}

write_manifest() {
  [[ -n "$EVIDENCE_PREFIX" ]] || return 0
  CODEXKIT_EVIDENCE_PREFIX="$EVIDENCE_PREFIX" \
  CODEXKIT_SOAK_SECONDS="$SOAK_SECONDS" \
  CODEXKIT_SOAK_SESSIONS="$SOAK_SESSIONS" \
  CODEXKIT_SOAK_TURNS="$SOAK_TURNS" \
  CODEXKIT_SOAK_MODEL="$SOAK_MODEL" \
  CODEXKIT_SOAK_LIVE_EFFECTIVE="$SOAK_LIVE" \
  CODEXKIT_SOAK_LIVE_SECONDS="${CODEXKIT_SOAK_LIVE_SECONDS:-60}" \
  CODEXKIT_SOAK_LIVE_SESSIONS="${CODEXKIT_SOAK_LIVE_SESSIONS:-2}" \
  CODEXKIT_SOAK_LIVE_TURNS="${CODEXKIT_SOAK_LIVE_TURNS:-2}" \
  CODEXKIT_SOAK_LIVE_CODING="${CODEXKIT_SOAK_LIVE_CODING:-1}" \
  CODEXKIT_LIVE_CODING_SESSIONS="${CODEXKIT_LIVE_CODING_SESSIONS:-2}" \
  CODEXKIT_LIVE_CODING_TURNS="${CODEXKIT_LIVE_CODING_TURNS:-3}" \
  python3 - <<'PY'
import json, os, platform, subprocess
from datetime import datetime, timezone
from pathlib import Path

def read_json(path):
    p = Path(path)
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))

def sw_vers():
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}

def hardware_uuid():
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

prefix = os.environ["CODEXKIT_EVIDENCE_PREFIX"]
files = {
    "boundedPrimitives": f"{prefix}.bounded-primitives.json",
    "mock": f"{prefix}.mock.json",
    "live": f"{prefix}.live.json",
    "liveCoding": f"{prefix}.live-coding.json",
}
payload = {
    "gate": "g6_soak",
    "result": "passed",
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "host": {
        "uname": platform.platform(),
        "sw_vers": sw_vers(),
        "hardwareUUID": hardware_uuid(),
    },
    "configuration": {
        "mockSeconds": int(os.environ["CODEXKIT_SOAK_SECONDS"]),
        "mockSessions": int(os.environ["CODEXKIT_SOAK_SESSIONS"]),
        "mockTurns": int(os.environ["CODEXKIT_SOAK_TURNS"]),
        "model": os.environ["CODEXKIT_SOAK_MODEL"],
        "liveEnabled": os.environ["CODEXKIT_SOAK_LIVE_EFFECTIVE"] == "1",
        "liveCodingEnabled": os.environ["CODEXKIT_SOAK_LIVE_CODING"] == "1",
        "liveSeconds": int(os.environ["CODEXKIT_SOAK_LIVE_SECONDS"]),
        "liveSessions": int(os.environ["CODEXKIT_SOAK_LIVE_SESSIONS"]),
        "liveTurns": int(os.environ["CODEXKIT_SOAK_LIVE_TURNS"]),
        "liveCodingSessions": int(os.environ["CODEXKIT_LIVE_CODING_SESSIONS"]),
        "liveCodingTurns": int(os.environ["CODEXKIT_LIVE_CODING_TURNS"]),
    },
    "files": files,
    "boundedPrimitives": read_json(files["boundedPrimitives"]),
    "mock": read_json(files["mock"]),
    "live": read_json(files["live"]),
    "liveCoding": read_json(files["liveCoding"]),
}
assert payload["boundedPrimitives"] is not None, "bounded-primitives evidence missing"
assert payload["boundedPrimitives"].get("gate") == "bounded_primitives_probe", payload["boundedPrimitives"]
assert payload["boundedPrimitives"].get("result") == "passed", payload["boundedPrimitives"]
bounded_assertions = payload["boundedPrimitives"].get("assertions") or {}
for key in (
    "allTestsPassed",
    "boundedChannelBlockingStorm",
    "boundedChannelRejectNewestStorm",
    "coalescingRingFlood",
    "overwriteRingConcurrentPush",
    "headTailBufferAdversarialSizes",
):
    assert bounded_assertions.get(key) is True, {"key": key, "boundedPrimitives": payload["boundedPrimitives"]}
assert payload["mock"] is not None, "mock soak evidence missing"
expected_mock_turns = payload["configuration"]["mockSessions"] * payload["configuration"]["mockTurns"]
assert payload["mock"]["turnsCompleted"] >= expected_mock_turns, payload["mock"]
assert payload["mock"]["elapsedSeconds"] >= payload["configuration"]["mockSeconds"], payload["mock"]
mock_sessions = payload["mock"].get("sessionDetails") or []
assert len(mock_sessions) >= payload["configuration"]["mockSessions"], payload["mock"]
for field in ("threadId", "workspace"):
    values = [s.get(field) for s in mock_sessions]
    assert all(isinstance(v, str) and v for v in values), {"phase": "mock", "field": field, "sessions": mock_sessions}
    assert len(set(values)) == len(values), {"phase": "mock", "field": field, "values": values}
assert all(s.get("turnsCompleted", 0) >= payload["configuration"]["mockTurns"] for s in mock_sessions), mock_sessions
broker_probe = payload["mock"].get("brokerStatsProbe") or {}
assert broker_probe.get("enabled") is True, payload["mock"]
assert broker_probe.get("responses", 0) >= 2, broker_probe
assert broker_probe.get("residentAfterClientEOF") is True, broker_probe
assert broker_probe.get("authStoreModeOctal") == "0o600", broker_probe
broker_stats = broker_probe.get("stats") or {}
expected_coalesced = broker_probe.get("stormRequests", 0) - 1
assert broker_stats.get("authRefreshes") == 1, broker_probe
assert broker_stats.get("authCoalesced", 0) >= expected_coalesced, broker_probe
if payload["configuration"]["liveEnabled"]:
    assert payload["live"] is not None, "live soak evidence missing"
    expected_live_turns = payload["configuration"]["liveSessions"] * payload["configuration"]["liveTurns"]
    assert payload["live"]["turnsCompleted"] >= expected_live_turns, payload["live"]
    assert payload["live"]["elapsedSeconds"] >= payload["configuration"]["liveSeconds"], payload["live"]
    live_sessions = payload["live"].get("sessionDetails") or []
    assert len(live_sessions) >= payload["configuration"]["liveSessions"], payload["live"]
    for field in ("threadId", "workspace"):
        values = [s.get(field) for s in live_sessions]
        assert all(isinstance(v, str) and v for v in values), {"phase": "live", "field": field, "sessions": live_sessions}
        assert len(set(values)) == len(values), {"phase": "live", "field": field, "values": values}
    assert all(s.get("turnsCompleted", 0) >= payload["configuration"]["liveTurns"] for s in live_sessions), live_sessions
if payload["configuration"]["liveEnabled"] and payload["configuration"]["liveCodingEnabled"]:
    assert payload["liveCoding"] is not None, "live coding evidence missing"
    assert payload["liveCoding"]["freshCodexdResumeVerified"] is True, payload["liveCoding"]
    assert payload["liveCoding"].get("debugRepairVerified") is True, payload["liveCoding"]
    assert payload["liveCoding"]["turnsPerSession"] >= payload["configuration"]["liveCodingTurns"], payload["liveCoding"]
    sessions = payload["liveCoding"]["sessions"]
    assert len(sessions) >= payload["configuration"]["liveCodingSessions"], payload["liveCoding"]
    for field in ("threadId", "workspace", "tag"):
        values = [s.get(field) for s in sessions]
        assert all(isinstance(v, str) and v for v in values), {"field": field, "sessions": sessions}
        assert len(set(values)) == len(values), {"field": field, "values": values}
    expected_tools = payload["configuration"]["liveCodingSessions"] * payload["configuration"]["liveCodingTurns"]
    assert payload["liveCoding"]["toolCompletionEventsObserved"] >= expected_tools, payload["liveCoding"]
    assert all(s.get("resumedAfterCodexdRestart") for s in sessions), payload["liveCoding"]
    assert all(s.get("rolloutCompletedTurns", 0) >= payload["configuration"]["liveCodingTurns"] for s in sessions), payload["liveCoding"]
    assert all(s.get("toolCompletionEventsObserved", 0) >= payload["configuration"]["liveCodingTurns"] for s in sessions), payload["liveCoding"]
    assert all(s.get("debugRepairVerified") for s in sessions), payload["liveCoding"]
    assert all((s.get("debugTrace") or {}).get("bugReturncode", 0) != 0 for s in sessions), payload["liveCoding"]
    assert all((s.get("debugTrace") or {}).get("fixedReturncode") == 0 for s in sessions), payload["liveCoding"]
    expected_turn = min(payload["configuration"]["liveCodingTurns"], 3)
    assert all((s.get("debugTrace") or {}).get("marker") == f"{s.get('tag')}_TURN{expected_turn}_OK" for s in sessions), payload["liveCoding"]
manifest = f"{prefix}.manifest.json"
Path(manifest).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={manifest}")
PY
}

gate_start "Run bounded queue/ring saturation probe"
bounded_evidence="$(evidence_arg bounded-primitives)"
bounded_args=()
if [[ -n "$bounded_evidence" ]]; then bounded_args=(--evidence-file "$bounded_evidence"); fi
run python3 tools/e2e/bounded_primitives_probe.py "${bounded_args[@]}"

gate_start "Run mock soak/noisy-neighbor pass"
mock_evidence="$(evidence_arg mock)"
mock_args=()
if [[ -n "$mock_evidence" ]]; then mock_args=(--evidence-file "$mock_evidence"); fi
run python3 tools/e2e/soak_driver.py \
  --mode mock \
  --seconds "$SOAK_SECONDS" \
  --sessions "$SOAK_SESSIONS" \
  --turns "$SOAK_TURNS" \
  --model "$SOAK_MODEL" \
  "${mock_args[@]}"

if [[ "$SOAK_LIVE" == "1" ]]; then
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "SKIP: CODEXKIT_SOAK_LIVE=1 but OPENAI_API_KEY is not set"
  else
    gate_start "Run live multi-session coding soak pass"
    live_evidence="$(evidence_arg live)"
    live_args=()
    if [[ -n "$live_evidence" ]]; then live_args=(--evidence-file "$live_evidence"); fi
    run python3 tools/e2e/soak_driver.py \
      --mode live \
      --seconds "${CODEXKIT_SOAK_LIVE_SECONDS:-60}" \
      --sessions "${CODEXKIT_SOAK_LIVE_SESSIONS:-2}" \
      --turns "${CODEXKIT_SOAK_LIVE_TURNS:-2}" \
      --model "$SOAK_MODEL" \
      --no-quiet-slo \
      "${live_args[@]}"
    if [[ "${CODEXKIT_SOAK_LIVE_CODING:-1}" == "1" ]]; then
      gate_start "Run release-binary live multi-session coding verification"
      live_coding_evidence="$(evidence_arg live-coding)"
      live_coding_args=()
      if [[ -n "$live_coding_evidence" ]]; then live_coding_args=(--evidence-file "$live_coding_evidence"); fi
      run python3 tools/e2e/live_coding_driver.py \
        --sessions "${CODEXKIT_LIVE_CODING_SESSIONS:-2}" \
        --turns "${CODEXKIT_LIVE_CODING_TURNS:-3}" \
        --model "$SOAK_MODEL" \
        "${live_coding_args[@]}"
    fi
  fi
fi

write_manifest

echo
echo "g6_soak OK"
