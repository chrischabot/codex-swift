#!/usr/bin/env bash
# Render and stage macOS lifecycle artifacts for CodexKit.
#
# This script is intentionally side-effect-light for `render` and `stage-install`:
# those actions write artifacts into caller-provided directories and do not call
# launchctl, codesign, or notarytool. The `install`, `status`, and `uninstall`
# actions are the explicit host-mutating lifecycle surface.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-render}"
shift || true

OUT_DIR=""
DESTDIR=""
INSTALL_ROOT="/Library/Application Support/CodexKit"
CODEX_HOME="${HOME:-}/.codex"
LABEL_PREFIX="ai.igent.codexkit"
LISTEN_URL="unix://"
BUILD_DIR="$ROOT/.build/debug"
RUNTIME_ROOT="$INSTALL_ROOT"
MOCK_MODEL=0
MOCK_SLOW_MS=""
LAUNCH_AGENTS_DIR="${HOME:-}/Library/LaunchAgents"
LAUNCH_DOMAIN="gui/$(id -u)"
BOOTSTRAP=1
REMOVE_FILES=1
TEMP_OUT=""
RELEASE_ID=""
PURGE_CODEX_HOME=0

usage() {
  cat <<'EOF'
Usage:
  scripts/codexkit-lifecycle.sh render --output DIR [options]
  scripts/codexkit-lifecycle.sh stage-install --destdir DIR [options]
  scripts/codexkit-lifecycle.sh stage-release --release ID [options]
  scripts/codexkit-lifecycle.sh promote-worker --release ID [options]
  scripts/codexkit-lifecycle.sh install [options]
  scripts/codexkit-lifecycle.sh status [options]
  scripts/codexkit-lifecycle.sh uninstall [options]

Options:
  --output DIR        Output directory for render mode.
  --destdir DIR       Staging root for stage-install mode.
  --install-root DIR  Runtime install root inside the target filesystem.
  --launch-agents-dir DIR
                      Directory for installed LaunchAgent plists.
  --launch-domain ID  launchctl domain, default gui/$(id -u).
  --codex-home DIR    CODEX_HOME used by generated launchd plists.
  --label-prefix ID   Launchd label prefix.
  --listen URL        codexd listen URL.
  --build-dir DIR     Directory containing codexd/codex-broker/codex-session.
  --release ID        Versioned release id for stage-release, promote-worker,
                      or versioned install/stage-install layout.
  --mock-model        Set CODEXKIT_MOCK=1 in rendered plists for smoke tests.
  --mock-slow-ms N    With --mock-model, slow each mock model turn by N ms.
  --no-bootstrap      Do not launchctl bootstrap during install.
  --keep-files        During uninstall, bootout only; keep files/plists.
  --purge-codex-home  During uninstall, also remove the explicit --codex-home.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUT_DIR="$2"; shift 2 ;;
    --destdir) DESTDIR="$2"; shift 2 ;;
    --install-root) INSTALL_ROOT="$2"; shift 2 ;;
    --launch-agents-dir) LAUNCH_AGENTS_DIR="$2"; shift 2 ;;
    --launch-domain) LAUNCH_DOMAIN="$2"; shift 2 ;;
    --codex-home) CODEX_HOME="$2"; shift 2 ;;
    --label-prefix) LABEL_PREFIX="$2"; shift 2 ;;
    --listen) LISTEN_URL="$2"; shift 2 ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --release) RELEASE_ID="$2"; shift 2 ;;
    --mock-model) MOCK_MODEL=1; shift ;;
    --mock-slow-ms) MOCK_SLOW_MS="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP=0; shift ;;
    --keep-files) REMOVE_FILES=0; shift ;;
    --purge-codex-home) PURGE_CODEX_HOME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

case "$ACTION" in
  render)
    if [[ -z "$OUT_DIR" ]]; then echo "--output is required" >&2; exit 64; fi
    ;;
  stage-install)
    if [[ -z "$DESTDIR" ]]; then echo "--destdir is required" >&2; exit 64; fi
    OUT_DIR="$DESTDIR"
    ;;
  stage-release)
    if [[ -z "$RELEASE_ID" ]]; then echo "--release is required" >&2; exit 64; fi
    TEMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/codexkit-stage-release.XXXXXX")"
    OUT_DIR="$TEMP_OUT"
    ;;
  promote-worker)
    if [[ -z "$RELEASE_ID" ]]; then echo "--release is required" >&2; exit 64; fi
    TEMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/codexkit-promote-worker.XXXXXX")"
    OUT_DIR="$TEMP_OUT"
    ;;
  install)
    TEMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/codexkit-install.XXXXXX")"
    OUT_DIR="$TEMP_OUT"
    ;;
  status|uninstall)
    OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexkit-lifecycle.XXXXXX")"
    TEMP_OUT="$OUT_DIR"
    ;;
  *)
    echo "unknown action: $ACTION" >&2
    usage >&2
    exit 64
    ;;
esac

cleanup() {
  if [[ -n "$TEMP_OUT" ]]; then
    rm -rf "$TEMP_OUT"
  fi
}
trap cleanup EXIT

mkdir -p "$OUT_DIR/LaunchAgents" "$OUT_DIR/entitlements" "$OUT_DIR/runbooks"

plist_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<<"$1"
}

render_launch_agent() {
  local name="$1"
  local program="$2"
  local stdout="$3"
  local stderr="$4"
  shift 4
  local args=("$@")
  local plist="$OUT_DIR/LaunchAgents/${LABEL_PREFIX}.${name}.plist"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(plist_escape "${LABEL_PREFIX}.${name}")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(plist_escape "$program")</string>
EOF
    if ((${#args[@]})); then
      for arg in "${args[@]}"; do
        printf '    <string>%s</string>\n' "$(plist_escape "$arg")"
      done
    fi
    cat <<EOF
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_HOME</key>
    <string>$(plist_escape "$CODEX_HOME")</string>
    <key>CODEX_BROKER_AUTH_STORE</key>
    <string>$(plist_escape "$CODEX_HOME/broker-auth.json")</string>
    <key>CODEXKIT_SESSION_BIN</key>
    <string>$(plist_escape "$RUNTIME_ROOT/bin/codex-session")</string>
EOF
    if [[ "$MOCK_MODEL" == "1" ]]; then
      cat <<EOF
    <key>CODEXKIT_MOCK</key>
    <string>1</string>
EOF
      if [[ -n "$MOCK_SLOW_MS" ]]; then
        cat <<EOF
    <key>CODEXKIT_MOCK_SLOW_MS</key>
    <string>$(plist_escape "$MOCK_SLOW_MS")</string>
EOF
      fi
    fi
    cat <<EOF
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$(plist_escape "$stdout")</string>
  <key>StandardErrorPath</key>
  <string>$(plist_escape "$stderr")</string>
</dict>
</plist>
EOF
  } > "$plist"
}

render_entitlements() {
  local name="$1"
  local outfile="$OUT_DIR/entitlements/${name}.entitlements"
  cat > "$outfile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.network.server</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <false/>
</dict>
</plist>
EOF
}

render_operations_runbook() {
  local outfile="$OUT_DIR/runbooks/operations.md"
  local codexd_label="${LABEL_PREFIX}.codexd"
  local broker_label="${LABEL_PREFIX}.codex-broker"
  local codexd_plist="$LAUNCH_AGENTS_DIR/${codexd_label}.plist"
  local broker_plist="$LAUNCH_AGENTS_DIR/${broker_label}.plist"
  local broker_socket="$CODEX_HOME/broker.sock"
  local app_socket="$CODEX_HOME/app-server-control/app-server-control.sock"
  cat > "$outfile" <<EOF
# CodexKit Operations Runbook

This runbook is generated from the same inputs as the LaunchAgents. Do not use
generic labels or paths when operating this install.

## Install Shape

- Install root: \`${INSTALL_ROOT}\`
- Runtime root for rendered plists: \`${RUNTIME_ROOT}\`
- CODEX_HOME: \`${CODEX_HOME}\`
- codexd label: \`${codexd_label}\`
- broker label: \`${broker_label}\`
- launchctl domain: \`${LAUNCH_DOMAIN}\`
- LaunchAgents directory: \`${LAUNCH_AGENTS_DIR}\`
- codexd listen URL: \`${LISTEN_URL}\`
- codexd UDS socket: \`${app_socket}\`
- broker UDS socket: \`${broker_socket}\`
- auth store: \`${CODEX_HOME}/broker-auth.json\`
- session worker binary: \`${RUNTIME_ROOT}/bin/codex-session\`

## Status And Logs

\`\`\`sh
scripts/codexkit-lifecycle.sh status --install-root "${INSTALL_ROOT}" --launch-agents-dir "${LAUNCH_AGENTS_DIR}" --codex-home "${CODEX_HOME}" --label-prefix "${LABEL_PREFIX}" --launch-domain "${LAUNCH_DOMAIN}"
launchctl print "${LAUNCH_DOMAIN}/${broker_label}"
launchctl print "${LAUNCH_DOMAIN}/${codexd_label}"
tail -n 200 "${INSTALL_ROOT}/logs/codex-broker.err.log"
tail -n 200 "${INSTALL_ROOT}/logs/codexd.err.log"
tail -n 200 "${INSTALL_ROOT}/logs/codex-broker.out.log"
tail -n 200 "${INSTALL_ROOT}/logs/codexd.out.log"
ls -la "${app_socket}" "${broker_socket}" "${CODEX_HOME}/broker-auth.json"
\`\`\`

Expected healthy shape: both labels are loaded, the broker socket exists, the
codexd control socket exists for UDS installs, and \`${CODEX_HOME}/broker-auth.json\`
is owned by the user with mode 0600.

## Restart Or Quarantine Recovery

\`\`\`sh
launchctl kickstart -k "${LAUNCH_DOMAIN}/${broker_label}"
launchctl kickstart -k "${LAUNCH_DOMAIN}/${codexd_label}"
launchctl bootout "${LAUNCH_DOMAIN}/${codexd_label}"
launchctl bootout "${LAUNCH_DOMAIN}/${broker_label}"
launchctl bootstrap "${LAUNCH_DOMAIN}" "${broker_plist}"
launchctl bootstrap "${LAUNCH_DOMAIN}" "${codexd_plist}"
\`\`\`

If poisoned or crashing workers are suspected, do not delete state first. Capture
the logs above, confirm \`CODEXKIT_SESSION_BIN=${RUNTIME_ROOT}/bin/codex-session\`
in \`${codexd_plist}\`, then kickstart codexd. A bad worker should fail one
session without taking down codexd or the broker; prove recovery with
\`tools/e2e/g6_poison_worker.sh\` before calling the incident closed.

## Update, Promote, And Roll Back

\`\`\`sh
swift build -c release
scripts/codexkit-lifecycle.sh stage-release --install-root "${INSTALL_ROOT}" --build-dir .build/release --release <new-release>
scripts/codexkit-lifecycle.sh promote-worker --install-root "${INSTALL_ROOT}" --release <new-release>
cat "${INSTALL_ROOT}/current-worker-release"
scripts/codexkit-lifecycle.sh promote-worker --install-root "${INSTALL_ROOT}" --release <previous-release>
cat "${INSTALL_ROOT}/current-worker-release"
tools/e2e/g6_blue_green.sh
\`\`\`

Rollback is the same \`promote-worker\` operation pointed at the previous release.
The \`${INSTALL_ROOT}/current-worker-release\` file is the operator-visible source
of truth for which worker new sessions will spawn. Existing quiet sessions should
continue while new sessions move to the promoted release.

## Evidence Collection

\`\`\`sh
export CODEXKIT_EVIDENCE_DIR=<evidence-dir>
tools/e2e/g6_lifecycle.sh
tools/e2e/g6_reboot_resume.sh
tools/e2e/g6_active_turn_crash.sh
tools/e2e/g6_poison_worker.sh
tools/e2e/g6_blue_green.sh
tools/e2e/g6_soak.sh
tools/e2e/g9_final_rehearsal.sh
python3 tools/e2e/verify_release_evidence.py --evidence-dir "\$CODEXKIT_EVIDENCE_DIR" --strict
\`\`\`

For strict release certification, also provide the live notary profile,
true-clean-machine attestation, true reboot evidence, enforced physical-footprint
evidence, and full-duration soak evidence required by the verifier. A local
rendered runbook is not evidence by itself; it is the operator contract for
collecting and recovering the real evidence.

## Uninstall

\`\`\`sh
scripts/codexkit-lifecycle.sh uninstall --install-root "${INSTALL_ROOT}" --launch-agents-dir "${LAUNCH_AGENTS_DIR}" --codex-home "${CODEX_HOME}" --label-prefix "${LABEL_PREFIX}" --launch-domain "${LAUNCH_DOMAIN}"
scripts/codexkit-lifecycle.sh uninstall --install-root "${INSTALL_ROOT}" --launch-agents-dir "${LAUNCH_AGENTS_DIR}" --codex-home "${CODEX_HOME}" --label-prefix "${LABEL_PREFIX}" --launch-domain "${LAUNCH_DOMAIN}" --purge-codex-home
\`\`\`

Use \`--purge-codex-home\` only for clean-machine certification or explicit user
data removal. The script refuses known unsafe roots, but operators must still
review \`--codex-home\` before purging.
EOF
}

target_root="$INSTALL_ROOT"
copy_binaries() {
  local root="$1"
  mkdir -p "$root/bin" "$root/logs"
  for bin in codexd codex-broker codex-session; do
    if [[ ! -x "$BUILD_DIR/$bin" ]]; then
      echo "missing built binary: $BUILD_DIR/$bin" >&2
      echo "run: swift build --product $bin" >&2
      exit 66
    fi
    cp "$BUILD_DIR/$bin" "$root/bin/$bin"
    chmod 0755 "$root/bin/$bin"
  done
}

validate_release_id() {
  local release="$1"
  case "$release" in
    ""|*/*|*..*|*:*|*[!A-Za-z0-9._-]*)
      echo "invalid release id: $release" >&2
      exit 64
      ;;
  esac
}

copy_release_binaries() {
  local root="$1"
  local release="$2"
  validate_release_id "$release"
  copy_binaries "$root/releases/$release"
}

link_current_release() {
  local root="$1"
  local release="$2"
  validate_release_id "$release"
  mkdir -p "$root/bin"
  for bin in codexd codex-broker codex-session; do
    ln -sfn "../releases/$release/bin/$bin" "$root/bin/$bin"
  done
  printf '%s\n' "$release" > "$root/current-release"
  printf '%s\n' "$release" > "$root/current-worker-release"
}

promote_worker_release() {
  local root="$1"
  local release="$2"
  validate_release_id "$release"
  local target="$root/releases/$release/bin/codex-session"
  if [[ ! -x "$target" ]]; then
    echo "missing release worker binary: $target" >&2
    exit 66
  fi
  mkdir -p "$root/bin"
  ln -sfn "../releases/$release/bin/codex-session" "$root/bin/codex-session"
  printf '%s\n' "$release" > "$root/current-worker-release"
  echo "promoted worker release $release at $root/bin/codex-session"
}

print_status() {
  local installed="no"
  if [[ -x "$INSTALL_ROOT/bin/codexd" \
        && -x "$INSTALL_ROOT/bin/codex-broker" \
        && -x "$INSTALL_ROOT/bin/codex-session" \
        && -f "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codexd.plist" \
        && -f "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codex-broker.plist" ]]; then
    installed="yes"
  fi
  echo "installed=$installed"
  for name in codex-broker codexd; do
    local label="${LABEL_PREFIX}.${name}"
    if command -v launchctl >/dev/null 2>&1 && launchctl print "$LAUNCH_DOMAIN/$label" >/dev/null 2>&1; then
      echo "$label=loaded"
    else
      echo "$label=not-loaded"
    fi
  done
}

if [[ "$ACTION" == "status" ]]; then
  print_status
  exit 0
fi

if [[ "$ACTION" == "uninstall" ]]; then
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "$LAUNCH_DOMAIN/${LABEL_PREFIX}.codexd" >/dev/null 2>&1 || true
    launchctl bootout "$LAUNCH_DOMAIN/${LABEL_PREFIX}.codex-broker" >/dev/null 2>&1 || true
  fi
  if [[ "$REMOVE_FILES" == "1" ]]; then
    rm -f "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codexd.plist"
    rm -f "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codex-broker.plist"
    rm -rf "$INSTALL_ROOT"
    if [[ "$PURGE_CODEX_HOME" == "1" ]]; then
      case "$CODEX_HOME" in
        ""|"/"|"$HOME"|"$HOME/"|"/Users"|"/Users/"|"/Library"|"/Library/"|"/System"|"/System/")
          echo "refusing to purge unsafe CODEX_HOME: $CODEX_HOME" >&2
          exit 64
          ;;
      esac
      rm -rf "$CODEX_HOME"
    fi
  fi
  echo "uninstalled ${LABEL_PREFIX}"
  exit 0
fi

if [[ "$ACTION" == "stage-release" ]]; then
  copy_release_binaries "$INSTALL_ROOT" "$RELEASE_ID"
  echo "staged release $RELEASE_ID to $INSTALL_ROOT/releases/$RELEASE_ID"
  exit 0
fi

if [[ "$ACTION" == "promote-worker" ]]; then
  promote_worker_release "$INSTALL_ROOT" "$RELEASE_ID"
  exit 0
fi

if [[ "$ACTION" == "stage-install" ]]; then
  if [[ -n "$RELEASE_ID" ]]; then
    copy_release_binaries "$DESTDIR$INSTALL_ROOT" "$RELEASE_ID"
    link_current_release "$DESTDIR$INSTALL_ROOT" "$RELEASE_ID"
  else
    copy_binaries "$DESTDIR$INSTALL_ROOT"
  fi
  target_root="$DESTDIR$INSTALL_ROOT"
elif [[ "$ACTION" == "install" ]]; then
  if [[ -n "$RELEASE_ID" ]]; then
    copy_release_binaries "$INSTALL_ROOT" "$RELEASE_ID"
    link_current_release "$INSTALL_ROOT" "$RELEASE_ID"
  else
    copy_binaries "$INSTALL_ROOT"
  fi
  target_root="$INSTALL_ROOT"
fi
RUNTIME_ROOT="$target_root"

render_launch_agent \
  "codexd" \
  "$target_root/bin/codexd" \
  "$target_root/logs/codexd.out.log" \
  "$target_root/logs/codexd.err.log" \
  "--listen" "$LISTEN_URL"

render_launch_agent \
  "codex-broker" \
  "$target_root/bin/codex-broker" \
  "$target_root/logs/codex-broker.out.log" \
  "$target_root/logs/codex-broker.err.log" \
  "--listen" "unix://$CODEX_HOME/broker.sock"

render_entitlements "codexd"
render_entitlements "codex-broker"
render_entitlements "codex-session"

cat > "$OUT_DIR/runbooks/sign-notarize.md" <<EOF
# CodexKit Signing And Lifecycle Runbook

1. Build release binaries: \`swift build -c release\`.
2. Stage artifacts: \`scripts/codexkit-lifecycle.sh stage-install --destdir <stage>\`.
3. Sign each binary with hardened runtime:
   \`codesign --force --options runtime --entitlements <stage>/entitlements/<name>.entitlements --sign "Developer ID Application: ..." <stage>${INSTALL_ROOT}/bin/<name>\`.
4. Package the staged tree with the rendered LaunchAgents.
5. Submit the package with \`xcrun notarytool submit --wait\`, staple on success, then validate Gatekeeper with \`spctl --assess --type install\`.
6. Install the LaunchAgents, run \`launchctl bootstrap gui/\$(id -u) <plist>\`, verify \`/readyz\`, then test reboot/resume.

The generated plists use KeepAlive, RunAtLoad, ThrottleInterval=5, CODEX_HOME,
CODEX_BROKER_AUTH_STORE, and CODEXKIT_SESSION_BIN so restart behavior is explicit
instead of hidden in shell wrappers.
EOF

render_operations_runbook

if [[ "$ACTION" == "install" ]]; then
  mkdir -p "$LAUNCH_AGENTS_DIR"
  cp "$OUT_DIR/LaunchAgents/${LABEL_PREFIX}.codexd.plist" "$LAUNCH_AGENTS_DIR/"
  cp "$OUT_DIR/LaunchAgents/${LABEL_PREFIX}.codex-broker.plist" "$LAUNCH_AGENTS_DIR/"
  if [[ "$BOOTSTRAP" == "1" ]]; then
    if ! command -v launchctl >/dev/null 2>&1; then
      echo "launchctl is required for install bootstrap; re-run with --no-bootstrap to only install files" >&2
      exit 69
    fi
    launchctl bootout "$LAUNCH_DOMAIN/${LABEL_PREFIX}.codexd" >/dev/null 2>&1 || true
    launchctl bootout "$LAUNCH_DOMAIN/${LABEL_PREFIX}.codex-broker" >/dev/null 2>&1 || true
    launchctl bootstrap "$LAUNCH_DOMAIN" "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codex-broker.plist"
    launchctl bootstrap "$LAUNCH_DOMAIN" "$LAUNCH_AGENTS_DIR/${LABEL_PREFIX}.codexd.plist"
  fi
  echo "installed ${LABEL_PREFIX} to $INSTALL_ROOT"
else
  echo "lifecycle artifacts written to $OUT_DIR"
fi
