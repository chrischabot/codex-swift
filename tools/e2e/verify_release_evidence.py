#!/usr/bin/env python3
"""Verify macOS release evidence artifacts.

The E2E gates deliberately write machine-readable JSON so release readiness is
not inferred from scattered console output. This verifier audits an evidence
directory in either local mode or strict release mode:

* local mode proves the composed rehearsal evidence is internally consistent
  without claiming external release-only proofs.
* strict mode requires notarized/stapled Gatekeeper evidence, an explicitly
  marked clean-machine run, true reboot evidence, a 24h/50-session soak, live
  OpenAI evidence, and severe live-coding resume evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


Json = dict[str, Any]


class EvidenceError(AssertionError):
    pass


def load_json(path: Path) -> Json:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise EvidenceError(f"failed to read JSON {path}: {exc}") from exc


def latest(evidence_dir: Path, pattern: str, *, required: bool = True) -> tuple[Path, Json] | None:
    matches = sorted(evidence_dir.glob(pattern))
    if not matches:
        if required:
            raise EvidenceError(f"missing evidence matching {pattern} in {evidence_dir}")
        return None
    path = matches[-1]
    return path, load_json(path)


def require(condition: bool, message: str, payload: Any | None = None) -> None:
    if not condition:
        detail = "" if payload is None else f": {payload!r}"
        raise EvidenceError(message + detail)


def contains_ci(value: Any, needle: str) -> bool:
    return isinstance(value, str) and needle.lower() in value.lower()


def notary_status_accepted(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return re.search(r"(?im)^\s*status\s*:\s*Accepted\s*$", value) is not None


def stapler_staple_succeeded(value: Any) -> bool:
    return isinstance(value, str) and re.search(r"(?im)^\s*The staple and validate action worked!?\s*$", value) is not None


def stapler_validate_succeeded(value: Any) -> bool:
    return isinstance(value, str) and re.search(r"(?im)^\s*The validate action worked!?\s*$", value) is not None


def gatekeeper_assessment_accepted(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return re.search(r"(?im)^\s*.+:\s*accepted\s*$", value) is not None


def gatekeeper_source_notarized_developer_id(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return re.search(r"(?im)^\s*source=Notarized Developer ID\s*$", value) is not None


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def all_assertions_true(payload: Json, key: str) -> None:
    assertions = payload.get(key)
    require(isinstance(assertions, dict), f"{key} missing or not an object", payload)
    failed = {k: v for k, v in assertions.items() if v is not True}
    require(not failed, f"{key} contains failed assertions", failed)


def parse_utc_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    normalized = value
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    parsed = parsed.astimezone(timezone.utc)
    return parsed if parsed.year >= 2024 else None


def require_unique_string_field(items: list[Any], field: str, message: str) -> None:
    values = []
    for item in items:
        if not isinstance(item, dict):
            raise EvidenceError(f"{message}: session entry is not an object: {item!r}")
        value = item.get(field)
        require(isinstance(value, str) and value, f"{message}: missing {field}", item)
        values.append(value)
    require(len(set(values)) == len(values), f"{message}: duplicate {field}", values)


def verify_phase_session_details(phase: Json, *, expected_sessions: int, expected_turns: int, name: str) -> None:
    sessions = phase.get("sessionDetails")
    require(isinstance(sessions, list), f"{name} sessionDetails missing", phase)
    require(len(sessions) >= expected_sessions, f"{name} sessionDetails count too low", phase)
    require_unique_string_field(sessions, "threadId", f"{name} sessions are not independent")
    require_unique_string_field(sessions, "workspace", f"{name} sessions are not independent")
    for session in sessions:
        require(
            session.get("turnsCompleted", 0) >= expected_turns,
            f"{name} session turns too low",
            session,
        )
        require(
            session.get("deltaEvents", 0) > 0,
            f"{name} session missing streamed deltas",
            session,
        )


def live_coding_debug_marker_matches(session: Json, *, expected_turns: int) -> bool:
    tag = session.get("tag")
    debug_trace = session.get("debugTrace") or {}
    if not isinstance(tag, str) or not tag:
        return False
    if not isinstance(debug_trace, dict):
        return False
    expected_marker = f"{tag}_TURN{min(expected_turns, 3)}_OK"
    return debug_trace.get("marker") == expected_marker


def verify_developer_id(evidence_dir: Path, *, strict: bool) -> Json:
    _, payload = latest(evidence_dir, "g6_developer_id_sign_smoke-*.json")
    require(payload.get("gate") == "g6_developer_id_sign_smoke", "Developer ID evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "Developer ID evidence did not pass", payload)
    binaries = payload.get("binaries")
    require(isinstance(binaries, dict) and binaries, "Developer ID binary evidence missing", payload)
    for name, binary in binaries.items():
        require(binary.get("developerIdAuthority") is True, f"{name} missing Developer ID authority", binary)
        require(bool(binary.get("teamIdentifier")), f"{name} missing Team ID", binary)
        require(binary.get("hardenedRuntime") is True, f"{name} missing hardened runtime", binary)
        entitlements = binary.get("entitlements")
        require(isinstance(entitlements, dict), f"{name} missing entitlements", binary)
        require(all(entitlements.values()), f"{name} entitlement check failed", entitlements)
    dmg = payload.get("dmg")
    require(isinstance(dmg, dict), "DMG evidence missing", payload)
    require(
        isinstance(dmg.get("sha256"), str) and re.fullmatch(r"[0-9a-fA-F]{64}", dmg.get("sha256") or "") is not None,
        "DMG SHA-256 evidence missing or invalid",
        dmg,
    )
    require(dmg.get("developerIdSigned") is True, "DMG is not Developer ID signed", dmg)
    if strict:
        require(payload.get("notaryProfileConfigured") is True, "strict release requires notary profile", payload)
        require(dmg.get("gatekeeperAccepted") is True, "strict release requires stapled Gatekeeper acceptance", dmg)
        require(notary_status_accepted(dmg.get("notarytoolSubmitOutput")), "strict release notarytool output did not show exact Accepted status", dmg)
        require(stapler_staple_succeeded(dmg.get("staplerStapleOutput")), "strict release stapler staple output did not show exact success", dmg)
        require(stapler_validate_succeeded(dmg.get("staplerValidateOutput")), "strict release stapler validate output did not show exact success", dmg)
        require(gatekeeper_assessment_accepted(dmg.get("gatekeeperAssessOutput")), "strict release missing exact accepted Gatekeeper assessment output", dmg)
        require(
            gatekeeper_source_notarized_developer_id(dmg.get("gatekeeperAssessOutput")),
            "strict release Gatekeeper assessment did not show exact Notarized Developer ID source",
            dmg,
        )
    else:
        if payload.get("notaryProfileConfigured") is False:
            for name, binary in binaries.items():
                signed_only = binary.get("signedOnlyGatekeeper") or {}
                require(signed_only.get("checked") is True, f"{name} signed-only Gatekeeper check missing", binary)
                require(signed_only.get("status") not in (None, 0), f"{name} signed-only artifact was accepted", binary)
                require(
                    signed_only.get("rejectedAsUnnotarized") is True,
                    f"{name} signed-only artifact was not explicitly rejected as unnotarized",
                    binary,
                )
    return payload


def verify_clean_machine(evidence_dir: Path, *, strict: bool) -> Json:
    _, payload = latest(evidence_dir, "g6_clean_machine-*.json")
    require(payload.get("gate") == "g6_clean_machine", "clean-machine evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "clean-machine gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    require(bool(payload.get("threadId")), "clean-machine gate did not create a thread", payload)
    if strict:
        expected_assertions = {
            "firstThreadCreated",
            "spawnedWorkerLogged",
            "workerReadyLogged",
            "installRootRemoved",
            "launchAgentsPlistsRemoved",
            "codexHomePurged",
        }
        evidence_assertions = payload.get("assertions") or {}
        require(
            set(evidence_assertions.keys()) == expected_assertions,
            "clean-machine evidence assertion keys do not match required cleanup proof",
            {"expected": sorted(expected_assertions), "actual": sorted(evidence_assertions.keys())},
        )
        labels = payload.get("labels") or {}
        codexd_label = labels.get("codexd")
        broker_label = labels.get("broker")
        require(isinstance(codexd_label, str) and codexd_label, "clean-machine codexd label missing", payload)
        require(isinstance(broker_label, str) and broker_label, "clean-machine broker label missing", payload)
        status_loaded = payload.get("statusLoaded")
        status_uninstalled = payload.get("statusUninstalled")
        require(isinstance(status_loaded, str) and "installed=yes" in status_loaded, "clean-machine loaded status missing installed=yes", payload)
        require(f"{broker_label}=loaded" in status_loaded, "clean-machine loaded status missing broker loaded marker", payload)
        require(f"{codexd_label}=loaded" in status_loaded, "clean-machine loaded status missing codexd loaded marker", payload)
        require(isinstance(status_uninstalled, str) and "installed=no" in status_uninstalled, "clean-machine uninstalled status missing installed=no", payload)
        require(f"{broker_label}=not-loaded" in status_uninstalled, "clean-machine uninstalled status missing broker not-loaded marker", payload)
        require(f"{codexd_label}=not-loaded" in status_uninstalled, "clean-machine uninstalled status missing codexd not-loaded marker", payload)
        require(payload.get("trueCleanMachine") is True, "strict release requires trueCleanMachine evidence", payload)
        attestation = payload.get("cleanMachineAttestation")
        require(isinstance(attestation, dict), "strict release requires clean-machine attestation payload", payload)
        require(attestation.get("trueCleanMachine") is True, "clean-machine attestation did not assert trueCleanMachine", attestation)
        require(bool(attestation.get("operator")), "clean-machine attestation missing operator", attestation)
        require(parse_utc_timestamp(attestation.get("timestamp")) is not None, "clean-machine attestation timestamp is not a valid UTC ISO-8601 timestamp", attestation)
        assertions = attestation.get("assertions")
        require(isinstance(assertions, dict) and assertions, "clean-machine attestation assertions missing", attestation)
        require(
            all(v is True for v in assertions.values()),
            "clean-machine attestation contains failed assertions",
            assertions,
        )
        require(
            set(assertions.keys()) == set(evidence_assertions.keys()),
            "clean-machine attestation assertion keys do not match evidence assertions",
            {"evidence": evidence_assertions, "attestation": assertions},
        )
        evidence_hw = (payload.get("host") or {}).get("hardwareUUID")
        attested_hw = (attestation.get("host") or {}).get("hardwareUUID")
        require(bool(evidence_hw), "strict release requires evidence host hardware UUID", payload)
        require(bool(attested_hw), "clean-machine attestation missing host hardware UUID", attestation)
        require(evidence_hw == attested_hw, "clean-machine attestation hardware UUID mismatch", {
            "evidence": evidence_hw,
            "attestation": attested_hw,
        })
    return payload


def verify_clean_machine_attestation_artifact(evidence_dir: Path, clean: Json, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_clean_machine_attestation-*.json", required=strict)
    if found is None:
        return None
    path, payload = found
    embedded = clean.get("cleanMachineAttestation")
    require(isinstance(embedded, dict), "clean-machine evidence missing embedded attestation", clean)
    require(payload == embedded, "clean-machine attestation artifact does not match embedded evidence", {
        "path": str(path),
        "artifact": payload,
        "embedded": embedded,
    })
    return payload


def verify_reboot_resume(evidence_dir: Path, *, strict: bool) -> Json:
    _, payload = latest(evidence_dir, "g6_reboot_resume-*.json")
    require(payload.get("gate") == "g6_reboot_resume", "reboot-resume evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "reboot-resume gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "sameThreadResumed",
        "atLeastTwoTurnsAfterResume",
        "spawnedWorkerLogged",
        "workerReadyLogged",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "reboot-resume evidence assertion keys do not match required resume proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    labels = payload.get("labels") or {}
    codexd_label = labels.get("codexd")
    broker_label = labels.get("broker")
    require(isinstance(codexd_label, str) and codexd_label, "reboot-resume codexd label missing", payload)
    require(isinstance(broker_label, str) and broker_label, "reboot-resume broker label missing", payload)
    status_loaded = payload.get("statusLoaded")
    status_uninstalled = payload.get("statusUninstalled")
    require(isinstance(status_loaded, str) and "installed=yes" in status_loaded, "reboot-resume loaded status missing installed=yes", payload)
    require(f"{broker_label}=loaded" in status_loaded, "reboot-resume loaded status missing broker loaded marker", payload)
    require(f"{codexd_label}=loaded" in status_loaded, "reboot-resume loaded status missing codexd loaded marker", payload)
    require(isinstance(status_uninstalled, str) and "installed=no" in status_uninstalled, "reboot-resume uninstalled status missing installed=no", payload)
    require(f"{broker_label}=not-loaded" in status_uninstalled, "reboot-resume uninstalled status missing broker not-loaded marker", payload)
    require(f"{codexd_label}=not-loaded" in status_uninstalled, "reboot-resume uninstalled status missing codexd not-loaded marker", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "reboot-resume createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "reboot-resume host hardware UUID missing", payload)
    daemon = payload.get("daemonRestart") or {}
    require(daemon.get("pidChanged") is True, "daemon restart evidence did not show pid change", payload)
    require(bool(daemon.get("oldPid")) and bool(daemon.get("newPid")), "daemon restart evidence missing old/new pid", payload)
    require(str(daemon.get("oldPid")) != str(daemon.get("newPid")), "daemon restart evidence old/new pid did not change", payload)
    require((payload.get("turnCountAfterResume") or 0) >= 2, "resume turn count too low", payload)
    return payload


def verify_active_turn_crash(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_active_turn_crash-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_active_turn_crash", "active-turn crash evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "active-turn crash gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "sameThreadResumed",
        "activeTurnMarkedInterruptedOrInProgress",
        "laterTurnCompleted",
        "atLeastTwoTurnsAfterRecovery",
        "daemonPidChanged",
        "spawnedWorkerLogged",
        "workerReadyLogged",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "active-turn crash evidence assertion keys do not match required recovery proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    require(bool(payload.get("threadId")), "active-turn crash thread id missing", payload)
    labels = payload.get("labels") or {}
    codexd_label = labels.get("codexd")
    broker_label = labels.get("broker")
    require(isinstance(codexd_label, str) and codexd_label, "active-turn crash codexd label missing", payload)
    require(isinstance(broker_label, str) and broker_label, "active-turn crash broker label missing", payload)
    status_loaded = payload.get("statusLoaded")
    status_uninstalled = payload.get("statusUninstalled")
    require(isinstance(status_loaded, str) and "installed=yes" in status_loaded, "active-turn crash loaded status missing installed=yes", payload)
    require(f"{broker_label}=loaded" in status_loaded, "active-turn crash loaded status missing broker loaded marker", payload)
    require(f"{codexd_label}=loaded" in status_loaded, "active-turn crash loaded status missing codexd loaded marker", payload)
    require(isinstance(status_uninstalled, str) and "installed=no" in status_uninstalled, "active-turn crash uninstalled status missing installed=no", payload)
    require(f"{broker_label}=not-loaded" in status_uninstalled, "active-turn crash uninstalled status missing broker not-loaded marker", payload)
    require(f"{codexd_label}=not-loaded" in status_uninstalled, "active-turn crash uninstalled status missing codexd not-loaded marker", payload)
    daemon = payload.get("daemonRestart") or {}
    require(daemon.get("pidChanged") is True, "active-turn crash daemon restart did not show pid change", payload)
    require(bool(daemon.get("oldPid")) and bool(daemon.get("newPid")), "active-turn crash daemon restart missing old/new pid", payload)
    require(str(daemon.get("oldPid")) != str(daemon.get("newPid")), "active-turn crash daemon old/new pid did not change", payload)
    before = payload.get("turnStatusesBeforeRecovery")
    after = payload.get("turnStatusesAfterRecovery")
    require(isinstance(before, list) and before, "active-turn crash missing pre-recovery turn statuses", payload)
    require(isinstance(after, list) and after, "active-turn crash missing post-recovery turn statuses", payload)
    require(
        "interrupted" in before or "inProgress" in before,
        "active-turn crash did not capture interrupted/in-progress turn before recovery",
        payload,
    )
    require(
        "interrupted" in after or "inProgress" in after,
        "active-turn crash did not preserve interrupted/in-progress turn after recovery",
        payload,
    )
    require("completed" in after, "active-turn crash did not complete a later turn after recovery", payload)
    require((payload.get("turnCountAfterRecovery") or 0) >= 2, "active-turn crash turn count after recovery too low", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "active-turn crash createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "active-turn crash host hardware UUID missing", payload)
    return payload


def verify_poison_worker(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_poison_worker-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_poison_worker", "poison-worker evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "poison-worker gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "daemonSurvivedPoison",
        "quietSessionSurvivedPoison",
        "poisonWorkerLaunchedOnce",
        "poisonedTurnDidNotComplete",
        "healthyWorkerLaunchedBeforeAndAfterPoison",
        "recoveredSessionCompleted",
        "threadsAreDistinct",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "poison-worker evidence assertion keys do not match required containment proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    threads = payload.get("threads") or {}
    thread_ids = [threads.get("quiet"), threads.get("poisoned"), threads.get("recovered")]
    require(all(isinstance(tid, str) and tid for tid in thread_ids), "poison-worker thread ids missing", payload)
    require(len(set(thread_ids)) == 3, "poison-worker thread ids are not distinct", payload)
    completions = payload.get("completions") or {}
    require(completions.get("quiet", 0) >= 2, "poison-worker quiet session did not survive poison", payload)
    require(completions.get("poisoned", 0) == 0, "poison-worker poisoned turn unexpectedly completed", payload)
    require(completions.get("recovered", 0) >= 1, "poison-worker recovered session did not complete", payload)
    launches = payload.get("launches") or {}
    require(launches.get("healthy", 0) >= 2, "poison-worker healthy launch count too low", payload)
    require(launches.get("poison") == 1, "poison-worker poison launch count was not exactly one", payload)
    daemon = payload.get("daemon") or {}
    require(bool(daemon.get("pid")), "poison-worker daemon pid missing", payload)
    require(daemon.get("survivedPoison") is True, "poison-worker daemon did not survive poison", payload)
    poison_turn = payload.get("poisonTurn") or {}
    require(poison_turn.get("unexpectedCompletion") is not True, "poison-worker evidence reported unexpected poisoned completion", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "poison-worker createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "poison-worker host hardware UUID missing", payload)
    return payload


def verify_blue_green(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_blue_green-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_blue_green", "blue/green evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "blue/green gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "loadedBlueSessionSurvivedPromotion",
        "greenSessionUsedAfterPromotion",
        "rollbackSessionUsedBlue",
        "noExtraBlueRespawnDuringPromotion",
        "threadsAreDistinct",
        "daemonSurvivedPromotionAndRollback",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "blue/green evidence assertion keys do not match required promotion proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    threads = payload.get("threads") or {}
    thread_ids = [threads.get("blue"), threads.get("green"), threads.get("rollback")]
    require(all(isinstance(tid, str) and tid for tid in thread_ids), "blue/green thread ids missing", payload)
    require(len(set(thread_ids)) == 3, "blue/green thread ids are not distinct", payload)
    completions = payload.get("completions") or {}
    require(completions.get("blue", 0) >= 3, "blue/green loaded blue session did not survive promotion", payload)
    require(completions.get("green", 0) >= 1, "blue/green promoted green session did not complete", payload)
    require(completions.get("rollback", 0) >= 1, "blue/green rollback session did not complete", payload)
    launches = payload.get("launches") or {}
    require(launches.get("blue") == 2, "blue/green blue launch count did not prove initial plus rollback only", payload)
    require(launches.get("green") == 1, "blue/green green launch count did not prove one promoted worker", payload)
    daemon = payload.get("daemon") or {}
    require(bool(daemon.get("pid")), "blue/green daemon pid missing", payload)
    require(daemon.get("survivedPromotionAndRollback") is True, "blue/green daemon did not survive promotion and rollback", payload)
    paths = payload.get("paths") or {}
    require(bool(paths.get("installRoot")), "blue/green install root missing", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "blue/green createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "blue/green host hardware UUID missing", payload)
    return payload


def verify_launchd_smoke(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_launchd_smoke-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_launchd_smoke", "launchd smoke evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "launchd smoke gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "brokerRestarted",
        "codexdRestarted",
        "turnBeforeAndAfterRestartCompleted",
        "spawnedWorkerLogged",
        "workerReadyLogged",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "launchd smoke assertion keys do not match required restart proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    labels = payload.get("labels") or {}
    codexd_label = labels.get("codexd")
    broker_label = labels.get("broker")
    require(isinstance(codexd_label, str) and codexd_label, "launchd smoke codexd label missing", payload)
    require(isinstance(broker_label, str) and broker_label, "launchd smoke broker label missing", payload)
    status_loaded = payload.get("statusLoaded")
    status_uninstalled = payload.get("statusUninstalled")
    require(isinstance(status_loaded, str) and "installed=yes" in status_loaded, "launchd smoke loaded status missing installed=yes", payload)
    require(f"{broker_label}=loaded" in status_loaded, "launchd smoke loaded status missing broker loaded marker", payload)
    require(f"{codexd_label}=loaded" in status_loaded, "launchd smoke loaded status missing codexd loaded marker", payload)
    require(isinstance(status_uninstalled, str) and "installed=no" in status_uninstalled, "launchd smoke uninstalled status missing installed=no", payload)
    require(f"{broker_label}=not-loaded" in status_uninstalled, "launchd smoke uninstalled status missing broker not-loaded marker", payload)
    require(f"{codexd_label}=not-loaded" in status_uninstalled, "launchd smoke uninstalled status missing codexd not-loaded marker", payload)
    restart = payload.get("restart") or {}
    for name in ("broker", "codexd"):
        item = restart.get(name) or {}
        require(item.get("pidChanged") is True, f"launchd smoke {name} restart did not show pid change", payload)
        require(bool(item.get("oldPid")) and bool(item.get("newPid")), f"launchd smoke {name} restart missing old/new pid", payload)
        require(str(item.get("oldPid")) != str(item.get("newPid")), f"launchd smoke {name} old/new pid did not change", payload)
    require((payload.get("turnCount") or 0) >= 2, "launchd smoke did not complete turns before and after restart", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "launchd smoke createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "launchd smoke host hardware UUID missing", payload)
    return payload


def verify_fault(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_fault-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_fault", "fault evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "fault gate did not pass", payload)
    all_assertions_true(payload, "assertions")
    assertions = payload.get("assertions") or {}
    expected_assertions = {
        "hardeningSmokePassed",
        "hardeningSmokeEvidenceCaptured",
        "poisonWorkerEvidenceCaptured",
        "launchdSmokeEvidenceCaptured",
    }
    require(
        set(assertions.keys()) == expected_assertions,
        "fault evidence assertion keys do not match required aggregate proof",
        {"expected": sorted(expected_assertions), "actual": sorted(assertions.keys())},
    )
    components = payload.get("components") or {}
    for name in ("hardeningSmoke", "poisonWorker", "launchdSmoke"):
        component = components.get(name) or {}
        require(component.get("result") == "passed", f"fault component {name} did not pass", payload)
    hardening_file = (components.get("hardeningSmoke") or {}).get("evidenceFile")
    poison_file = (components.get("poisonWorker") or {}).get("evidenceFile")
    launchd_file = (components.get("launchdSmoke") or {}).get("evidenceFile")
    require(isinstance(hardening_file, str) and hardening_file, "fault evidence missing hardening-smoke child artifact", payload)
    require(isinstance(poison_file, str) and poison_file, "fault evidence missing poison-worker child artifact", payload)
    require(isinstance(launchd_file, str) and launchd_file, "fault evidence missing launchd-smoke child artifact", payload)
    hardening_path = resolve_evidence_file(evidence_dir, hardening_file, "fault hardening-smoke child evidence path invalid")
    poison_path = resolve_evidence_file(evidence_dir, poison_file, "fault poison-worker child evidence path invalid")
    launchd_path = resolve_evidence_file(evidence_dir, launchd_file, "fault launchd-smoke child evidence path invalid")
    hardening_payload = load_json(hardening_path)
    require(hardening_payload.get("gate") == "g6_hardening_smoke", "fault hardening-smoke child gate mismatch", payload)
    require(hardening_payload.get("result") == "passed", "fault hardening-smoke child did not pass", payload)
    hardening_assertions = hardening_payload.get("assertions") or {}
    hardening_expected = {
        "adversarialFailureModeCampaignPassed",
        "toolForkBombContainmentPassed",
        "workerIsolationAndInfraPrimitivesPassed",
        "modelTransportFaultCampaignPassed",
        "releaseBuildPassed",
    }
    require(
        set(hardening_assertions.keys()) == hardening_expected,
        "hardening-smoke assertion keys do not match required campaign proof",
        {"expected": sorted(hardening_expected), "actual": sorted(hardening_assertions.keys())},
    )
    all_assertions_true(hardening_payload, "assertions")
    hardening_components = hardening_payload.get("components") or {}
    for name in (
        "adversarialFailureModeCampaign",
        "toolForkBombContainment",
        "workerIsolationAndInfraPrimitives",
        "modelTransportFaultCampaign",
        "releaseBuild",
    ):
        component = hardening_components.get(name) or {}
        require(component.get("result") == "passed", f"hardening-smoke component {name} did not pass", hardening_payload)
    require((load_json(poison_path).get("gate")) == "g6_poison_worker", "fault poison-worker child gate mismatch", payload)
    require((load_json(launchd_path).get("gate")) == "g6_launchd_smoke", "fault launchd-smoke child gate mismatch", payload)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "fault createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "fault host hardware UUID missing", payload)
        require(parse_utc_timestamp(hardening_payload.get("createdAt")) is not None, "hardening-smoke createdAt is not a valid UTC ISO-8601 timestamp", hardening_payload)
        require(bool((hardening_payload.get("host") or {}).get("hardwareUUID")), "hardening-smoke host hardware UUID missing", hardening_payload)
    return payload


def verify_true_reboot(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_true_reboot_resume-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_true_reboot_resume", "true reboot evidence gate mismatch", payload)
    require(payload.get("result") == "passed", "true reboot gate did not pass", payload)
    require(payload.get("phase") == "verified", "true reboot evidence was not verified phase", payload)
    require(bool(payload.get("threadId")), "true reboot thread id missing", payload)
    require(payload.get("trueOSReboot") is True, "trueOSReboot marker missing", payload)
    boot = payload.get("boot") or {}
    require(boot.get("bootTimeChanged") is True, "kernel boot time did not change", payload)
    prepare_boot = boot.get("prepareBootTimeSec")
    verify_boot = boot.get("verifyBootTimeSec")
    require(isinstance(prepare_boot, int) and prepare_boot > 0, "true reboot prepare boot time missing", payload)
    require(isinstance(verify_boot, int) and verify_boot > 0, "true reboot verify boot time missing", payload)
    require(verify_boot > prepare_boot, "true reboot verify boot time is not after prepare boot time", payload)
    require(boot.get("verifyBootTimeAfterPrepare") is True, "true reboot boot ordering marker missing", payload)
    evidence_hw = (payload.get("host") or {}).get("hardwareUUID")
    prepare_hw = boot.get("prepareHardwareUUID")
    verify_hw = boot.get("verifyHardwareUUID")
    require(bool(evidence_hw), "true reboot evidence host hardware UUID missing", payload)
    require(bool(prepare_hw), "true reboot prepare hardware UUID missing", payload)
    require(bool(verify_hw), "true reboot verify hardware UUID missing", payload)
    require(boot.get("hardwareUUIDMatched") is True, "true reboot hardware UUID match marker missing", payload)
    require(evidence_hw == prepare_hw == verify_hw, "true reboot hardware UUID mismatch", payload)
    require((payload.get("turnCountAfterResume") or 0) >= 2, "true reboot turn count too low", payload)
    if strict:
        prepared_at = parse_utc_timestamp(payload.get("preparedAt"))
        verified_at = parse_utc_timestamp(payload.get("verifiedAt"))
        require(prepared_at is not None, "true reboot preparedAt is not a valid UTC ISO-8601 timestamp", payload)
        require(verified_at is not None, "true reboot verifiedAt is not a valid UTC ISO-8601 timestamp", payload)
        require(verified_at > prepared_at, "true reboot verifiedAt is not after preparedAt", payload)
        require(
            prepared_at.timestamp() >= prepare_boot,
            "true reboot preparedAt is before prepare boot time",
            {"preparedAt": payload.get("preparedAt"), "prepareBootTimeSec": prepare_boot},
        )
        require(
            verified_at.timestamp() >= verify_boot,
            "true reboot verifiedAt is before verify boot time",
            {"verifiedAt": payload.get("verifiedAt"), "verifyBootTimeSec": verify_boot},
        )
    return payload


def verify_soak(evidence_dir: Path, *, strict: bool) -> Json:
    _, payload = latest(evidence_dir, "g6_soak-*.manifest.json")
    require(payload.get("gate") == "g6_soak", "soak manifest gate mismatch", payload)
    require(payload.get("result") == "passed", "soak manifest did not pass", payload)
    config = payload.get("configuration") or {}
    mock = payload.get("mock") or {}
    expected_mock_turns = config.get("mockSessions", 0) * config.get("mockTurns", 0)
    require(mock.get("turnsCompleted", 0) >= expected_mock_turns, "mock soak turns too low", mock)
    require((mock.get("durabilityProbeSeconds") or {}).get("p99") is not None, "mock durability p99 missing", mock)
    require(mock.get("elapsedSeconds", 0) >= config.get("mockSeconds", 0), "mock soak elapsed time too low", mock)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "strict soak manifest createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "strict soak manifest host hardware UUID missing", payload)
        bounded = payload.get("boundedPrimitives") or {}
        bounded_assertions = bounded.get("assertions") or {}
        require(bounded.get("gate") == "bounded_primitives_probe", "strict soak bounded-primitives evidence gate mismatch", bounded)
        require(bounded.get("result") == "passed", "strict soak bounded-primitives probe did not pass", bounded)
        for key in [
            "allTestsPassed",
            "boundedChannelBlockingStorm",
            "boundedChannelRejectNewestStorm",
            "coalescingRingFlood",
            "overwriteRingConcurrentPush",
            "headTailBufferAdversarialSizes",
        ]:
            require(bounded_assertions.get(key) is True, f"strict soak bounded-primitives assertion missing: {key}", bounded)
        require(config.get("mockSeconds", 0) >= 86_400, "strict release requires 24h soak", config)
        require(config.get("mockSessions", 0) >= 50, "strict release requires >=50 soak sessions", config)
        require(config.get("mockTurns", 0) > 0, "strict release requires mock turn count", config)
        verify_phase_session_details(
            mock,
            expected_sessions=config.get("mockSessions", 0),
            expected_turns=config.get("mockTurns", 0),
            name="mock soak",
        )
        trend = mock.get("resourceTrend") or {}
        trend_assertions = trend.get("assertions") or {}
        require(trend.get("sampleCount", 0) >= 3, "strict soak resource trend sample count too low", trend)
        require(trend_assertions.get("sampledMultipleTimes") is True, "strict soak resource trend was not sampled repeatedly", trend)
        require(trend_assertions.get("fdTrendFlat") is True, "strict soak fd trend exceeded limit", trend)
        require(trend_assertions.get("rssTrendFlat") is True, "strict soak RSS trend exceeded limit", trend)
        require(trend_assertions.get("workerCountBounded") is True, "strict soak worker trend exceeded session count", trend)
        growth = trend.get("growth") or {}
        max_values = trend.get("max") or {}
        require(growth.get("fd_count", 0) <= trend.get("fdGrowthLimit", -1), "strict soak fd growth exceeds recorded limit", trend)
        require(growth.get("rss_kb", 0) <= trend.get("rssGrowthLimitKiB", -1), "strict soak RSS growth exceeds recorded limit", trend)
        require(max_values.get("workers", 0) <= trend.get("workerLimit", -1), "strict soak max workers exceeds recorded limit", trend)
        broker_probe = mock.get("brokerStatsProbe") or {}
        broker_stats = broker_probe.get("stats") or {}
        expected_coalesced = broker_probe.get("stormRequests", 0) - 1
        require(broker_probe.get("enabled") is True, "strict soak missing broker stats probe", mock)
        require(broker_probe.get("residentAfterClientEOF") is True, "strict soak broker did not stay resident after client EOF", broker_probe)
        require(broker_probe.get("authStoreModeOctal") == "0o600", "strict soak broker auth store was not owner-only", broker_probe)
        require(broker_stats.get("authRefreshes") == 1, "strict soak broker stats did not prove one upstream refresh", broker_probe)
        require(
            isinstance(expected_coalesced, int) and expected_coalesced >= 1,
            "strict soak broker stats storm size too small",
            broker_probe,
        )
        require(
            broker_stats.get("authCoalesced", 0) >= expected_coalesced,
            "strict soak broker stats did not prove refresh storm coalescing",
            broker_probe,
        )
        require(config.get("liveEnabled") is True, "strict release requires live soak", config)
        require(config.get("liveSeconds", 0) > 0, "strict release requires live soak duration", config)
        require(config.get("liveSessions", 0) >= 2, "strict release requires multiple live soak sessions", config)
        require(config.get("liveTurns", 0) >= 2, "strict release requires multi-turn live soak sessions", config)
        live = payload.get("live") or {}
        expected_live_turns = config.get("liveSessions", 0) * config.get("liveTurns", 0)
        require(live.get("turnsCompleted", 0) >= expected_live_turns, "live soak turns too low", live)
        require(live.get("elapsedSeconds", 0) >= config.get("liveSeconds", 0), "live soak elapsed time too low", live)
        verify_phase_session_details(
            live,
            expected_sessions=config.get("liveSessions", 0),
            expected_turns=config.get("liveTurns", 0),
            name="live soak",
        )
        require(config.get("liveCodingEnabled") is True, "strict release requires live coding", config)
        require(config.get("liveCodingSessions", 0) >= 2, "strict release requires multiple live coding sessions", config)
        require(config.get("liveCodingTurns", 0) >= 3, "strict release requires complex multi-turn live coding sessions", config)
        live_coding = payload.get("liveCoding") or {}
        require(live_coding.get("freshCodexdResumeVerified") is True, "live coding resume missing", live_coding)
        require(live_coding.get("debugRepairVerified") is True, "live coding debug/fix proof missing", live_coding)
        require(
            live_coding.get("turnsPerSession", 0) >= config.get("liveCodingTurns", 0),
            "live coding turns per session too low",
            live_coding,
        )
        require(
            len(live_coding.get("sessions") or []) >= config.get("liveCodingSessions", 0),
            "live coding session count too low",
            live_coding,
        )
        sessions = live_coding.get("sessions") or []
        require_unique_string_field(sessions, "threadId", "live coding sessions are not independent")
        require_unique_string_field(sessions, "workspace", "live coding sessions are not independent")
        require_unique_string_field(sessions, "tag", "live coding sessions are not independent")
        expected_tools = config.get("liveCodingSessions", 0) * config.get("liveCodingTurns", 0)
        require(
            live_coding.get("toolCompletionEventsObserved", 0) >= expected_tools,
            "live coding tool completions too low",
            live_coding,
        )
        require(
            (live_coding.get("toolInvocationKindsObserved") or {}).get("code", 0) >= expected_tools,
            "live coding code-mode tool completions too low",
            live_coding,
        )
        require(
            all(s.get("resumedAfterCodexdRestart") is True for s in live_coding.get("sessions") or []),
            "not every live coding session resumed after codexd restart",
            live_coding,
        )
        require(
            all(s.get("rolloutCompletedTurns", 0) >= config.get("liveCodingTurns", 0) for s in live_coding.get("sessions") or []),
            "not every live coding session has enough durable completed turns",
            live_coding,
        )
        require(
            all(s.get("toolCompletionEventsObserved", 0) >= config.get("liveCodingTurns", 0) for s in live_coding.get("sessions") or []),
            "not every live coding session has enough tool completions",
            live_coding,
        )
        require(
            all((s.get("toolInvocationKindsObserved") or {}).get("code", 0) >= config.get("liveCodingTurns", 0) for s in live_coding.get("sessions") or []),
            "not every live coding session has enough code-mode tool completions",
            live_coding,
        )
        require(
            all(s.get("debugRepairVerified") is True for s in live_coding.get("sessions") or []),
            "not every live coding session proved debug/fix repair",
            live_coding,
        )
        require(
            all(((s.get("debugTrace") or {}).get("bugReturncode")) not in (None, 0) for s in live_coding.get("sessions") or []),
            "not every live coding session observed the intentionally failing regression",
            live_coding,
        )
        require(
            all((s.get("debugTrace") or {}).get("fixedReturncode") == 0 for s in live_coding.get("sessions") or []),
            "not every live coding session observed the repaired test passing",
            live_coding,
        )
        require(
            all(live_coding_debug_marker_matches(s, expected_turns=config.get("liveCodingTurns", 0)) for s in live_coding.get("sessions") or []),
            "not every live coding session debug trace marker matched its session tag",
            live_coding,
        )
    return payload


def allocated_mib_from_output(value: Any) -> list[int]:
    if not isinstance(value, str):
        return []
    return [int(match.group(1)) for match in re.finditer(r"(?m)^ALLOCATED mib=([0-9]+)\s*$", value)]


def verify_physical_footprint(evidence_dir: Path, *, strict: bool) -> Json | None:
    found = latest(evidence_dir, "g6_physical_footprint-*.json", required=strict)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g6_physical_footprint", "physical-footprint evidence gate mismatch", payload)
    probe = payload.get("probe") or {}
    if strict:
        config = payload.get("configuration") or {}
        host = payload.get("host") or {}
        started_at = parse_utc_timestamp(probe.get("startedAt"))
        finished_at = parse_utc_timestamp(probe.get("finishedAt"))
        require(payload.get("result") == "passed", "strict release requires physical-footprint probe to pass", payload)
        require(bool(host.get("hardwareUUID")), "strict release physical-footprint host hardware UUID missing", payload)
        require(started_at is not None, "strict release footprint startedAt is not a valid UTC ISO-8601 timestamp", probe)
        require(finished_at is not None, "strict release footprint finishedAt is not a valid UTC ISO-8601 timestamp", probe)
        require(finished_at >= started_at, "strict release footprint finishedAt is before startedAt", probe)
        require(config.get("capMib", 0) > 0, "strict release physical-footprint cap missing", payload)
        require(config.get("allocMib", 0) > config.get("capMib", 0), "strict release physical-footprint allocation did not exceed cap", payload)
        require(probe.get("setOk") is True, "strict release requires task_set_phys_footprint_limit success", probe)
        require(probe.get("setFailed") is not True, "strict release footprint probe reported set failure", probe)
        require(probe.get("enforced") is True, "strict release requires kernel-enforced footprint cap", probe)
        require(probe.get("terminatedAfterSet") is True, "strict release requires process termination after cap set", probe)
        require(probe.get("signalTerminated") is True, "strict release requires signal termination after cap set", probe)
        rc = probe.get("returncode")
        require(isinstance(rc, int) and rc >= 128, "strict release footprint return code did not show signal termination", probe)
        require(rc - 128 == 9, "strict release footprint probe was not SIGKILLed", probe)
        require(probe.get("survivedAllocation") is not True, "strict release footprint probe survived allocation", probe)
        require(probe.get("allocationFailed") is not True, "strict release footprint probe failed by allocation failure", probe)
        require(probe.get("exceededCap") is True, "strict release footprint probe did not prove cap was exceeded", probe)
        require(probe.get("maxAllocatedMib", 0) > config.get("capMib", 0), "strict release footprint max allocation did not exceed cap", {
            "configuration": config,
            "probe": probe,
        })
        output = probe.get("output")
        require(isinstance(output, str) and re.search(r"(?m)^SET_OK\b", output) is not None, "strict release footprint output did not show SET_OK", probe)
        allocated = allocated_mib_from_output(output)
        require(allocated, "strict release footprint output missing ALLOCATED samples", probe)
        require(
            max(allocated) > config.get("capMib", 0),
            "strict release footprint output did not show allocation beyond cap",
            {"configuration": config, "allocatedMib": allocated, "probe": probe},
        )
        require(
            probe.get("maxAllocatedMib") == max(allocated),
            "strict release footprint max allocation does not match probe output",
            {"maxAllocatedMib": probe.get("maxAllocatedMib"), "allocatedMib": allocated},
        )
    return payload


def verify_final_manifest(
    evidence_dir: Path,
    *,
    strict: bool,
    openai_key: str | None,
    notary_profile: str | None,
    required: bool = True,
) -> Json | None:
    found = latest(evidence_dir, "g9_final_rehearsal.manifest.json", required=required)
    if found is None:
        return None
    _, payload = found
    require(payload.get("gate") == "g9_final_rehearsal", "final rehearsal manifest gate mismatch", payload)
    require(payload.get("result") == "passed", "final rehearsal manifest did not pass", payload)
    require(payload.get("strict") is strict, "final rehearsal strict flag mismatch", payload)
    config = payload.get("configuration") or {}
    if openai_key:
        require(config.get("openAIKeyConfigured") is True, "final manifest OpenAI key marker does not match verifier environment", config)
    if notary_profile:
        require(config.get("notaryProfileConfigured") is True, "final manifest notary marker does not match verifier environment", config)
    if strict:
        require(parse_utc_timestamp(payload.get("createdAt")) is not None, "strict final manifest createdAt is not a valid UTC ISO-8601 timestamp", payload)
        require(bool((payload.get("host") or {}).get("hardwareUUID")), "strict final manifest host hardware UUID missing", payload)
        require(bool(openai_key), "strict release verifier requires OPENAI_API_KEY")
        require(bool(notary_profile), "strict release verifier requires CODEXKIT_NOTARY_PROFILE")
        require(config.get("openAIKeyConfigured") is True, "strict final manifest missing OpenAI key marker", config)
        require(config.get("notaryProfileConfigured") is True, "strict final manifest missing notary marker", config)
        require(config.get("trueCleanMachine") is True, "strict final manifest missing true-clean marker", config)
        require(bool(config.get("cleanMachineAttestation")), "strict final manifest missing clean-machine attestation path", config)
        require(bool(config.get("trueRebootEvidence")), "strict final manifest missing true reboot evidence path", config)
        require(
            config.get("physicalFootprintExpectedEnforced") is True,
            "strict final manifest missing physical-footprint enforcement marker",
            config,
        )
        require(config.get("soakSeconds", 0) >= 86_400, "strict final manifest soak seconds too low", config)
        require(config.get("soakSessions", 0) >= 50, "strict final manifest soak sessions too low", config)
        require(config.get("soakTurns", 0) > 0, "strict final manifest soak turn count missing", config)
        require(config.get("soakLiveEnabled") is True, "strict final manifest missing live soak marker", config)
        require(config.get("soakLiveSeconds", 0) > 0, "strict final manifest live soak duration missing", config)
        require(config.get("soakLiveSessions", 0) >= 2, "strict final manifest live soak sessions too low", config)
        require(config.get("soakLiveTurns", 0) >= 2, "strict final manifest live soak turn count too low", config)
        require(config.get("liveCodingEnabled") is True, "strict final manifest missing live coding marker", config)
        require(config.get("liveCodingSessions", 0) >= 2, "strict final manifest live coding sessions too low", config)
        require(config.get("liveCodingTurns", 0) >= 3, "strict final manifest live coding turns too low", config)
    return payload


def verify_final_soak_consistency(final: Json | None, soak: Json, *, strict: bool) -> None:
    if final is None:
        return
    final_config = final.get("configuration") or {}
    soak_config = soak.get("configuration") or {}
    pairs = [
        ("soakSeconds", "mockSeconds"),
        ("soakSessions", "mockSessions"),
        ("soakTurns", "mockTurns"),
        ("soakLiveSeconds", "liveSeconds"),
        ("soakLiveSessions", "liveSessions"),
        ("soakLiveTurns", "liveTurns"),
        ("liveCodingSessions", "liveCodingSessions"),
        ("liveCodingTurns", "liveCodingTurns"),
    ]
    for final_key, soak_key in pairs:
        require(
            final_config.get(final_key) == soak_config.get(soak_key),
            f"final manifest {final_key} does not match soak {soak_key}",
            {"final": final_config, "soak": soak_config},
        )
    require(
        final_config.get("soakLiveEnabled") is soak_config.get("liveEnabled"),
        "final manifest live soak marker does not match soak manifest",
        {"final": final_config, "soak": soak_config},
    )
    require(
        final_config.get("liveCodingEnabled") is soak_config.get("liveCodingEnabled"),
        "final manifest live coding marker does not match soak manifest",
        {"final": final_config, "soak": soak_config},
    )


def resolve_evidence_file(evidence_dir: Path, raw: Any, message: str) -> Path:
    require(isinstance(raw, str) and raw, message, raw)
    candidate = Path(raw) if Path(raw).is_absolute() else evidence_dir / raw
    require(candidate.exists(), f"{message}: file does not exist", raw)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(evidence_dir.resolve())
    except ValueError:
        raise EvidenceError(f"{message}: file outside evidence dir: {raw}") from None
    return resolved


def verify_soak_phase_files(evidence_dir: Path, soak: Json, indexed_paths: set[Path], *, strict: bool) -> None:
    if not strict:
        return
    files = soak.get("files")
    require(isinstance(files, dict), "strict soak manifest missing phase file map", soak)
    config = soak.get("configuration") or {}
    required_phases = ["boundedPrimitives", "mock"]
    if config.get("liveEnabled") is True:
        required_phases.append("live")
    if config.get("liveEnabled") is True and config.get("liveCodingEnabled") is True:
        required_phases.append("liveCoding")
    for phase in required_phases:
        resolved = resolve_evidence_file(evidence_dir, files.get(phase), f"strict soak {phase} phase evidence path missing")
        require(resolved in indexed_paths, f"final manifest missing indexed soak {phase} phase evidence file", files.get(phase))
        payload = load_json(resolved)
        require(payload == soak.get(phase), f"strict soak {phase} phase evidence file does not match manifest payload", {
            "file": files.get(phase),
            "phaseFile": payload,
            "manifestPhase": soak.get(phase),
        })


def verify_final_evidence_index(
    evidence_dir: Path,
    final: Json | None,
    developer_id: Json,
    clean: Json,
    reboot: Json,
    true_reboot: Json | None,
    active_crash: Json | None,
    poison: Json | None,
    blue_green: Json | None,
    launchd: Json | None,
    fault: Json | None,
    soak: Json,
    footprint: Json | None,
    *,
    strict: bool,
) -> set[Path]:
    if final is None:
        return set()
    files = final.get("evidenceFiles")
    require(isinstance(files, list) and files, "final manifest evidenceFiles missing", final)
    hashes = final.get("evidenceFileHashes")
    require(isinstance(hashes, dict) and hashes, "final manifest evidenceFileHashes missing", final)
    hash_keys = set(hashes.keys())
    require(
        all(isinstance(key, str) and key for key in hash_keys),
        "final manifest evidenceFileHashes keys must be non-empty strings",
        hashes,
    )
    evidence_root = evidence_dir.resolve()
    final_manifest_path = (evidence_dir / "g9_final_rehearsal.manifest.json").resolve()
    indexed_paths: set[Path] = set()
    indexed_raws: set[str] = set()
    for raw in files:
        require(isinstance(raw, str) and raw, "final manifest evidenceFiles entries must be non-empty strings", raw)
        indexed_raws.add(raw)
        path = Path(raw)
        candidate = path if path.is_absolute() else evidence_dir / path
        require(candidate.exists(), "final manifest indexed evidence file does not exist", raw)
        resolved = candidate.resolve()
        try:
            resolved.relative_to(evidence_root)
        except ValueError:
            raise EvidenceError(f"final manifest indexed evidence file outside evidence dir: {raw}") from None
        require(resolved != final_manifest_path, "final manifest must not index itself as evidence", raw)
        require(resolved not in indexed_paths, "final manifest evidenceFiles contains duplicate path", raw)
        expected_hash = hashes.get(raw)
        require(
            isinstance(expected_hash, str) and len(expected_hash) == 64,
            "final manifest missing SHA-256 for indexed evidence file",
            raw,
        )
        actual_hash = sha256_file(resolved)
        require(
            actual_hash == expected_hash,
            "final manifest evidence file SHA-256 mismatch",
            {"path": raw, "expected": expected_hash, "actual": actual_hash},
        )
        indexed_paths.add(resolved)
    require(
        hash_keys == indexed_raws,
        "final manifest evidenceFileHashes keys must exactly match evidenceFiles",
        {"indexed": sorted(indexed_raws), "hashKeys": sorted(hash_keys)},
    )

    config = final.get("configuration") or {}
    require(config.get("trueCleanMachine") is clean.get("trueCleanMachine"), "final true-clean marker does not match clean evidence", {
        "final": config,
        "clean": clean,
    })
    require(
        config.get("physicalFootprintExpectedEnforced") is bool(((footprint or {}).get("probe") or {}).get("enforced")),
        "final physical-footprint marker does not match footprint evidence",
        {"final": config, "footprint": footprint},
    )
    require(
        config.get("notaryProfileConfigured") is developer_id.get("notaryProfileConfigured"),
        "final notary marker does not match Developer ID evidence",
        {"final": config, "developerId": developer_id},
    )
    require(
        bool(config.get("trueRebootEvidence")) is bool(true_reboot and true_reboot.get("trueOSReboot")),
        "final true-reboot marker does not match true reboot evidence",
        {"final": config, "trueReboot": true_reboot},
    )
    def require_latest(pattern: str, message: str, *, required: bool = True) -> Path | None:
        current = latest(evidence_dir, pattern, required=required)
        if current is None:
            return None
        require(current is not None, f"missing evidence matching {pattern} in {evidence_dir}")
        audited_path = current[0].resolve()
        require(
            audited_path in indexed_paths,
            message,
            {
                "audited": str(audited_path),
                "indexed": sorted(str(path) for path in indexed_paths),
            },
        )
        return audited_path

    require_latest("g6_developer_id_sign_smoke-*.json", "final manifest missing audited Developer ID evidence file")
    require_latest("g6_clean_machine-*.json", "final manifest missing audited clean-machine evidence file")
    audited_clean_attestation = require_latest("g6_clean_machine_attestation-*.json", "final manifest missing audited clean-machine attestation evidence file", required=strict)
    require_latest("g6_reboot_resume-*.json", "final manifest missing audited reboot-resume evidence file")
    require_latest("g6_blue_green-*.json", "final manifest missing audited blue/green evidence file", required=strict)
    require_latest("g6_active_turn_crash-*.json", "final manifest missing audited active-turn crash evidence file", required=strict)
    require_latest("g6_poison_worker-*.json", "final manifest missing audited poison-worker evidence file", required=strict)
    require_latest("g6_launchd_smoke-*.json", "final manifest missing audited launchd-smoke evidence file", required=strict)
    require_latest("g6_hardening_smoke-*.json", "final manifest missing audited hardening-smoke evidence file", required=strict)
    require_latest("g6_fault-*.json", "final manifest missing audited fault evidence file", required=strict)
    require_latest("g6_soak-*.manifest.json", "final manifest missing audited soak evidence file")
    require_latest("g6_physical_footprint-*.json", "final manifest missing audited physical-footprint evidence file", required=False)
    audited_true_reboot = require_latest("g6_true_reboot_resume-*.json", "final manifest missing audited true-reboot evidence file", required=strict)
    if not strict:
        return indexed_paths
    clean_attestation_source = config.get("cleanMachineAttestation")
    require(isinstance(clean_attestation_source, str) and clean_attestation_source, "strict final manifest clean-machine attestation path missing", config)
    require(audited_clean_attestation is not None, "strict final manifest missing audited clean-machine attestation evidence file", config)
    expected_attestation_name = f"g6_clean_machine_attestation-{Path(clean_attestation_source).name}"
    require(
        audited_clean_attestation.name == expected_attestation_name,
        "final clean-machine attestation source path does not match audited evidence artifact",
        {"final": clean_attestation_source, "audited": str(audited_clean_attestation), "expectedName": expected_attestation_name},
    )
    true_reboot_source = config.get("trueRebootEvidence")
    require(isinstance(true_reboot_source, str) and true_reboot_source, "strict final manifest true reboot evidence path missing", config)
    require(audited_true_reboot is not None, "strict final manifest missing audited true-reboot evidence file", config)
    require(
        Path(true_reboot_source).name == audited_true_reboot.name,
        "final true-reboot source path does not match audited evidence artifact",
        {"final": true_reboot_source, "audited": str(audited_true_reboot)},
    )
    require((soak.get("configuration") or {}).get("liveEnabled") is True, "strict final evidence index expected live soak evidence", soak)
    return indexed_paths


def scan_secret(evidence_dir: Path, secret: str | None, indexed_paths: set[Path]) -> None:
    if not secret or len(secret) < 12:
        return
    paths = {path.resolve() for path in evidence_dir.rglob("*.json") if path.is_file()}
    paths.update(indexed_paths)
    for path in sorted(paths):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        require(secret not in text, f"secret value appeared in evidence file {path}")


def verify(
    evidence_dir: Path,
    *,
    strict: bool,
    openai_key: str | None,
    notary_profile: str | None = None,
    allow_missing_final: bool = False,
) -> Json:
    require(evidence_dir.is_dir(), f"evidence dir does not exist: {evidence_dir}")
    final = verify_final_manifest(
        evidence_dir,
        strict=strict,
        openai_key=openai_key,
        notary_profile=notary_profile,
        required=not allow_missing_final,
    )
    developer_id = verify_developer_id(evidence_dir, strict=strict)
    clean = verify_clean_machine(evidence_dir, strict=strict)
    verify_clean_machine_attestation_artifact(evidence_dir, clean, strict=strict)
    reboot = verify_reboot_resume(evidence_dir, strict=strict)
    blue_green = verify_blue_green(evidence_dir, strict=strict)
    active_crash = verify_active_turn_crash(evidence_dir, strict=strict)
    poison = verify_poison_worker(evidence_dir, strict=strict)
    launchd = verify_launchd_smoke(evidence_dir, strict=strict)
    fault = verify_fault(evidence_dir, strict=strict)
    true_reboot = verify_true_reboot(evidence_dir, strict=strict)
    soak = verify_soak(evidence_dir, strict=strict)
    verify_final_soak_consistency(final, soak, strict=strict)
    footprint = verify_physical_footprint(evidence_dir, strict=strict)
    indexed_paths = verify_final_evidence_index(
        evidence_dir,
        final,
        developer_id,
        clean,
        reboot,
        true_reboot,
        active_crash,
        poison,
        blue_green,
        launchd,
        fault,
        soak,
        footprint,
        strict=strict,
    )
    verify_soak_phase_files(evidence_dir, soak, indexed_paths, strict=strict)
    scan_secret(evidence_dir, openai_key, indexed_paths)
    report: Json = {
        "result": "passed",
        "strict": strict,
        "evidenceDir": str(evidence_dir),
        "checks": {
            "finalManifest": final.get("result") if final else "not-required",
            "developerId": developer_id.get("result"),
            "notarizedGatekeeper": bool((developer_id.get("dmg") or {}).get("gatekeeperAccepted")),
            "cleanMachine": clean.get("result"),
            "trueCleanMachine": bool(clean.get("trueCleanMachine")),
            "restartResume": reboot.get("result"),
            "blueGreen": (blue_green or {}).get("result", "not-required"),
            "activeTurnCrash": (active_crash or {}).get("result", "not-required"),
            "poisonWorker": (poison or {}).get("result", "not-required"),
            "launchdSmoke": (launchd or {}).get("result", "not-required"),
            "fault": (fault or {}).get("result", "not-required"),
            "trueReboot": bool(true_reboot and true_reboot.get("trueOSReboot")),
            "soak": soak.get("result"),
            "soakSeconds": (soak.get("configuration") or {}).get("mockSeconds"),
            "soakSessions": (soak.get("configuration") or {}).get("mockSessions"),
            "liveCodingResume": bool(((soak.get("liveCoding") or {}).get("freshCodexdResumeVerified"))),
            "physicalFootprint": (footprint or {}).get("result", "not-required"),
            "physicalFootprintEnforced": bool(((footprint or {}).get("probe") or {}).get("enforced")),
        },
    }
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence_dir", type=Path)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--allow-missing-final", action="store_true")
    parser.add_argument("--openai-key-env", default="OPENAI_API_KEY")
    parser.add_argument("--notary-profile-env", default="CODEXKIT_NOTARY_PROFILE")
    args = parser.parse_args()
    key = os.environ.get(args.openai_key_env) if args.openai_key_env else None
    notary_profile = os.environ.get(args.notary_profile_env) if args.notary_profile_env else None
    try:
        report = verify(
            args.evidence_dir,
            strict=args.strict,
            openai_key=key,
            notary_profile=notary_profile,
            allow_missing_final=args.allow_missing_final,
        )
    except EvidenceError as exc:
        raise SystemExit(f"FAIL: {exc}") from None
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
