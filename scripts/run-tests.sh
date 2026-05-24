#!/usr/bin/env bash
# Regression gate: build + full unit/integration/adversarial test suite.
# Usage: scripts/run-tests.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="debug"
[ "${1:-}" = "--release" ] && CONFIG="release"

echo "==> swift build (-c $CONFIG)"
swift build -c "$CONFIG"

echo "==> swift test"
swift test

echo "==> mock-responses self-test"
swift run mock-responses >/dev/null

echo "ALL GREEN"