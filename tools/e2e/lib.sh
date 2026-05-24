#!/usr/bin/env bash
# Shared helpers for macOS completion gate scripts. Source this file; do not
# execute it directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

gate_start() {
  echo
  echo "==> $*"
}

run() {
  echo "+ $*"
  "$@"
}

run_bash() {
  echo "+ $*"
  bash -lc "$*"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL: required tool not found: $1" >&2
    exit 127
  fi
}

swift_filter() {
  local filter="$1"
  run swift test --filter "$filter"
}

swift_non_live() {
  run swift test --skip LiveTests --skip LiveDeepTests --skip LiveRealWorldTests
}

live_available() {
  [ -n "${OPENAI_API_KEY:-}" ]
}

swift_live_if_available() {
  if live_available; then
    gate_start "Live OpenAI suite"
    run swift test --filter Live
  else
    echo "SKIP: OPENAI_API_KEY not set (live Swift tests skipped)"
  fi
}

require_tool swift
