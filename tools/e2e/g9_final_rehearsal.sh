#!/usr/bin/env bash
# Final release rehearsal entrypoint.
#
# Local mode composes the strongest executable evidence that can run on a
# developer Mac without external notary credentials or a clean VM. Strict mode
# (`CODEXKIT_FINAL_STRICT=1`) requires the external release inputs too: live
# OpenAI access, a saved notary profile, true clean-machine evidence, true
# reboot evidence, and 24 h / 50-session live soak settings.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_tool python3
require_tool rg

STRICT="${CODEXKIT_FINAL_STRICT:-0}"
OWN_EVIDENCE_DIR=0
if [[ -n "${CODEXKIT_EVIDENCE_DIR:-}" ]]; then
  EVIDENCE_DIR="$CODEXKIT_EVIDENCE_DIR"
else
  EVIDENCE_DIR="$(mktemp -d /tmp/codexkit-final-evidence.XXXXXX)"
  OWN_EVIDENCE_DIR=1
fi
mkdir -p "$EVIDENCE_DIR"
INITIAL_EVIDENCE_LIST="$EVIDENCE_DIR/.g9-initial-evidence-$$.txt"
find "$EVIDENCE_DIR" -maxdepth 1 -type f -name '*.json' -print | sort > "$INITIAL_EVIDENCE_LIST"
export CODEXKIT_EVIDENCE_DIR="$EVIDENCE_DIR"

finish() {
  rm -f "$INITIAL_EVIDENCE_LIST"
  if [[ "$OWN_EVIDENCE_DIR" == "1" ]]; then
    echo "evidence_dir=$EVIDENCE_DIR"
  fi
}
trap finish EXIT

strict_requirements() {
  [[ "$STRICT" == "1" ]] || return 0
  require_int_at_least() {
    local name="$1"
    local value="$2"
    local minimum="$3"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires $name to be an integer >=$minimum" >&2
      exit 1
    fi
    if (( value < minimum )); then
      echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires $name>=$minimum" >&2
      exit 1
    fi
  }
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires OPENAI_API_KEY" >&2
    exit 1
  fi
  if [[ -z "${CODEXKIT_NOTARY_PROFILE:-}" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires CODEXKIT_NOTARY_PROFILE" >&2
    exit 1
  fi
  if [[ "${CODEXKIT_TRUE_CLEAN_MACHINE:-0}" != "1" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires CODEXKIT_TRUE_CLEAN_MACHINE=1" >&2
    exit 1
  fi
  if [[ -z "${CODEXKIT_CLEAN_MACHINE_ATTESTATION:-}" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires CODEXKIT_CLEAN_MACHINE_ATTESTATION=<json>" >&2
    exit 1
  fi
  if [[ ! -f "${CODEXKIT_CLEAN_MACHINE_ATTESTATION:-}" ]]; then
    echo "FAIL: CODEXKIT_CLEAN_MACHINE_ATTESTATION does not exist: ${CODEXKIT_CLEAN_MACHINE_ATTESTATION:-}" >&2
    exit 1
  fi
  if [[ -z "${CODEXKIT_TRUE_REBOOT_EVIDENCE:-}" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires CODEXKIT_TRUE_REBOOT_EVIDENCE from g6_true_reboot_resume.sh verify" >&2
    exit 1
  fi
  if [[ ! -f "${CODEXKIT_TRUE_REBOOT_EVIDENCE:-}" ]]; then
    echo "FAIL: CODEXKIT_TRUE_REBOOT_EVIDENCE does not exist: ${CODEXKIT_TRUE_REBOOT_EVIDENCE:-}" >&2
    exit 1
  fi
  require_int_at_least CODEXKIT_SOAK_SECONDS "${CODEXKIT_SOAK_SECONDS:-0}" 86400
  require_int_at_least CODEXKIT_SOAK_SESSIONS "${CODEXKIT_SOAK_SESSIONS:-0}" 50
  require_int_at_least CODEXKIT_SOAK_TURNS "${CODEXKIT_SOAK_TURNS:-0}" 1
  if [[ "${CODEXKIT_SOAK_LIVE:-auto}" == "0" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires live soak enabled" >&2
    exit 1
  fi
  require_int_at_least CODEXKIT_SOAK_LIVE_SECONDS "${CODEXKIT_SOAK_LIVE_SECONDS:-0}" 1
  require_int_at_least CODEXKIT_SOAK_LIVE_SESSIONS "${CODEXKIT_SOAK_LIVE_SESSIONS:-0}" 2
  require_int_at_least CODEXKIT_SOAK_LIVE_TURNS "${CODEXKIT_SOAK_LIVE_TURNS:-0}" 2
  if [[ "${CODEXKIT_SOAK_LIVE_CODING:-1}" == "0" ]]; then
    echo "FAIL: CODEXKIT_FINAL_STRICT=1 requires live coding soak enabled" >&2
    exit 1
  fi
  require_int_at_least CODEXKIT_LIVE_CODING_SESSIONS "${CODEXKIT_LIVE_CODING_SESSIONS:-0}" 2
  require_int_at_least CODEXKIT_LIVE_CODING_TURNS "${CODEXKIT_LIVE_CODING_TURNS:-0}" 3
  python3 tools/e2e/strict_release_readiness.py >&2
}

assert_true_clean_if_strict() {
  [[ "$STRICT" == "1" ]] || return 0
  python3 - "$EVIDENCE_DIR" "$CODEXKIT_CLEAN_MACHINE_ATTESTATION" <<'PY'
import json, shutil, sys
from datetime import datetime, timezone
from pathlib import Path

evidence_dir = Path(sys.argv[1])
attestation_src = Path(sys.argv[2])
docs = sorted(evidence_dir.glob("g6_clean_machine-*.json"))
assert docs, "clean-machine evidence missing"
payload = json.loads(docs[-1].read_text(encoding="utf-8"))
attestation_payload = json.loads(attestation_src.read_text(encoding="utf-8"))
assert payload["result"] == "passed", payload
assert payload["trueCleanMachine"] is True, payload
attestation = payload.get("cleanMachineAttestation")
assert isinstance(attestation, dict), payload
assert attestation == attestation_payload, {"embedded": attestation, "source": attestation_payload}
assert attestation.get("trueCleanMachine") is True, attestation
assert attestation.get("operator"), attestation
timestamp = str(attestation.get("timestamp") or "")
normalized = timestamp[:-1] + "+00:00" if timestamp.endswith("Z") else timestamp
parsed = datetime.fromisoformat(normalized)
assert parsed.tzinfo is not None and parsed.astimezone(timezone.utc).year >= 2024, attestation
assert all(attestation.get("assertions", {}).values()), attestation
assert all(payload["assertions"].values()), payload["assertions"]
assert set(attestation.get("assertions", {}).keys()) == set(payload["assertions"].keys()), {
    "embedded": attestation.get("assertions"),
    "evidence": payload["assertions"],
}
evidence_hw = (payload.get("host") or {}).get("hardwareUUID")
attested_hw = (attestation.get("host") or {}).get("hardwareUUID")
assert evidence_hw, payload
assert attested_hw, attestation
assert evidence_hw == attested_hw, {"evidence": evidence_hw, "attestation": attested_hw}
dst = evidence_dir / f"g6_clean_machine_attestation-{attestation_src.name}"
if attestation_src.resolve() != dst.resolve():
    shutil.copy2(attestation_src, dst)
PY
}

assert_true_reboot_if_strict() {
  [[ "$STRICT" == "1" ]] || return 0
  python3 - "$CODEXKIT_TRUE_REBOOT_EVIDENCE" "$EVIDENCE_DIR" <<'PY'
import json, shutil, sys
from datetime import datetime, timezone
from pathlib import Path

src = Path(sys.argv[1])
evidence_dir = Path(sys.argv[2])
payload = json.loads(src.read_text(encoding="utf-8"))
assert payload["gate"] == "g6_true_reboot_resume", payload
assert payload["result"] == "passed", payload
assert payload["phase"] == "verified", payload
assert payload["trueOSReboot"] is True, payload
assert payload["boot"]["bootTimeChanged"] is True, payload["boot"]
assert payload["boot"]["verifyBootTimeAfterPrepare"] is True, payload["boot"]
assert payload["boot"]["verifyBootTimeSec"] > payload["boot"]["prepareBootTimeSec"], payload["boot"]
assert payload["boot"]["hardwareUUIDMatched"] is True, payload["boot"]
def parse_utc_timestamp(value):
    assert isinstance(value, str) and value, value
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    assert parsed.tzinfo is not None and parsed.astimezone(timezone.utc).year >= 2024, value
    return parsed.astimezone(timezone.utc)
prepared_at = parse_utc_timestamp(payload.get("preparedAt"))
verified_at = parse_utc_timestamp(payload.get("verifiedAt"))
assert verified_at > prepared_at, payload
assert prepared_at.timestamp() >= payload["boot"]["prepareBootTimeSec"], payload
assert verified_at.timestamp() >= payload["boot"]["verifyBootTimeSec"], payload
evidence_hw = (payload.get("host") or {}).get("hardwareUUID")
prepare_hw = payload["boot"].get("prepareHardwareUUID")
verify_hw = payload["boot"].get("verifyHardwareUUID")
assert evidence_hw, payload
assert prepare_hw, payload["boot"]
assert verify_hw, payload["boot"]
assert evidence_hw == prepare_hw == verify_hw, payload
assert payload["turnCountAfterResume"] >= 2, payload
dst = evidence_dir / src.name
if src.resolve() != dst.resolve():
    shutil.copy2(src, dst)
PY
}

assert_notary_if_strict() {
  [[ "$STRICT" == "1" ]] || return 0
  python3 - "$EVIDENCE_DIR" <<'PY'
import json, sys
from pathlib import Path

evidence_dir = Path(sys.argv[1])
docs = sorted(evidence_dir.glob("g6_developer_id_sign_smoke-*.json"))
assert docs, "Developer ID evidence missing"
payload = json.loads(docs[-1].read_text(encoding="utf-8"))
assert payload["notaryProfileConfigured"] is True, payload
assert payload["dmg"]["gatekeeperAccepted"] is True, payload["dmg"]
PY
}

assert_no_openai_key_in_evidence() {
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ "${#OPENAI_API_KEY}" -lt 12 ]]; then
    return 0
  fi
  if rg -F --quiet "$OPENAI_API_KEY" "$EVIDENCE_DIR"; then
    echo "FAIL: OPENAI_API_KEY value appeared in final rehearsal evidence" >&2
    exit 1
  fi
}

write_manifest() {
  python3 tools/e2e/write_final_rehearsal_manifest.py "$EVIDENCE_DIR" "$STRICT" "$INITIAL_EVIDENCE_LIST"
}

strict_requirements

gate_start "Release build"
run swift build -c release

gate_start "Signed artifact and Gatekeeper evidence"
run tools/e2e/g6_developer_id_sign_smoke.sh
assert_notary_if_strict

gate_start "Keychain token storage"
swift_filter "AuthTests/testKeychainTokenStoreRoundTripAndClear"

gate_start "Clean install / first turn / purge uninstall"
run tools/e2e/g6_clean_machine.sh
assert_true_clean_if_strict

gate_start "Durable resume after service restart"
run tools/e2e/g6_reboot_resume.sh
assert_true_reboot_if_strict

gate_start "Blue/green worker promotion and rollback"
run tools/e2e/g6_blue_green.sh

gate_start "Transport smokes"
run scripts/codexd-stdio-smoke.sh
run scripts/codexd-uds-smoke.sh
run scripts/codexd-ws-smoke.sh
run scripts/codexd-stdio-live-smoke.sh

gate_start "Fault containment"
run tools/e2e/g6_fault.sh
run tools/e2e/g6_active_turn_crash.sh

gate_start "Physical-footprint enforcement evidence"
run_bash "CODEXKIT_FOOTPRINT_EXPECT_ENFORCED=$STRICT tools/e2e/g6_physical_footprint.sh"

gate_start "Soak / noisy-neighbor / live coding evidence"
run tools/e2e/g6_soak.sh

gate_start "Evidence secret scan and manifest"
assert_no_openai_key_in_evidence
write_manifest
verify_args=()
if [[ "$STRICT" == "1" ]]; then
  verify_args=(--strict)
fi
run python3 tools/e2e/verify_release_evidence.py "$EVIDENCE_DIR" "${verify_args[@]}"

echo
echo "g9_final_rehearsal OK"
