#!/usr/bin/env bash
# Developer ID release-signing gate.
#
# When a Developer ID Application identity is available, this script stages
# release artifacts, signs every executable with hardened runtime + generated
# entitlements, and verifies the signature metadata. If CODEXKIT_NOTARY_PROFILE
# is set, it also packages the staged tree as a signed DMG, submits it to
# notarytool, staples the ticket, and validates the stapled artifact with
# Gatekeeper. Without notarization credentials it proves Gatekeeper rejects the
# signed-only executables as unnotarized, so the missing release step is explicit.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "developer-id signing smoke requires macOS; skipping on $(uname -s)"
  exit 0
fi

require_tool codesign
require_tool hdiutil
require_tool security
require_tool spctl
require_tool xcrun
require_tool rg

EVIDENCE_DIR="${CODEXKIT_EVIDENCE_DIR:-}"
EVIDENCE_FILE=""
if [[ -n "$EVIDENCE_DIR" ]]; then
  mkdir -p "$EVIDENCE_DIR"
  EVIDENCE_FILE="$EVIDENCE_DIR/g6_developer_id_sign_smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
fi

write_skip_evidence() {
  local reason="$1"
  [[ -n "$EVIDENCE_FILE" ]] || return 0
  CODEXKIT_EVIDENCE_FILE="$EVIDENCE_FILE" \
  CODEXKIT_SKIP_REASON="$reason" \
  python3 - <<'PY'
import json, os, platform, subprocess
from pathlib import Path

def sw_vers():
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}

payload = {
    "gate": "g6_developer_id_sign_smoke",
    "result": "skipped",
    "skipReason": os.environ["CODEXKIT_SKIP_REASON"],
    "host": {"uname": platform.platform(), "sw_vers": sw_vers()},
}
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
}

identity="${CODEXKIT_DEVELOPER_ID_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' |
      head -n 1
  )"
fi

if [[ -z "$identity" ]]; then
  echo "SKIP: no Developer ID Application identity found"
  write_skip_evidence "no Developer ID Application identity found"
  exit 0
fi

gate_start "Build release binaries for Developer ID signing smoke"
run swift build -c release

WORK="$(mktemp -d /tmp/codexkit-devid.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$identity" > "$WORK/identity.txt"
printf '%s\n' "${CODEXKIT_NOTARY_PROFILE:-}" > "$WORK/notary-profile.txt"

gate_start "Stage lifecycle artifacts for Developer ID signing smoke"
run scripts/codexkit-lifecycle.sh stage-install \
  --destdir "$WORK/stage" \
  --build-dir .build/release \
  --codex-home "$WORK/home"

STAGED_ROOT="$WORK/stage/Library/Application Support/CodexKit"

for name in codexd codex-broker codex-session; do
  binary="$STAGED_ROOT/bin/$name"
  entitlements="$WORK/stage/entitlements/$name.entitlements"

  gate_start "Developer ID sign and verify $name"
  test -x "$binary"
  test -f "$entitlements"

  run codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" \
    --sign "$identity" \
    "$binary"
  run codesign --verify --strict --verbose=2 "$binary"

  display="$WORK/$name.codesign-display.txt"
  ent_dump="$WORK/$name.entitlements.txt"
  codesign -d --verbose=4 "$binary" >"$display" 2>&1
  codesign -d --entitlements :- "$binary" >"$ent_dump" 2>&1

  rg -q 'Authority=Developer ID Application:' "$display"
  rg -q 'TeamIdentifier=[A-Z0-9]+' "$display"
  rg -q 'flags=.*runtime' "$display"
  rg -q '<key>com.apple.security.network.client</key><true/>' "$ent_dump"
  rg -q '<key>com.apple.security.network.server</key><true/>' "$ent_dump"
  rg -q '<key>com.apple.security.cs.disable-library-validation</key><false/>' "$ent_dump"

  if [[ -z "${CODEXKIT_NOTARY_PROFILE:-}" ]]; then
    spctl_out="$WORK/$name.spctl.txt"
    set +e
    spctl --assess --type execute --verbose=4 "$binary" >"$spctl_out" 2>&1
    spctl_status=$?
    set -e
    printf '%s\n' "$spctl_status" > "$WORK/$name.spctl-status.txt"
    if [[ "$spctl_status" -eq 0 ]]; then
      echo "FAIL: Gatekeeper accepted non-notarized Developer ID binary $binary" >&2
      exit 1
    fi
    rg -q 'Unnotarized Developer ID' "$spctl_out"
  fi
done

DMG="$WORK/CodexKit.dmg"
gate_start "Create and sign Developer ID DMG"
run hdiutil create -volname CodexKit -srcfolder "$WORK/stage" -ov -format UDZO "$DMG"
run codesign --force --timestamp --sign "$identity" "$DMG"
run codesign --verify --strict --verbose=2 "$DMG"
codesign -d --verbose=4 "$DMG" >"$WORK/dmg.codesign-display.txt" 2>&1
shasum -a 256 "$DMG" > "$WORK/dmg.sha256.txt"

if [[ -n "${CODEXKIT_NOTARY_PROFILE:-}" ]]; then
  gate_start "Submit, staple, and validate notarized DMG"
  run xcrun notarytool submit "$DMG" --keychain-profile "$CODEXKIT_NOTARY_PROFILE" --wait | tee "$WORK/notarytool-submit.txt"
  run xcrun stapler staple "$DMG" | tee "$WORK/stapler-staple.txt"
  run xcrun stapler validate "$DMG" | tee "$WORK/stapler-validate.txt"
  run spctl --assess --type open --verbose=4 "$DMG" >"$WORK/dmg.spctl.txt" 2>&1
else
  echo "SKIP: CODEXKIT_NOTARY_PROFILE not set; notarization/stapling not run"
fi

if [[ -n "$EVIDENCE_FILE" ]]; then
  CODEXKIT_EVIDENCE_FILE="$EVIDENCE_FILE" \
  CODEXKIT_WORK="$WORK" \
  CODEXKIT_STAGED_ROOT="$STAGED_ROOT" \
  CODEXKIT_DMG="$DMG" \
  python3 - <<'PY'
import json, os, platform, re, subprocess
from pathlib import Path

def read(path):
    p = Path(path)
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""

def sw_vers():
    try:
        out = subprocess.check_output(["sw_vers"], text=True, stderr=subprocess.DEVNULL)
        return dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
    except Exception:
        return {}

def notary_status_accepted(value):
    return isinstance(value, str) and re.search(r"(?im)^\s*status\s*:\s*Accepted\s*$", value) is not None

def stapler_staple_succeeded(value):
    return isinstance(value, str) and re.search(r"(?im)^\s*The staple and validate action worked!?\s*$", value) is not None

def stapler_validate_succeeded(value):
    return isinstance(value, str) and re.search(r"(?im)^\s*The validate action worked!?\s*$", value) is not None

def gatekeeper_assessment_accepted(value):
    return isinstance(value, str) and re.search(r"(?im)^\s*.+:\s*accepted\s*$", value) is not None

def gatekeeper_source_notarized_developer_id(value):
    return isinstance(value, str) and re.search(r"(?im)^\s*source=Notarized Developer ID\s*$", value) is not None

work = Path(os.environ["CODEXKIT_WORK"])
notary_profile = read(work / "notary-profile.txt").strip()
binaries = {}
for name in ["codexd", "codex-broker", "codex-session"]:
    display = read(work / f"{name}.codesign-display.txt")
    entitlements = read(work / f"{name}.entitlements.txt")
    spctl_text = read(work / f"{name}.spctl.txt")
    spctl_status_text = read(work / f"{name}.spctl-status.txt").strip()
    team = None
    m = re.search(r"TeamIdentifier=([A-Z0-9]+)", display)
    if m:
        team = m.group(1)
    binaries[name] = {
        "path": str(Path(os.environ["CODEXKIT_STAGED_ROOT"]) / "bin" / name),
        "developerIdAuthority": "Authority=Developer ID Application:" in display,
        "teamIdentifier": team,
        "hardenedRuntime": bool(re.search(r"flags=.*runtime", display)),
        "entitlements": {
            "networkClient": "<key>com.apple.security.network.client</key><true/>" in entitlements,
            "networkServer": "<key>com.apple.security.network.server</key><true/>" in entitlements,
            "libraryValidationNotDisabled": "<key>com.apple.security.cs.disable-library-validation</key><false/>" in entitlements,
        },
        "signedOnlyGatekeeper": {
            "checked": not bool(notary_profile),
            "status": int(spctl_status_text) if spctl_status_text else None,
            "rejectedAsUnnotarized": "Unnotarized Developer ID" in spctl_text,
        },
    }
dmg_spctl = read(work / "dmg.spctl.txt")
notary_ran = bool(notary_profile)
gatekeeper_accepted = bool(
    notary_ran
    and gatekeeper_assessment_accepted(dmg_spctl)
    and gatekeeper_source_notarized_developer_id(dmg_spctl)
)
payload = {
    "gate": "g6_developer_id_sign_smoke",
    "result": "passed",
    "host": {"uname": platform.platform(), "sw_vers": sw_vers()},
    "identity": read(work / "identity.txt").strip(),
    "notaryProfileConfigured": notary_ran,
    "stagedRoot": os.environ["CODEXKIT_STAGED_ROOT"],
    "dmg": {
        "path": os.environ["CODEXKIT_DMG"],
        "sha256": read(work / "dmg.sha256.txt").split()[0] if read(work / "dmg.sha256.txt").split() else None,
        "developerIdSigned": "Authority=Developer ID Application:" in read(work / "dmg.codesign-display.txt"),
        "notarytoolSubmitOutput": read(work / "notarytool-submit.txt") if notary_ran else None,
        "staplerStapleOutput": read(work / "stapler-staple.txt") if notary_ran else None,
        "staplerValidateOutput": read(work / "stapler-validate.txt") if notary_ran else None,
        "gatekeeperAssessOutput": dmg_spctl if notary_ran else None,
        "gatekeeperAccepted": gatekeeper_accepted,
    },
    "binaries": binaries,
}
assert all(v["developerIdAuthority"] for v in binaries.values()), binaries
assert all(v["teamIdentifier"] for v in binaries.values()), binaries
assert all(v["hardenedRuntime"] for v in binaries.values()), binaries
assert all(all(v["entitlements"].values()) for v in binaries.values()), binaries
if not notary_ran:
    assert all(v["signedOnlyGatekeeper"]["status"] not in (None, 0) for v in binaries.values()), binaries
    assert all(v["signedOnlyGatekeeper"]["rejectedAsUnnotarized"] for v in binaries.values()), binaries
else:
    assert payload["dmg"]["gatekeeperAccepted"], payload["dmg"]
    assert notary_status_accepted(payload["dmg"]["notarytoolSubmitOutput"]), payload["dmg"]
    assert stapler_staple_succeeded(payload["dmg"]["staplerStapleOutput"]), payload["dmg"]
    assert stapler_validate_succeeded(payload["dmg"]["staplerValidateOutput"]), payload["dmg"]
    assert gatekeeper_assessment_accepted(payload["dmg"]["gatekeeperAssessOutput"]), payload["dmg"]
    assert gatekeeper_source_notarized_developer_id(payload["dmg"]["gatekeeperAssessOutput"]), payload["dmg"]
Path(os.environ["CODEXKIT_EVIDENCE_FILE"]).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"evidence={os.environ['CODEXKIT_EVIDENCE_FILE']}")
PY
fi

echo
echo "g6_developer_id_sign_smoke OK"
