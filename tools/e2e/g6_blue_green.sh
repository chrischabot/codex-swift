#!/usr/bin/env bash
# Blue/green worker swap gate for spawned codex-session workers.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool python3

gate_start "Build release binaries for blue/green worker swap"
run swift build -c release

WORK="$(mktemp -d /tmp/codexkit-bluegreen.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
INSTALL_ROOT="$WORK/install"

make_generation_wrapper() {
  local release="$1"
  local worker="$INSTALL_ROOT/releases/$release/bin/codex-session"
  test -x "$worker"
  mv "$worker" "$worker.real"
  cat > "$worker" <<EOF
#!/usr/bin/env bash
echo 'codex-session generation=$release' >&2
exec '$worker.real' "\$@"
EOF
  chmod 0755 "$worker"
}

gate_start "Install blue release and stage green release"
run scripts/codexkit-lifecycle.sh install \
  --install-root "$INSTALL_ROOT" \
  --launch-agents-dir "$WORK/LaunchAgents" \
  --build-dir .build/release \
  --release blue \
  --no-bootstrap
make_generation_wrapper blue
run scripts/codexkit-lifecycle.sh stage-release \
  --install-root "$INSTALL_ROOT" \
  --build-dir .build/release \
  --release green
make_generation_wrapper green

test "$(readlink "$INSTALL_ROOT/bin/codex-session")" = "../releases/blue/bin/codex-session"

gate_start "Run lifecycle blue/green spawned-worker swap and rollback"
evidence_args=()
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$CODEXKIT_EVIDENCE_DIR"
  evidence_args=(--evidence-file "$CODEXKIT_EVIDENCE_DIR/g6_blue_green-$(date -u +%Y%m%dT%H%M%SZ)-$$.json")
fi
run python3 tools/e2e/blue_green_driver.py --install-root "$INSTALL_ROOT" "${evidence_args[@]}"
test "$(cat "$INSTALL_ROOT/current-worker-release")" = "blue"
test "$(readlink "$INSTALL_ROOT/bin/codex-session")" = "../releases/blue/bin/codex-session"

echo
echo "g6_blue_green OK"
