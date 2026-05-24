#!/usr/bin/env python3
"""Self-test release evidence verification with synthetic strict bundles."""

from __future__ import annotations

import copy
import hashlib
import json
import tempfile
from pathlib import Path

import verify_release_evidence as verifier


def write_json(evidence_dir: Path, name: str, payload: dict) -> None:
    (evidence_dir / name).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def evidence_hashes(paths: list[str]) -> dict[str, str]:
    return {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in paths if Path(path).exists()}


def final_manifest_payload(config: dict, files: list[str], *, strict: bool) -> dict:
    return {
        "gate": "g9_final_rehearsal",
        "result": "passed",
        "strict": strict,
        "createdAt": "2026-05-20T00:10:00Z",
        "host": {"hardwareUUID": "HW-1"},
        "configuration": config,
        "evidenceFiles": files,
        "evidenceFileHashes": evidence_hashes(files),
    }


def strict_final_manifest_payload(config: dict, files: list[str]) -> dict:
    return final_manifest_payload(config, files, strict=True)


def strict_final_config() -> dict:
    return {
        "openAIKeyConfigured": True,
        "notaryProfileConfigured": True,
        "trueCleanMachine": True,
        "cleanMachineAttestation": "attestation.json",
        "trueRebootEvidence": "g6_true_reboot_resume-000.json",
        "physicalFootprintExpectedEnforced": True,
        "soakSeconds": 86_400,
        "soakSessions": 50,
        "soakTurns": 3,
        "soakLiveEnabled": True,
        "soakLiveSeconds": 120,
        "soakLiveSessions": 4,
        "soakLiveTurns": 5,
        "liveCodingEnabled": True,
        "liveCodingSessions": 2,
        "liveCodingTurns": 3,
    }


def clean_attestation_artifact_name(config: dict | None = None) -> str:
    source = (config or strict_final_config())["cleanMachineAttestation"]
    return f"g6_clean_machine_attestation-{Path(source).name}"


def base_soak_manifest() -> dict:
    return {
        "gate": "g6_soak",
        "result": "passed",
        "createdAt": "2026-05-20T00:20:00Z",
        "host": {"hardwareUUID": "HW-1"},
        "configuration": {
            "mockSeconds": 86_400,
            "mockSessions": 50,
            "mockTurns": 3,
            "liveEnabled": True,
            "liveSeconds": 120,
            "liveSessions": 4,
            "liveTurns": 5,
            "liveCodingEnabled": True,
            "liveCodingSessions": 2,
            "liveCodingTurns": 3,
        },
        "files": {
            "boundedPrimitives": "g6_soak-000.bounded-primitives.json",
            "mock": "g6_soak-000.mock.json",
            "live": "g6_soak-000.live.json",
            "liveCoding": "g6_soak-000.live-coding.json",
        },
        "boundedPrimitives": {
            "gate": "bounded_primitives_probe",
            "result": "passed",
            "createdAt": "2026-05-20T00:19:00Z",
            "finishedAt": "2026-05-20T00:19:10Z",
            "assertions": {
                "allTestsPassed": True,
                "boundedChannelBlockingStorm": True,
                "boundedChannelRejectNewestStorm": True,
                "coalescingRingFlood": True,
                "overwriteRingConcurrentPush": True,
                "headTailBufferAdversarialSizes": True,
            },
            "tests": [
                {"id": "boundedChannelBlockingStorm", "passed": True},
                {"id": "boundedChannelRejectNewestStorm", "passed": True},
                {"id": "coalescingRingFlood", "passed": True},
                {"id": "overwriteRingConcurrentPush", "passed": True},
                {"id": "headTailBufferAdversarialSizes", "passed": True},
            ],
        },
        "mock": {
            "turnsCompleted": 150,
            "elapsedSeconds": 86_400,
            "durabilityProbeSeconds": {"p99": 0.2},
            "resourceTrend": {
                "sampleCount": 60,
                "fdGrowthLimit": 150,
                "rssGrowthLimitKiB": 524288,
                "workerLimit": 50,
                "start": {"fd_count": 17, "rss_kb": 10000, "workers": 50},
                "end": {"fd_count": 20, "rss_kb": 12000, "workers": 50},
                "max": {"fd_count": 20, "rss_kb": 12000, "workers": 50},
                "growth": {"fd_count": 3, "rss_kb": 2000},
                "assertions": {
                    "sampledMultipleTimes": True,
                    "fdTrendFlat": True,
                    "rssTrendFlat": True,
                    "workerCountBounded": True,
                },
            },
            "brokerStatsProbe": {
                "enabled": True,
                "stormRequests": 200,
                "delayMs": 30,
                "responses": 200,
                "stats": {
                    "authRefreshes": 1,
                    "authCoalesced": 199,
                    "authBreakerOpen": 0,
                    "catalogUpstreamCalls": 0,
                    "catalogCoalesced": 0,
                },
                "authStoreModeOctal": "0o600",
                "residentAfterClientEOF": True,
            },
            "sessionDetails": [
                {
                    "threadId": f"thread-mock-{i}",
                    "workspace": f"/tmp/mock-workspace-{i}",
                    "turnsCompleted": 3,
                    "deltaEvents": 3,
                }
                for i in range(50)
            ],
        },
        "live": {
            "turnsCompleted": 20,
            "elapsedSeconds": 120,
            "sessionDetails": [
                {
                    "threadId": f"thread-live-{i}",
                    "workspace": f"/tmp/live-workspace-{i}",
                    "turnsCompleted": 5,
                    "deltaEvents": 5,
                }
                for i in range(4)
            ],
        },
        "liveCoding": {
            "freshCodexdResumeVerified": True,
            "debugRepairVerified": True,
            "turnsPerSession": 3,
            "toolCompletionEventsObserved": 6,
            "toolInvocationKindsObserved": {"code": 6},
            "sessions": [
                {
                    "threadId": "thread-live-coding-1",
                    "workspace": "/tmp/live-coding-workspace-1",
                    "tag": "LIVE_SESSION_1",
                    "rolloutCompletedTurns": 3,
                    "toolCompletionEventsObserved": 3,
                    "toolInvocationKindsObserved": {"code": 3},
                    "resumedAfterCodexdRestart": True,
                    "debugRepairVerified": True,
                    "debugTrace": {"bugReturncode": 1, "fixedReturncode": 0, "marker": "LIVE_SESSION_1_TURN3_OK"},
                },
                {
                    "threadId": "thread-live-coding-2",
                    "workspace": "/tmp/live-coding-workspace-2",
                    "tag": "LIVE_SESSION_2",
                    "rolloutCompletedTurns": 3,
                    "toolCompletionEventsObserved": 3,
                    "toolInvocationKindsObserved": {"code": 3},
                    "resumedAfterCodexdRestart": True,
                    "debugRepairVerified": True,
                    "debugTrace": {"bugReturncode": 1, "fixedReturncode": 0, "marker": "LIVE_SESSION_2_TURN3_OK"},
                },
            ],
        },
    }


def strict_index_files(evidence_dir: Path, *, physical_suffix: str = "000") -> list[str]:
    config = strict_final_config()
    return [
        str(evidence_dir / "g6_developer_id_sign_smoke-000.json"),
        str(evidence_dir / "g6_clean_machine-000.json"),
        str(evidence_dir / clean_attestation_artifact_name(config)),
        str(evidence_dir / "g6_reboot_resume-000.json"),
        str(evidence_dir / "g6_blue_green-000.json"),
        str(evidence_dir / "g6_active_turn_crash-000.json"),
        str(evidence_dir / "g6_poison_worker-000.json"),
        str(evidence_dir / "g6_launchd_smoke-000.json"),
        str(evidence_dir / "g6_hardening_smoke-000.json"),
        str(evidence_dir / "g6_fault-000.json"),
        str(evidence_dir / "g6_true_reboot_resume-000.json"),
        str(evidence_dir / f"g6_physical_footprint-{physical_suffix}.json"),
        str(evidence_dir / "g6_soak-000.bounded-primitives.json"),
        str(evidence_dir / "g6_soak-000.mock.json"),
        str(evidence_dir / "g6_soak-000.live.json"),
        str(evidence_dir / "g6_soak-000.live-coding.json"),
        str(evidence_dir / "g6_soak-000.manifest.json"),
    ]


def strict_developer_id_payload(dmg_overrides: dict | None = None, *, include_gate: bool = True) -> dict:
    dmg = {
        "sha256": "a" * 64,
        "developerIdSigned": True,
        "gatekeeperAccepted": True,
        "notarytoolSubmitOutput": "status: Accepted",
        "staplerStapleOutput": "The staple and validate action worked!",
        "staplerValidateOutput": "The validate action worked!",
        "gatekeeperAssessOutput": "/tmp/CodexKit.dmg: accepted\nsource=Notarized Developer ID\n",
    }
    if dmg_overrides:
        dmg.update(dmg_overrides)
    payload = {
        "result": "passed",
        "notaryProfileConfigured": True,
        "binaries": {
            "codexd": {
                "developerIdAuthority": True,
                "teamIdentifier": "TEAMID1234",
                "hardenedRuntime": True,
                "entitlements": {"sandbox": True},
            }
        },
        "dmg": dmg,
    }
    if include_gate:
        payload["gate"] = "g6_developer_id_sign_smoke"
    return payload


def write_strict_bundle(evidence_dir: Path, soak: dict) -> None:
    write_json(evidence_dir, "g6_developer_id_sign_smoke-000.json", strict_developer_id_payload())
    clean_payload = strict_clean_machine_payload()
    write_json(evidence_dir, "g6_clean_machine-000.json", clean_payload)
    write_json(evidence_dir, clean_attestation_artifact_name(), clean_payload["cleanMachineAttestation"])
    write_json(
        evidence_dir,
        "g6_reboot_resume-000.json",
        {
            "gate": "g6_reboot_resume",
            "result": "passed",
            "createdAt": "2026-05-20T00:15:00Z",
            "host": {"hardwareUUID": "HW-1"},
            "labels": {
                "codexd": "ai.igent.codexkit.resume.codexd",
                "broker": "ai.igent.codexkit.resume.codex-broker",
            },
            "statusLoaded": "installed=yes\nai.igent.codexkit.resume.codex-broker=loaded\nai.igent.codexkit.resume.codexd=loaded\n",
            "statusUninstalled": "installed=no\nai.igent.codexkit.resume.codex-broker=not-loaded\nai.igent.codexkit.resume.codexd=not-loaded\n",
            "assertions": {
                "sameThreadResumed": True,
                "atLeastTwoTurnsAfterResume": True,
                "spawnedWorkerLogged": True,
                "workerReadyLogged": True,
            },
            "daemonRestart": {"oldPid": "100", "newPid": "200", "pidChanged": True},
            "turnCountAfterResume": 2,
        },
    )
    write_json(
        evidence_dir,
        "g6_active_turn_crash-000.json",
        strict_active_turn_crash_payload(),
    )
    write_json(
        evidence_dir,
        "g6_blue_green-000.json",
        strict_blue_green_payload(),
    )
    write_json(
        evidence_dir,
        "g6_poison_worker-000.json",
        strict_poison_worker_payload(),
    )
    write_json(
        evidence_dir,
        "g6_launchd_smoke-000.json",
        strict_launchd_smoke_payload(),
    )
    write_json(
        evidence_dir,
        "g6_hardening_smoke-000.json",
        strict_hardening_smoke_payload(),
    )
    write_json(
        evidence_dir,
        "g6_fault-000.json",
        strict_fault_payload(),
    )
    write_json(
        evidence_dir,
        "g6_true_reboot_resume-000.json",
        strict_true_reboot_payload(),
    )
    write_json(
        evidence_dir,
        "g6_physical_footprint-000.json",
        strict_physical_footprint_payload(),
    )
    write_soak_phase_files(evidence_dir, soak)
    write_json(evidence_dir, "g6_soak-000.manifest.json", soak)
    files = strict_index_files(evidence_dir)
    write_json(evidence_dir, "g9_final_rehearsal.manifest.json", strict_final_manifest_payload(strict_final_config(), files))


def strict_clean_machine_payload(*, evidence_hw: str | None = "HW-1", attested_hw: str | None = "HW-1") -> dict:
    host = {}
    if evidence_hw is not None:
        host["hardwareUUID"] = evidence_hw
    attested_host = {}
    if attested_hw is not None:
        attested_host["hardwareUUID"] = attested_hw
    assertions = {
        "firstThreadCreated": True,
        "spawnedWorkerLogged": True,
        "workerReadyLogged": True,
        "installRootRemoved": True,
        "launchAgentsPlistsRemoved": True,
        "codexHomePurged": True,
    }
    return {
        "gate": "g6_clean_machine",
        "result": "passed",
        "trueCleanMachine": True,
        "threadId": "thread-clean",
        "host": host,
        "labels": {
            "codexd": "ai.igent.codexkit.clean.codexd",
            "broker": "ai.igent.codexkit.clean.codex-broker",
        },
        "statusLoaded": "installed=yes\nai.igent.codexkit.clean.codex-broker=loaded\nai.igent.codexkit.clean.codexd=loaded\n",
        "statusUninstalled": "installed=no\nai.igent.codexkit.clean.codex-broker=not-loaded\nai.igent.codexkit.clean.codexd=not-loaded\n",
        "assertions": assertions.copy(),
        "cleanMachineAttestation": {
            "trueCleanMachine": True,
            "operator": "selftest",
            "timestamp": "2026-05-20T00:00:00Z",
            "host": attested_host,
            "assertions": assertions.copy(),
        },
    }


def write_good_clean_machine_bundle(evidence_dir: Path) -> None:
    clean_payload = strict_clean_machine_payload()
    write_json(evidence_dir, "g6_clean_machine-000.json", clean_payload)
    write_json(evidence_dir, clean_attestation_artifact_name(), clean_payload["cleanMachineAttestation"])


def strict_true_reboot_payload(
    *,
    phase: str = "verified",
    prepare_boot: int = 100,
    verify_boot: int = 200,
    prepared_at: str | None = "2026-05-20T00:00:00Z",
    verified_at: str | None = "2026-05-20T00:05:00Z",
    evidence_hw: str | None = "HW-1",
    prepare_hw: str | None = "HW-1",
    verify_hw: str | None = "HW-1",
    hardware_match_marker: bool = True,
    include_gate: bool = True,
) -> dict:
    host = {}
    if evidence_hw is not None:
        host["hardwareUUID"] = evidence_hw
    boot = {
        "prepareBootTimeSec": prepare_boot,
        "verifyBootTimeSec": verify_boot,
        "bootTimeChanged": prepare_boot != verify_boot,
        "verifyBootTimeAfterPrepare": verify_boot > prepare_boot,
        "hardwareUUIDMatched": hardware_match_marker,
    }
    if prepare_hw is not None:
        boot["prepareHardwareUUID"] = prepare_hw
    if verify_hw is not None:
        boot["verifyHardwareUUID"] = verify_hw
    payload = {
        "result": "passed",
        "phase": phase,
        "trueOSReboot": True,
        "threadId": "thread-reboot",
        "host": host,
        "boot": boot,
        "turnCountAfterResume": 2,
    }
    if include_gate:
        payload["gate"] = "g6_true_reboot_resume"
    if prepared_at is not None:
        payload["preparedAt"] = prepared_at
    if verified_at is not None:
        payload["verifiedAt"] = verified_at
    return payload


def strict_active_turn_crash_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:16:00Z",
    hardware_uuid: str | None = "HW-1",
    labels: dict | None = None,
    status_loaded: str | None = None,
    status_uninstalled: str | None = None,
    assertions: dict | None = None,
    old_pid: str | None = "300",
    new_pid: str | None = "400",
    pid_changed: bool = True,
    before_statuses: list | None = None,
    after_statuses: list | None = None,
    turn_count_after: int | None = 2,
) -> dict:
    if labels is None:
        labels = {
            "codexd": "ai.igent.codexkit.active.codexd",
            "broker": "ai.igent.codexkit.active.codex-broker",
        }
    if status_loaded is None:
        status_loaded = "installed=yes\nai.igent.codexkit.active.codex-broker=loaded\nai.igent.codexkit.active.codexd=loaded\n"
    if status_uninstalled is None:
        status_uninstalled = "installed=no\nai.igent.codexkit.active.codex-broker=not-loaded\nai.igent.codexkit.active.codexd=not-loaded\n"
    if before_statuses is None:
        before_statuses = ["interrupted"]
    if after_statuses is None:
        after_statuses = ["interrupted", "completed"]
    if assertions is None:
        assertions = {
            "sameThreadResumed": True,
            "activeTurnMarkedInterruptedOrInProgress": True,
            "laterTurnCompleted": True,
            "atLeastTwoTurnsAfterRecovery": True,
            "daemonPidChanged": True,
            "spawnedWorkerLogged": True,
            "workerReadyLogged": True,
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "labels": labels,
        "statusLoaded": status_loaded,
        "statusUninstalled": status_uninstalled,
        "threadId": "thread-active-crash",
        "daemonRestart": {"oldPid": old_pid, "newPid": new_pid, "pidChanged": pid_changed},
        "turnStatusesBeforeRecovery": before_statuses,
        "turnStatusesAfterRecovery": after_statuses,
        "turnCountAfterRecovery": turn_count_after,
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_active_turn_crash"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_poison_worker_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:17:00Z",
    hardware_uuid: str | None = "HW-1",
    threads: dict | None = None,
    completions: dict | None = None,
    launches: dict | None = None,
    daemon: dict | None = None,
    poison_turn: dict | None = None,
    assertions: dict | None = None,
) -> dict:
    if threads is None:
        threads = {
            "quiet": "thread-poison-quiet",
            "poisoned": "thread-poison-poisoned",
            "recovered": "thread-poison-recovered",
        }
    if completions is None:
        completions = {"quiet": 2, "poisoned": 0, "recovered": 1}
    if launches is None:
        launches = {"healthy": 2, "poison": 1}
    if daemon is None:
        daemon = {"pid": 500, "survivedPoison": True}
    if poison_turn is None:
        poison_turn = {"errored": True, "unexpectedCompletion": False}
    if assertions is None:
        assertions = {
            "daemonSurvivedPoison": True,
            "quietSessionSurvivedPoison": True,
            "poisonWorkerLaunchedOnce": True,
            "poisonedTurnDidNotComplete": True,
            "healthyWorkerLaunchedBeforeAndAfterPoison": True,
            "recoveredSessionCompleted": True,
            "threadsAreDistinct": True,
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "threads": threads,
        "completions": completions,
        "launches": launches,
        "daemon": daemon,
        "poisonTurn": poison_turn,
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_poison_worker"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_blue_green_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:18:00Z",
    hardware_uuid: str | None = "HW-1",
    threads: dict | None = None,
    completions: dict | None = None,
    launches: dict | None = None,
    daemon: dict | None = None,
    paths: dict | None = None,
    assertions: dict | None = None,
) -> dict:
    if threads is None:
        threads = {
            "blue": "thread-blue-green-blue",
            "green": "thread-blue-green-green",
            "rollback": "thread-blue-green-rollback",
        }
    if completions is None:
        completions = {"blue": 3, "green": 1, "rollback": 1}
    if launches is None:
        launches = {"blue": 2, "green": 1}
    if daemon is None:
        daemon = {"pid": 600, "survivedPromotionAndRollback": True}
    if paths is None:
        paths = {"installRoot": "/tmp/blue-green-install"}
    if assertions is None:
        assertions = {
            "loadedBlueSessionSurvivedPromotion": True,
            "greenSessionUsedAfterPromotion": True,
            "rollbackSessionUsedBlue": True,
            "noExtraBlueRespawnDuringPromotion": True,
            "threadsAreDistinct": True,
            "daemonSurvivedPromotionAndRollback": True,
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "threads": threads,
        "completions": completions,
        "launches": launches,
        "daemon": daemon,
        "paths": paths,
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_blue_green"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_launchd_smoke_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:19:00Z",
    hardware_uuid: str | None = "HW-1",
    assertions: dict | None = None,
    restart: dict | None = None,
    turn_count: int = 2,
) -> dict:
    labels = {
        "codexd": "ai.igent.codexkit.launchd.codexd",
        "broker": "ai.igent.codexkit.launchd.codex-broker",
    }
    if assertions is None:
        assertions = {
            "brokerRestarted": True,
            "codexdRestarted": True,
            "turnBeforeAndAfterRestartCompleted": True,
            "spawnedWorkerLogged": True,
            "workerReadyLogged": True,
        }
    if restart is None:
        restart = {
            "broker": {"oldPid": "700", "newPid": "701", "pidChanged": True},
            "codexd": {"oldPid": "800", "newPid": "801", "pidChanged": True},
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "labels": labels,
        "statusLoaded": "installed=yes\nai.igent.codexkit.launchd.codex-broker=loaded\nai.igent.codexkit.launchd.codexd=loaded\n",
        "statusUninstalled": "installed=no\nai.igent.codexkit.launchd.codex-broker=not-loaded\nai.igent.codexkit.launchd.codexd=not-loaded\n",
        "restart": restart,
        "turnCount": turn_count,
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_launchd_smoke"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_fault_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:20:00Z",
    hardware_uuid: str | None = "HW-1",
    assertions: dict | None = None,
    components: dict | None = None,
) -> dict:
    if assertions is None:
        assertions = {
            "hardeningSmokePassed": True,
            "hardeningSmokeEvidenceCaptured": True,
            "poisonWorkerEvidenceCaptured": True,
            "launchdSmokeEvidenceCaptured": True,
        }
    if components is None:
        components = {
            "hardeningSmoke": {"result": "passed", "evidenceFile": "g6_hardening_smoke-000.json"},
            "poisonWorker": {"result": "passed", "evidenceFile": "g6_poison_worker-000.json"},
            "launchdSmoke": {"result": "passed", "evidenceFile": "g6_launchd_smoke-000.json"},
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "components": components,
        "evidenceFiles": ["g6_hardening_smoke-000.json", "g6_poison_worker-000.json", "g6_launchd_smoke-000.json"],
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_fault"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_hardening_smoke_payload(
    *,
    include_gate: bool = True,
    result: str = "passed",
    created_at: str | None = "2026-05-20T00:19:00Z",
    hardware_uuid: str | None = "HW-1",
    assertions: dict | None = None,
) -> dict:
    if assertions is None:
        assertions = {
            "adversarialFailureModeCampaignPassed": True,
            "toolForkBombContainmentPassed": True,
            "workerIsolationAndInfraPrimitivesPassed": True,
            "modelTransportFaultCampaignPassed": True,
            "releaseBuildPassed": True,
        }
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "components": {
            "adversarialFailureModeCampaign": {"result": "passed"},
            "toolForkBombContainment": {"result": "passed"},
            "workerIsolationAndInfraPrimitives": {"result": "passed"},
            "modelTransportFaultCampaign": {"result": "passed"},
            "releaseBuild": {"result": "passed"},
        },
        "assertions": assertions,
    }
    if include_gate:
        payload["gate"] = "g6_hardening_smoke"
    if created_at is not None:
        payload["createdAt"] = created_at
    return payload


def strict_physical_footprint_payload(
    *,
    result: str = "passed",
    cap_mib: int = 64,
    alloc_mib: int = 256,
    set_ok: bool = True,
    set_failed: bool = False,
    enforced: bool = True,
    terminated_after_set: bool = True,
    signal_terminated: bool = True,
    returncode: int | None = None,
    survived_allocation: bool = False,
    allocation_failed: bool = False,
    max_allocated_mib: int = 80,
    exceeded_cap: bool = True,
    output: str | None = None,
    include_gate: bool = True,
    hardware_uuid: str | None = "HW-1",
    started_at: str | None = "2026-05-20T00:00:00Z",
    finished_at: str | None = "2026-05-20T00:00:05Z",
) -> dict:
    if returncode is None:
        returncode = 137 if signal_terminated else 3
    if output is None:
        output = f"SET_OK old=0 cap_mib={cap_mib}\nALLOCATED mib={max_allocated_mib}\n"
    payload = {
        "result": result,
        "host": {"hardwareUUID": hardware_uuid} if hardware_uuid is not None else {},
        "configuration": {
            "capMib": cap_mib,
            "allocMib": alloc_mib,
            "expectEnforced": True,
        },
        "probe": {
            "returncode": returncode,
            "setOk": set_ok,
            "setFailed": set_failed,
            "enforced": enforced,
            "terminatedAfterSet": terminated_after_set,
            "signalTerminated": signal_terminated,
            "survivedAllocation": survived_allocation,
            "allocationFailed": allocation_failed,
            "maxAllocatedMib": max_allocated_mib,
            "exceededCap": exceeded_cap,
            "output": output,
        },
    }
    if include_gate:
        payload["gate"] = "g6_physical_footprint"
    if started_at is not None:
        payload["probe"]["startedAt"] = started_at
    if finished_at is not None:
        payload["probe"]["finishedAt"] = finished_at
    return payload


def assert_strict_passes(evidence_dir: Path) -> None:
    report = verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
    assert report["result"] == "passed", report


def write_soak_phase_files(evidence_dir: Path, soak: dict) -> None:
    if "boundedPrimitives" in soak:
        write_json(evidence_dir, "g6_soak-000.bounded-primitives.json", soak["boundedPrimitives"])
    write_json(evidence_dir, "g6_soak-000.mock.json", soak["mock"])
    write_json(evidence_dir, "g6_soak-000.live.json", soak["live"])
    write_json(evidence_dir, "g6_soak-000.live-coding.json", soak["liveCoding"])


def refresh_final_manifest_hashes(evidence_dir: Path) -> None:
    path = evidence_dir / "g9_final_rehearsal.manifest.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["evidenceFileHashes"] = evidence_hashes(payload["evidenceFiles"])
    write_json(evidence_dir, "g9_final_rehearsal.manifest.json", payload)


def assert_strict_rejects(evidence_dir: Path, soak: dict, expected: str, *, sync_phase_files: bool = True) -> None:
    if sync_phase_files:
        write_soak_phase_files(evidence_dir, soak)
    write_json(evidence_dir, "g6_soak-000.manifest.json", soak)
    refresh_final_manifest_hashes(evidence_dir)
    try:
        verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
    except verifier.EvidenceError as exc:
        assert expected in str(exc), str(exc)
        return
    raise AssertionError(f"strict verifier accepted invalid soak evidence; expected {expected!r}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="codexkit-evidence-selftest-") as temp:
        evidence_dir = Path(temp)
        good = base_soak_manifest()
        write_strict_bundle(evidence_dir, good)
        assert_strict_passes(evidence_dir)
        strict_manifest = verifier.load_json(evidence_dir / "g9_final_rehearsal.manifest.json")
        missing_manifest_gate = copy.deepcopy(strict_manifest)
        del missing_manifest_gate["gate"]
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_manifest_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final rehearsal manifest gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest without the gate marker")

        bad_manifest_timestamp = copy.deepcopy(strict_manifest)
        bad_manifest_timestamp["createdAt"] = "2026-05-20T00:10:00"
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", bad_manifest_timestamp)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict final manifest createdAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less final manifest createdAt")

        missing_manifest_hw = copy.deepcopy(strict_manifest)
        missing_manifest_hw["host"] = {}
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_manifest_hw)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict final manifest host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest without host hardware UUID")

        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", strict_manifest)

        missing_bounded = copy.deepcopy(good)
        del missing_bounded["boundedPrimitives"]
        assert_strict_rejects(evidence_dir, missing_bounded, "strict soak bounded-primitives evidence gate mismatch")
        failed_bounded_assertion = copy.deepcopy(good)
        failed_bounded_assertion["boundedPrimitives"]["assertions"]["overwriteRingConcurrentPush"] = False
        assert_strict_rejects(
            evidence_dir,
            failed_bounded_assertion,
            "strict soak bounded-primitives assertion missing: overwriteRingConcurrentPush",
        )
        write_strict_bundle(evidence_dir, good)
        strict_manifest = verifier.load_json(evidence_dir / "g9_final_rehearsal.manifest.json")

        missing_broker_probe = copy.deepcopy(good)
        del missing_broker_probe["mock"]["brokerStatsProbe"]
        assert_strict_rejects(evidence_dir, missing_broker_probe, "strict soak missing broker stats probe")
        missing_resource_trend = copy.deepcopy(good)
        del missing_resource_trend["mock"]["resourceTrend"]
        assert_strict_rejects(evidence_dir, missing_resource_trend, "strict soak resource trend sample count too low")
        bad_resource_trend = copy.deepcopy(good)
        bad_resource_trend["mock"]["resourceTrend"]["assertions"]["rssTrendFlat"] = False
        assert_strict_rejects(evidence_dir, bad_resource_trend, "strict soak RSS trend exceeded limit")
        low_broker_coalescing = copy.deepcopy(good)
        low_broker_coalescing["mock"]["brokerStatsProbe"]["stats"]["authCoalesced"] = 198
        assert_strict_rejects(
            evidence_dir,
            low_broker_coalescing,
            "strict soak broker stats did not prove refresh storm coalescing",
        )
        write_strict_bundle(evidence_dir, good)
        strict_manifest = verifier.load_json(evidence_dir / "g9_final_rehearsal.manifest.json")

        good_reboot_resume = verifier.load_json(evidence_dir / "g6_reboot_resume-000.json")
        missing_reboot_gate = copy.deepcopy(good_reboot_resume)
        del missing_reboot_gate["gate"]
        write_json(evidence_dir, "g6_reboot_resume-000.json", missing_reboot_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "reboot-resume evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted reboot-resume evidence without the gate marker")

        incomplete_reboot_assertions = copy.deepcopy(good_reboot_resume)
        del incomplete_reboot_assertions["assertions"]["workerReadyLogged"]
        write_json(evidence_dir, "g6_reboot_resume-000.json", incomplete_reboot_assertions)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "reboot-resume evidence assertion keys do not match required resume proof" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted incomplete reboot-resume assertion keys")

        missing_reboot_loaded_status = copy.deepcopy(good_reboot_resume)
        missing_reboot_loaded_status["statusLoaded"] = "installed=yes\nai.igent.codexkit.resume.codex-broker=loaded\n"
        write_json(evidence_dir, "g6_reboot_resume-000.json", missing_reboot_loaded_status)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "reboot-resume loaded status missing codexd loaded marker" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted reboot-resume evidence without codexd loaded status")

        bad_reboot_timestamp = copy.deepcopy(good_reboot_resume)
        bad_reboot_timestamp["createdAt"] = "2026-05-20T00:15:00"
        write_json(evidence_dir, "g6_reboot_resume-000.json", bad_reboot_timestamp)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "reboot-resume createdAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less reboot-resume createdAt")

        missing_reboot_hw = copy.deepcopy(good_reboot_resume)
        missing_reboot_hw["host"] = {}
        write_json(evidence_dir, "g6_reboot_resume-000.json", missing_reboot_hw)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "reboot-resume host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted reboot-resume evidence without host hardware UUID")

        missing_reboot_pid = copy.deepcopy(good_reboot_resume)
        missing_reboot_pid["daemonRestart"]["newPid"] = ""
        write_json(evidence_dir, "g6_reboot_resume-000.json", missing_reboot_pid)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "daemon restart evidence missing old/new pid" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted reboot-resume evidence without old/new pid")

        write_json(evidence_dir, "g6_reboot_resume-000.json", good_reboot_resume)

        good_blue_green = verifier.load_json(evidence_dir / "g6_blue_green-000.json")
        missing_blue_green_gate = copy.deepcopy(good_blue_green)
        del missing_blue_green_gate["gate"]
        write_json(evidence_dir, "g6_blue_green-000.json", missing_blue_green_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted blue/green evidence without the gate marker")

        incomplete_blue_green_assertions = copy.deepcopy(good_blue_green)
        del incomplete_blue_green_assertions["assertions"]["rollbackSessionUsedBlue"]
        write_json(evidence_dir, "g6_blue_green-000.json", incomplete_blue_green_assertions)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green evidence assertion keys do not match required promotion proof" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted incomplete blue/green assertion keys")

        duplicate_blue_green_threads = copy.deepcopy(good_blue_green)
        duplicate_blue_green_threads["threads"]["rollback"] = duplicate_blue_green_threads["threads"]["blue"]
        write_json(evidence_dir, "g6_blue_green-000.json", duplicate_blue_green_threads)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green thread ids are not distinct" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted duplicate blue/green thread ids")

        under_run_blue = copy.deepcopy(good_blue_green)
        under_run_blue["completions"]["blue"] = 2
        write_json(evidence_dir, "g6_blue_green-000.json", under_run_blue)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green loaded blue session did not survive promotion" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted blue/green evidence with under-run blue completions")

        extra_blue_launch = copy.deepcopy(good_blue_green)
        extra_blue_launch["launches"]["blue"] = 3
        write_json(evidence_dir, "g6_blue_green-000.json", extra_blue_launch)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green blue launch count did not prove initial plus rollback only" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted extra blue worker launch")

        dead_blue_green_daemon = copy.deepcopy(good_blue_green)
        dead_blue_green_daemon["daemon"]["survivedPromotionAndRollback"] = False
        write_json(evidence_dir, "g6_blue_green-000.json", dead_blue_green_daemon)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green daemon did not survive promotion and rollback" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted blue/green evidence with dead daemon")

        bad_blue_green_timestamp = copy.deepcopy(good_blue_green)
        bad_blue_green_timestamp["createdAt"] = "2026-05-20T00:18:00"
        write_json(evidence_dir, "g6_blue_green-000.json", bad_blue_green_timestamp)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green createdAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less blue/green createdAt")

        missing_blue_green_hw = copy.deepcopy(good_blue_green)
        missing_blue_green_hw["host"] = {}
        write_json(evidence_dir, "g6_blue_green-000.json", missing_blue_green_hw)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "blue/green host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted blue/green evidence without host hardware UUID")

        write_json(evidence_dir, "g6_blue_green-000.json", good_blue_green)

        good_active_crash = verifier.load_json(evidence_dir / "g6_active_turn_crash-000.json")
        missing_active_gate = copy.deepcopy(good_active_crash)
        del missing_active_gate["gate"]
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_active_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without the gate marker")

        incomplete_active_assertions = copy.deepcopy(good_active_crash)
        del incomplete_active_assertions["assertions"]["laterTurnCompleted"]
        write_json(evidence_dir, "g6_active_turn_crash-000.json", incomplete_active_assertions)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash evidence assertion keys do not match required recovery proof" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted incomplete active-turn crash assertion keys")

        missing_active_loaded_status = copy.deepcopy(good_active_crash)
        missing_active_loaded_status["statusLoaded"] = "installed=yes\nai.igent.codexkit.active.codex-broker=loaded\n"
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_active_loaded_status)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash loaded status missing codexd loaded marker" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without codexd loaded status")

        bad_active_timestamp = copy.deepcopy(good_active_crash)
        bad_active_timestamp["createdAt"] = "2026-05-20T00:16:00"
        write_json(evidence_dir, "g6_active_turn_crash-000.json", bad_active_timestamp)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash createdAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less active-turn crash createdAt")

        missing_active_hw = copy.deepcopy(good_active_crash)
        missing_active_hw["host"] = {}
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_active_hw)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without host hardware UUID")

        missing_active_pid = copy.deepcopy(good_active_crash)
        missing_active_pid["daemonRestart"]["newPid"] = ""
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_active_pid)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash daemon restart missing old/new pid" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without old/new pid")

        missing_interrupted_status = copy.deepcopy(good_active_crash)
        missing_interrupted_status["turnStatusesBeforeRecovery"] = ["completed"]
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_interrupted_status)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash did not capture interrupted/in-progress turn before recovery" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without interrupted pre-recovery status")

        missing_later_completed = copy.deepcopy(good_active_crash)
        missing_later_completed["turnStatusesAfterRecovery"] = ["interrupted"]
        write_json(evidence_dir, "g6_active_turn_crash-000.json", missing_later_completed)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "active-turn crash did not complete a later turn after recovery" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted active-turn crash evidence without later completed turn")

        write_json(evidence_dir, "g6_active_turn_crash-000.json", good_active_crash)

        good_poison = verifier.load_json(evidence_dir / "g6_poison_worker-000.json")
        missing_poison_gate = copy.deepcopy(good_poison)
        del missing_poison_gate["gate"]
        write_json(evidence_dir, "g6_poison_worker-000.json", missing_poison_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted poison-worker evidence without the gate marker")

        incomplete_poison_assertions = copy.deepcopy(good_poison)
        del incomplete_poison_assertions["assertions"]["recoveredSessionCompleted"]
        write_json(evidence_dir, "g6_poison_worker-000.json", incomplete_poison_assertions)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker evidence assertion keys do not match required containment proof" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted incomplete poison-worker assertion keys")

        duplicate_poison_threads = copy.deepcopy(good_poison)
        duplicate_poison_threads["threads"]["recovered"] = duplicate_poison_threads["threads"]["quiet"]
        write_json(evidence_dir, "g6_poison_worker-000.json", duplicate_poison_threads)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker thread ids are not distinct" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted duplicate poison-worker thread ids")

        poisoned_completed = copy.deepcopy(good_poison)
        poisoned_completed["completions"]["poisoned"] = 1
        write_json(evidence_dir, "g6_poison_worker-000.json", poisoned_completed)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker poisoned turn unexpectedly completed" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted completed poisoned turn")

        dead_poison_daemon = copy.deepcopy(good_poison)
        dead_poison_daemon["daemon"]["survivedPoison"] = False
        write_json(evidence_dir, "g6_poison_worker-000.json", dead_poison_daemon)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker daemon did not survive poison" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted poison-worker evidence with dead daemon")

        bad_poison_timestamp = copy.deepcopy(good_poison)
        bad_poison_timestamp["createdAt"] = "2026-05-20T00:17:00"
        write_json(evidence_dir, "g6_poison_worker-000.json", bad_poison_timestamp)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker createdAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less poison-worker createdAt")

        missing_poison_hw = copy.deepcopy(good_poison)
        missing_poison_hw["host"] = {}
        write_json(evidence_dir, "g6_poison_worker-000.json", missing_poison_hw)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "poison-worker host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted poison-worker evidence without host hardware UUID")

        write_json(evidence_dir, "g6_poison_worker-000.json", good_poison)

        good_launchd = verifier.load_json(evidence_dir / "g6_launchd_smoke-000.json")
        missing_launchd_gate = copy.deepcopy(good_launchd)
        del missing_launchd_gate["gate"]
        write_json(evidence_dir, "g6_launchd_smoke-000.json", missing_launchd_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "launchd smoke evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted launchd smoke evidence without the gate marker")

        bad_launchd_restart = copy.deepcopy(good_launchd)
        bad_launchd_restart["restart"]["codexd"]["pidChanged"] = False
        write_json(evidence_dir, "g6_launchd_smoke-000.json", bad_launchd_restart)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "launchd smoke codexd restart did not show pid change" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted launchd smoke evidence without codexd pid change")

        bad_launchd_turns = copy.deepcopy(good_launchd)
        bad_launchd_turns["turnCount"] = 1
        write_json(evidence_dir, "g6_launchd_smoke-000.json", bad_launchd_turns)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "launchd smoke did not complete turns before and after restart" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted launchd smoke evidence without post-restart turn")

        write_json(evidence_dir, "g6_launchd_smoke-000.json", good_launchd)

        good_fault = verifier.load_json(evidence_dir / "g6_fault-000.json")
        missing_fault_gate = copy.deepcopy(good_fault)
        del missing_fault_gate["gate"]
        write_json(evidence_dir, "g6_fault-000.json", missing_fault_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "fault evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted fault evidence without the gate marker")

        bad_fault_hardening_child = copy.deepcopy(good_fault)
        bad_fault_hardening_child["components"]["hardeningSmoke"]["evidenceFile"] = ""
        write_json(evidence_dir, "g6_fault-000.json", bad_fault_hardening_child)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "fault evidence missing hardening-smoke child artifact" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted fault evidence without hardening child artifact")

        bad_hardening_child = copy.deepcopy(verifier.load_json(evidence_dir / "g6_hardening_smoke-000.json"))
        bad_hardening_child["assertions"]["releaseBuildPassed"] = False
        write_json(evidence_dir, "g6_hardening_smoke-000.json", bad_hardening_child)
        write_json(evidence_dir, "g6_fault-000.json", good_fault)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "assertions contains failed assertions" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted failed hardening-smoke child assertion")
        write_json(evidence_dir, "g6_hardening_smoke-000.json", strict_hardening_smoke_payload())

        bad_hardening_component = copy.deepcopy(verifier.load_json(evidence_dir / "g6_hardening_smoke-000.json"))
        bad_hardening_component["components"]["modelTransportFaultCampaign"]["result"] = "failed"
        write_json(evidence_dir, "g6_hardening_smoke-000.json", bad_hardening_component)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "hardening-smoke component modelTransportFaultCampaign did not pass" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted failed hardening-smoke model-transport component")
        write_json(evidence_dir, "g6_hardening_smoke-000.json", strict_hardening_smoke_payload())

        bad_fault_component = copy.deepcopy(good_fault)
        bad_fault_component["components"]["hardeningSmoke"]["result"] = "failed"
        write_json(evidence_dir, "g6_fault-000.json", bad_fault_component)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "fault component hardeningSmoke did not pass" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted failed hardening component in fault evidence")

        bad_fault_child = copy.deepcopy(good_fault)
        bad_fault_child["components"]["launchdSmoke"]["evidenceFile"] = ""
        write_json(evidence_dir, "g6_fault-000.json", bad_fault_child)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "fault evidence missing launchd-smoke child artifact" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted fault evidence without launchd child artifact")

        write_json(evidence_dir, "g6_fault-000.json", good_fault)

        try:
            verifier.verify(evidence_dir, strict=True, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "strict release verifier requires OPENAI_API_KEY" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted strict release evidence without OPENAI_API_KEY")
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key")
        except verifier.EvidenceError as exc:
            assert "strict release verifier requires CODEXKIT_NOTARY_PROFILE" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted strict release evidence without CODEXKIT_NOTARY_PROFILE")

        files_000 = strict_index_files(evidence_dir)
        local_final = final_manifest_payload(strict_final_config(), files_000, strict=False)
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_final)
        report = verifier.verify(evidence_dir, strict=False, openai_key=None)
        assert report["result"] == "passed", report

        local_key_marker_drift = copy.deepcopy(local_final)
        local_key_marker_drift["configuration"]["openAIKeyConfigured"] = False
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_key_marker_drift)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest OpenAI key marker does not match verifier environment" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted OpenAI key marker drift")

        local_notary_marker_drift = copy.deepcopy(local_final)
        local_notary_marker_drift["configuration"]["notaryProfileConfigured"] = False
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_notary_marker_drift)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None, notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest notary marker does not match verifier environment" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted notary marker drift")

        local_soak_drift = copy.deepcopy(local_final)
        local_soak_drift["configuration"]["soakTurns"] = 2
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_soak_drift)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest soakTurns does not match soak mockTurns" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted final/soak turn configuration drift")

        local_marker_drift = copy.deepcopy(local_final)
        local_marker_drift["configuration"]["physicalFootprintExpectedEnforced"] = False
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_marker_drift)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final physical-footprint marker does not match footprint evidence" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted final/footprint marker drift")

        local_missing_footprint_index_files = [
            str(evidence_dir / "g6_developer_id_sign_smoke-000.json"),
            str(evidence_dir / "g6_clean_machine-000.json"),
            str(evidence_dir / clean_attestation_artifact_name()),
            str(evidence_dir / "g6_reboot_resume-000.json"),
            str(evidence_dir / "g6_blue_green-000.json"),
            str(evidence_dir / "g6_active_turn_crash-000.json"),
            str(evidence_dir / "g6_poison_worker-000.json"),
            str(evidence_dir / "g6_launchd_smoke-000.json"),
            str(evidence_dir / "g6_hardening_smoke-000.json"),
            str(evidence_dir / "g6_fault-000.json"),
            str(evidence_dir / "g6_true_reboot_resume-000.json"),
            str(evidence_dir / "g6_soak-000.manifest.json"),
        ]
        local_missing_footprint_index = final_manifest_payload(
            strict_final_config(),
            local_missing_footprint_index_files,
            strict=False,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_missing_footprint_index)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited physical-footprint evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted missing audited physical-footprint evidence index")

        local_missing_blue_green_index = final_manifest_payload(
            strict_final_config(),
            [path for path in files_000 if not path.endswith("g6_blue_green-000.json")],
            strict=False,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_missing_blue_green_index)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited blue/green evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted missing audited blue/green evidence index")

        local_missing_active_index = final_manifest_payload(
            strict_final_config(),
            [path for path in files_000 if not path.endswith("g6_active_turn_crash-000.json")],
            strict=False,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_missing_active_index)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited active-turn crash evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted missing audited active-turn crash evidence index")

        local_missing_poison_index = final_manifest_payload(
            strict_final_config(),
            [path for path in files_000 if not path.endswith("g6_poison_worker-000.json")],
            strict=False,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_missing_poison_index)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited poison-worker evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted missing audited poison-worker evidence index")

        local_bad_hash = copy.deepcopy(local_final)
        local_bad_hash["evidenceFileHashes"][files_000[0]] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_bad_hash)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest evidence file SHA-256 mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted mismatched final manifest evidence hash")

        local_self_index = copy.deepcopy(local_final)
        manifest_path = str(evidence_dir / "g9_final_rehearsal.manifest.json")
        local_self_index["evidenceFiles"] = files_000 + [manifest_path]
        local_self_index["evidenceFileHashes"][manifest_path] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_self_index)
        current_manifest_hash = hashlib.sha256((evidence_dir / "g9_final_rehearsal.manifest.json").read_bytes()).hexdigest()
        local_self_index["evidenceFileHashes"][manifest_path] = current_manifest_hash
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", local_self_index)
        try:
            verifier.verify(evidence_dir, strict=False, openai_key=None)
        except verifier.EvidenceError as exc:
            assert "final manifest must not index itself as evidence" in str(exc), str(exc)
        else:
            raise AssertionError("local verifier accepted final manifest self-indexing")

        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", strict_final_manifest_payload(strict_final_config(), files_000))

        bad = copy.deepcopy(good)
        del bad["gate"]
        assert_strict_rejects(evidence_dir, bad, "soak manifest gate mismatch")

        bad = copy.deepcopy(good)
        bad["createdAt"] = "2026-05-20T00:20:00"
        assert_strict_rejects(evidence_dir, bad, "strict soak manifest createdAt is not a valid UTC ISO-8601 timestamp")

        bad = copy.deepcopy(good)
        bad["host"] = {}
        assert_strict_rejects(evidence_dir, bad, "strict soak manifest host hardware UUID missing")
        write_json(evidence_dir, "g6_soak-000.manifest.json", good)
        refresh_final_manifest_hashes(evidence_dir)

        missing_live_coding_phase_index_files = [
            path for path in files_000 if not path.endswith("g6_soak-000.live-coding.json")
        ]
        write_json(
            evidence_dir,
            "g9_final_rehearsal.manifest.json",
            strict_final_manifest_payload(strict_final_config(), missing_live_coding_phase_index_files),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing indexed soak liveCoding phase evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted missing indexed live-coding phase evidence")
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", strict_final_manifest_payload(strict_final_config(), files_000))

        bad = copy.deepcopy(good)
        bad["mock"]["turnsCompleted"] = 151
        assert_strict_rejects(
            evidence_dir,
            bad,
            "strict soak mock phase evidence file does not match manifest payload",
            sync_phase_files=False,
        )

        bad = copy.deepcopy(good)
        bad["mock"]["turnsCompleted"] = 149
        assert_strict_rejects(evidence_dir, bad, "mock soak turns too low")

        bad = copy.deepcopy(good)
        bad["mock"]["sessionDetails"][0]["turnsCompleted"] = 2
        assert_strict_rejects(evidence_dir, bad, "mock soak session turns too low")

        bad = copy.deepcopy(good)
        bad["mock"]["sessionDetails"][1]["threadId"] = bad["mock"]["sessionDetails"][0]["threadId"]
        assert_strict_rejects(evidence_dir, bad, "mock soak sessions are not independent: duplicate threadId")

        bad = copy.deepcopy(good)
        bad["live"]["turnsCompleted"] = 19
        assert_strict_rejects(evidence_dir, bad, "live soak turns too low")

        bad = copy.deepcopy(good)
        bad["live"]["elapsedSeconds"] = 119
        assert_strict_rejects(evidence_dir, bad, "live soak elapsed time too low")

        bad = copy.deepcopy(good)
        bad["live"]["sessionDetails"][0]["turnsCompleted"] = 4
        assert_strict_rejects(evidence_dir, bad, "live soak session turns too low")

        bad = copy.deepcopy(good)
        bad["live"]["sessionDetails"][1]["workspace"] = bad["live"]["sessionDetails"][0]["workspace"]
        assert_strict_rejects(evidence_dir, bad, "live soak sessions are not independent: duplicate workspace")

        bad = copy.deepcopy(good)
        del bad["live"]["sessionDetails"]
        assert_strict_rejects(evidence_dir, bad, "live soak sessionDetails missing")

        bad = copy.deepcopy(good)
        del bad["configuration"]["liveTurns"]
        assert_strict_rejects(evidence_dir, bad, "strict release requires multi-turn live soak sessions")

        bad = copy.deepcopy(good)
        bad["configuration"]["liveSessions"] = 1
        bad["live"]["turnsCompleted"] = 5
        assert_strict_rejects(evidence_dir, bad, "strict release requires multiple live soak sessions")

        bad = copy.deepcopy(good)
        bad["configuration"]["liveTurns"] = 1
        bad["live"]["turnsCompleted"] = 4
        assert_strict_rejects(evidence_dir, bad, "strict release requires multi-turn live soak sessions")

        bad = copy.deepcopy(good)
        bad["configuration"]["liveCodingSessions"] = 1
        assert_strict_rejects(evidence_dir, bad, "strict release requires multiple live coding sessions")

        bad = copy.deepcopy(good)
        bad["configuration"]["liveCodingTurns"] = 2
        bad["liveCoding"]["turnsPerSession"] = 2
        assert_strict_rejects(evidence_dir, bad, "strict release requires complex multi-turn live coding sessions")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][1]["threadId"] = bad["liveCoding"]["sessions"][0]["threadId"]
        assert_strict_rejects(evidence_dir, bad, "live coding sessions are not independent: duplicate threadId")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][1]["workspace"] = bad["liveCoding"]["sessions"][0]["workspace"]
        assert_strict_rejects(evidence_dir, bad, "live coding sessions are not independent: duplicate workspace")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][1]["tag"] = bad["liveCoding"]["sessions"][0]["tag"]
        assert_strict_rejects(evidence_dir, bad, "live coding sessions are not independent: duplicate tag")

        bad = copy.deepcopy(good)
        del bad["liveCoding"]["sessions"][1]["workspace"]
        assert_strict_rejects(evidence_dir, bad, "live coding sessions are not independent: missing workspace")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][0]["rolloutCompletedTurns"] = 2
        assert_strict_rejects(evidence_dir, bad, "not every live coding session has enough durable completed turns")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][0]["toolCompletionEventsObserved"] = 2
        assert_strict_rejects(evidence_dir, bad, "not every live coding session has enough tool completions")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["toolInvocationKindsObserved"]["code"] = 5
        assert_strict_rejects(evidence_dir, bad, "live coding code-mode tool completions too low")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][0]["toolInvocationKindsObserved"]["code"] = 2
        assert_strict_rejects(evidence_dir, bad, "not every live coding session has enough code-mode tool completions")

        bad = copy.deepcopy(good)
        bad["liveCoding"]["sessions"][0]["debugTrace"]["marker"] = "LIVE_SESSION_2_TURN3_OK"
        assert_strict_rejects(evidence_dir, bad, "not every live coding session debug trace marker matched its session tag")

        bad = copy.deepcopy(good)
        del bad["liveCoding"]["sessions"][0]["debugTrace"]["marker"]
        assert_strict_rejects(evidence_dir, bad, "not every live coding session debug trace marker matched its session tag")

        write_soak_phase_files(evidence_dir, good)
        files_000 = strict_index_files(evidence_dir)
        bad_config = strict_final_config() | {"soakTurns": 2}
        bad_final = strict_final_manifest_payload(bad_config, files_000)
        write_json(evidence_dir, "g6_soak-000.manifest.json", good)
        bad_final = strict_final_manifest_payload(bad_config, files_000)
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", bad_final)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest soakTurns does not match soak mockTurns" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted mismatched final/soak turn configuration")

        write_json(
            evidence_dir,
            "g9_final_rehearsal.manifest.json",
            strict_final_manifest_payload(strict_final_config(), files_000),
        )

        clean_missing_gate = strict_clean_machine_payload()
        del clean_missing_gate["gate"]
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_missing_gate)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted clean-machine evidence without the gate marker")

        clean_missing_cleanup_assertion = strict_clean_machine_payload()
        del clean_missing_cleanup_assertion["assertions"]["launchAgentsPlistsRemoved"]
        del clean_missing_cleanup_assertion["cleanMachineAttestation"]["assertions"]["launchAgentsPlistsRemoved"]
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_missing_cleanup_assertion)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_missing_cleanup_assertion["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine evidence assertion keys do not match required cleanup proof" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted incomplete clean-machine cleanup assertion keys")

        clean_bad_loaded_status = strict_clean_machine_payload()
        clean_bad_loaded_status["statusLoaded"] = "installed=yes\nai.igent.codexkit.clean.codex-broker=loaded\n"
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_bad_loaded_status)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_bad_loaded_status["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine loaded status missing codexd loaded marker" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted clean-machine evidence without codexd loaded status")

        clean_bad_uninstalled_status = strict_clean_machine_payload()
        clean_bad_uninstalled_status["statusUninstalled"] = "installed=no\nai.igent.codexkit.clean.codexd=not-loaded\n"
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_bad_uninstalled_status)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_bad_uninstalled_status["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine uninstalled status missing broker not-loaded marker" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted clean-machine evidence without broker not-loaded status")

        write_good_clean_machine_bundle(evidence_dir)

        write_json(evidence_dir, "g6_clean_machine-000.json", strict_clean_machine_payload(attested_hw=None))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation missing host hardware UUID" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted clean-machine attestation without hardware UUID")

        write_json(evidence_dir, "g6_clean_machine-000.json", strict_clean_machine_payload(attested_hw="HW-2"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation hardware UUID mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted mismatched clean-machine hardware UUID")

        clean_bad_timestamp = strict_clean_machine_payload()
        clean_bad_timestamp["cleanMachineAttestation"]["timestamp"] = "not-a-timestamp"
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_bad_timestamp)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_bad_timestamp["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation timestamp is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted malformed clean-machine attestation timestamp")

        clean_naive_timestamp = strict_clean_machine_payload()
        clean_naive_timestamp["cleanMachineAttestation"]["timestamp"] = "2026-05-20T00:00:00"
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_naive_timestamp)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_naive_timestamp["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation timestamp is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less clean-machine attestation timestamp")

        clean_assertion_drift = strict_clean_machine_payload()
        clean_assertion_drift["cleanMachineAttestation"]["assertions"]["extraOperatorClaim"] = True
        write_json(evidence_dir, "g6_clean_machine-000.json", clean_assertion_drift)
        write_json(evidence_dir, clean_attestation_artifact_name(), clean_assertion_drift["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation assertion keys do not match evidence assertions" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted clean-machine attestation assertion-key drift")

        write_good_clean_machine_bundle(evidence_dir)

        write_json(evidence_dir, clean_attestation_artifact_name(), strict_clean_machine_payload(attested_hw="HW-2")["cleanMachineAttestation"])
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "clean-machine attestation artifact does not match embedded evidence" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted mismatched clean-machine attestation artifact")
        write_json(evidence_dir, clean_attestation_artifact_name(), strict_clean_machine_payload()["cleanMachineAttestation"])

        attestation_source_drift = strict_final_manifest_payload(
            strict_final_config() | {"cleanMachineAttestation": "different-attestation.json"},
            files_000,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", attestation_source_drift)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final clean-machine attestation source path does not match audited evidence artifact" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final clean-machine attestation source path drift")
        write_json(
            evidence_dir,
            "g9_final_rehearsal.manifest.json",
            strict_final_manifest_payload(strict_final_config(), files_000),
        )

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(phase="prepared"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot evidence was not verified phase" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted prepared-phase true reboot evidence")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(prepare_boot=200, verify_boot=100))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot verify boot time is not after prepare boot time" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted non-increasing true reboot boot time")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(verify_hw="HW-2", hardware_match_marker=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot hardware UUID match marker missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted mismatched true reboot hardware UUID")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(include_gate=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted true reboot evidence without the gate marker")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(prepared_at=None))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot preparedAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted true reboot evidence without preparedAt")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload(verified_at="2026-05-20T00:05:00"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot verifiedAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less true reboot verifiedAt")

        write_json(
            evidence_dir,
            "g6_true_reboot_resume-000.json",
            strict_true_reboot_payload(prepared_at="2026-05-20T00:10:00Z", verified_at="2026-05-20T00:05:00Z"),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot verifiedAt is not after preparedAt" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted non-monotonic true reboot timestamps")

        write_json(
            evidence_dir,
            "g6_true_reboot_resume-000.json",
            strict_true_reboot_payload(verify_boot=2_000_000_000, verified_at="2026-05-20T00:05:00Z"),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "true reboot verifiedAt is before verify boot time" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted true reboot verifiedAt before verify boot time")

        write_json(evidence_dir, "g6_true_reboot_resume-000.json", strict_true_reboot_payload())

        reboot_source_drift = strict_final_manifest_payload(
            strict_final_config() | {"trueRebootEvidence": "different-true-reboot.json"},
            files_000,
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", reboot_source_drift)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final true-reboot source path does not match audited evidence artifact" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final true-reboot source path drift")
        write_json(
            evidence_dir,
            "g9_final_rehearsal.manifest.json",
            strict_final_manifest_payload(strict_final_config(), files_000),
        )

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"gatekeeperAssessOutput": "/tmp/CodexKit.dmg: accepted\nsource=Developer ID\n"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release Gatekeeper assessment did not show exact Notarized Developer ID source" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted non-notarized Gatekeeper assessment source")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"gatekeeperAssessOutput": "/tmp/CodexKit.dmg: not accepted\nsource=Notarized Developer ID\n"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release missing exact accepted Gatekeeper assessment output" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted misleading Gatekeeper not accepted output")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"gatekeeperAssessOutput": "/tmp/CodexKit.dmg: accepted\nsource=Notarized Developer ID (cached)\n"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release Gatekeeper assessment did not show exact Notarized Developer ID source" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted inexact Gatekeeper assessment source")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"notarytoolSubmitOutput": "status: Invalid"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release notarytool output did not show exact Accepted status" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted notary output without acceptance")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"notarytoolSubmitOutput": "status: Not Accepted"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release notarytool output did not show exact Accepted status" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted misleading Not Accepted notary output")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"staplerStapleOutput": "The staple action failed"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release stapler staple output did not show exact success" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted misleading stapler staple failure output")

        write_json(
            evidence_dir,
            "g6_developer_id_sign_smoke-000.json",
            strict_developer_id_payload({"staplerValidateOutput": "The validate action failed"}),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release stapler validate output did not show exact success" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted misleading stapler validate failure output")

        write_json(evidence_dir, "g6_developer_id_sign_smoke-000.json", strict_developer_id_payload(include_gate=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "Developer ID evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted Developer ID evidence without the gate marker")

        write_json(evidence_dir, "g6_developer_id_sign_smoke-000.json", strict_developer_id_payload({"sha256": "not-a-sha"}))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "DMG SHA-256 evidence missing or invalid" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted invalid DMG SHA-256 evidence")

        write_json(evidence_dir, "g6_developer_id_sign_smoke-000.json", strict_developer_id_payload())

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(include_gate=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "physical-footprint evidence gate mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted physical-footprint evidence without the gate marker")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(hardware_uuid=None))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release physical-footprint host hardware UUID missing" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted physical-footprint evidence without hardware UUID")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(started_at=None))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint startedAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted physical-footprint evidence without startedAt")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(finished_at="2026-05-20T00:00:05"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint finishedAt is not a valid UTC ISO-8601 timestamp" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted timezone-less physical-footprint finishedAt")

        write_json(
            evidence_dir,
            "g6_physical_footprint-000.json",
            strict_physical_footprint_payload(started_at="2026-05-20T00:00:10Z", finished_at="2026-05-20T00:00:05Z"),
        )
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint finishedAt is before startedAt" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted non-monotonic physical-footprint timestamps")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(signal_terminated=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release requires signal termination after cap set" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence without signal termination")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(returncode=143))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint probe was not SIGKILLed" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence terminated by a non-SIGKILL signal")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(set_failed=True))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint probe reported set failure" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence that also reported set failure")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(survived_allocation=True))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint probe survived allocation" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence that survived allocation")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(allocation_failed=True))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint probe failed by allocation failure" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence caused by allocation failure")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(max_allocated_mib=64, exceeded_cap=False))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint probe did not prove cap was exceeded" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence that did not exceed the cap")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(output="SET_OK old=0 cap_mib=64\n"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint output missing ALLOCATED samples" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence without allocated output samples")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload(max_allocated_mib=80, output="SET_OK old=0 cap_mib=64\nALLOCATED mib=96\n"))
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "strict release footprint max allocation does not match probe output" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted footprint evidence with mismatched max allocation output")

        write_json(evidence_dir, "g6_physical_footprint-000.json", strict_physical_footprint_payload())
        missing_index_files = [
            str(evidence_dir / "g6_developer_id_sign_smoke-000.json"),
            str(evidence_dir / "g6_clean_machine-000.json"),
            str(evidence_dir / clean_attestation_artifact_name()),
            str(evidence_dir / "g6_reboot_resume-000.json"),
            str(evidence_dir / "g6_blue_green-000.json"),
            str(evidence_dir / "g6_active_turn_crash-000.json"),
            str(evidence_dir / "g6_poison_worker-000.json"),
            str(evidence_dir / "g6_launchd_smoke-000.json"),
            str(evidence_dir / "g6_hardening_smoke-000.json"),
            str(evidence_dir / "g6_fault-000.json"),
            str(evidence_dir / "g6_true_reboot_resume-000.json"),
            str(evidence_dir / "g6_soak-000.manifest.json"),
        ]
        missing_index = strict_final_manifest_payload(strict_final_config(), missing_index_files)
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited physical-footprint evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest missing physical-footprint evidence index")

        write_json(evidence_dir, "g6_physical_footprint-999.json", strict_physical_footprint_payload())
        stale_index = strict_final_manifest_payload(strict_final_config(), files_000)
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", stale_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited physical-footprint evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted stale physical-footprint evidence index")

        missing_attestation_index = strict_final_manifest_payload(
            strict_final_config(),
            [path for path in strict_index_files(evidence_dir, physical_suffix="999") if "g6_clean_machine_attestation-" not in path],
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_attestation_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited clean-machine attestation evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted missing clean-machine attestation evidence index")

        good_index_files = strict_index_files(evidence_dir, physical_suffix="999")
        strict_config = strict_final_config()
        missing_path_index = strict_final_manifest_payload(
            strict_config,
            good_index_files + [str(evidence_dir / "missing-evidence.json")],
        )
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_path_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest indexed evidence file does not exist" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted nonexistent final manifest evidence path")

        outside = evidence_dir.parent / "outside-evidence.json"
        outside.write_text("{}\n", encoding="utf-8")
        outside_path_index = strict_final_manifest_payload(strict_config, good_index_files + [str(outside)])
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", outside_path_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest indexed evidence file outside evidence dir" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest evidence path outside evidence dir")

        shadow_dir = evidence_dir / "shadow"
        shadow_dir.mkdir()
        shadow_soak = shadow_dir / "g6_soak-000.manifest.json"
        shadow_soak.write_text((evidence_dir / "g6_soak-000.manifest.json").read_text(encoding="utf-8"), encoding="utf-8")
        shadow_index_files = [
            str(evidence_dir / "g6_developer_id_sign_smoke-000.json"),
            str(evidence_dir / "g6_clean_machine-000.json"),
            str(evidence_dir / clean_attestation_artifact_name()),
            str(evidence_dir / "g6_reboot_resume-000.json"),
            str(evidence_dir / "g6_blue_green-000.json"),
            str(evidence_dir / "g6_active_turn_crash-000.json"),
            str(evidence_dir / "g6_poison_worker-000.json"),
            str(evidence_dir / "g6_launchd_smoke-000.json"),
            str(evidence_dir / "g6_hardening_smoke-000.json"),
            str(evidence_dir / "g6_fault-000.json"),
            str(evidence_dir / "g6_true_reboot_resume-000.json"),
            str(evidence_dir / "g6_physical_footprint-999.json"),
            str(shadow_soak),
        ]
        shadow_path_index = strict_final_manifest_payload(strict_config, shadow_index_files)
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", shadow_path_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing audited soak evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted shadow evidence path with audited basename")

        secret_extra = shadow_dir / "diagnostic.txt"
        secret_extra.write_text("diagnostic sk-selftest-openai-key leak\n", encoding="utf-8")
        secret_index = strict_final_manifest_payload(strict_config, good_index_files + [str(secret_extra)])
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", secret_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "secret value appeared in evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted indexed nested evidence containing OPENAI_API_KEY")

        non_string_index = strict_final_manifest_payload(strict_config, good_index_files)
        non_string_index["evidenceFiles"] = good_index_files + [None]
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", non_string_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest evidenceFiles entries must be non-empty strings" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted non-string final manifest evidence path")

        duplicate_index = strict_final_manifest_payload(strict_config, good_index_files + [good_index_files[0]])
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", duplicate_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest evidenceFiles contains duplicate path" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted duplicate final manifest evidence path")

        self_index = strict_final_manifest_payload(strict_config, good_index_files)
        manifest_path = str(evidence_dir / "g9_final_rehearsal.manifest.json")
        self_index["evidenceFiles"] = good_index_files + [manifest_path]
        self_index["evidenceFileHashes"][manifest_path] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", self_index)
        current_manifest_hash = hashlib.sha256((evidence_dir / "g9_final_rehearsal.manifest.json").read_bytes()).hexdigest()
        self_index["evidenceFileHashes"][manifest_path] = current_manifest_hash
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", self_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest must not index itself as evidence" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest self-indexing")

        missing_hash_index = strict_final_manifest_payload(strict_config, good_index_files)
        missing_hash_index["evidenceFileHashes"].pop(good_index_files[0])
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", missing_hash_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest missing SHA-256 for indexed evidence file" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted final manifest missing evidence hash")

        bad_hash_index = strict_final_manifest_payload(strict_config, good_index_files)
        bad_hash_index["evidenceFileHashes"][good_index_files[0]] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", bad_hash_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest evidence file SHA-256 mismatch" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted mismatched final manifest evidence hash")

        extra_hash_index = strict_final_manifest_payload(strict_config, good_index_files)
        extra_hash_index["evidenceFileHashes"][str(evidence_dir / "not-indexed.json")] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", extra_hash_index)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest evidenceFileHashes keys must exactly match evidenceFiles" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted extra evidence hash entry")

        empty_hash_key = strict_final_manifest_payload(strict_config, good_index_files)
        empty_hash_key["evidenceFileHashes"][""] = "0" * 64
        write_json(evidence_dir, "g9_final_rehearsal.manifest.json", empty_hash_key)
        try:
            verifier.verify(evidence_dir, strict=True, openai_key="sk-selftest-openai-key", notary_profile="selftest-notary-profile")
        except verifier.EvidenceError as exc:
            assert "final manifest evidenceFileHashes keys must be non-empty strings" in str(exc), str(exc)
        else:
            raise AssertionError("strict verifier accepted empty evidence hash key")

    print("verify_release_evidence_selftest OK")


if __name__ == "__main__":
    main()
