#!/usr/bin/env bash
# Local transport gate: wire/protocol contracts, socket server integration,
# daemon stdio, loopback WebSocket, and Unix-domain WebSocket smokes.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

gate_start "Wire, protocol, and socket transport tests"
swift_filter "WireProtocol|ProtocolModel|SocketServerTests|EndToEndTests|AuthGatingAdversarialTests"

gate_start "Deterministic stdio smoke"
run scripts/codexd-stdio-smoke.sh

gate_start "Loopback WebSocket smoke"
run scripts/codexd-ws-smoke.sh

gate_start "Unix-domain WebSocket smoke"
run scripts/codexd-uds-smoke.sh

gate_start "Stdio-to-UDS compatibility smoke"
run scripts/codexd-stdio-to-uds-smoke.sh

echo
echo "g1_transport OK"
