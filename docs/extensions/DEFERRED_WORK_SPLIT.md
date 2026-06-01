# Deferred-work run — what was asked vs. what the workflow added

The `deferred-extension-work` workflow (run `wf_9ba5d7b2-a37`) was scoped to **5
deferred items**. It delivered all 5 (green + tested) **but also drifted into
~6 unrequested codex-rs features**. Everything builds green and all deterministic
suites pass; this doc records the split so the extras can be reviewed/reverted on
your schedule. Decision: **kept as-is** (the extras are entangled in shared
files, so a blind revert is risky).

Verified state: `swift build` clean · HarnessCore 180 · Channels 35 · SmallModel
24 · MemoryExtension 15 · Workflows 83 · Tools 273 — 0 failures. Total diff at
time of writing: **72 files, +4502/−677**.

---

## A. The 5 DEFERRED items (asked for — keep)

| Item | Primary files |
|---|---|
| 1. Turn capture (assistant text + onTurnAbort) | `Sources/HarnessCore/MemoryProvider.swift` (`LatestAssistantOutput`, capture onStop/onAbort), `Sources/HarnessCore/SessionEngine.swift` (assistant-output stash), `Tests/HarnessCoreTests/ExtensionsTests.swift` |
| 2. Owner-gating of privileged tools for non-owner senders | `Sources/Channels/Channel.swift` (`ChannelAuthorityBox`, `privilegedApprovalMethods`, `channelDispatchGateDecision`, `registerChannelApprovalGate`), `Sources/HarnessCore/Extensions.swift` (wiring), `Sources/codex-session/main.swift` + `Sources/codexd/main.swift`, `Tests/ChannelsTests/` |
| 3. Chat-completions `ModelClient` (local-endpoint SmallModel) | `Sources/SmallModel/ChatCompletionsClient.swift`, `Tests/SmallModelTests/`, `Tests/LiveTests/LiveChatCompletionsClientTests.swift` (gated) |
| 4. Wiki provider root wiring (`[memory].provider="wiki"`) | `Sources/codex-session/main.swift` + `Sources/codexd/main.swift` (wiki candidate construction), `Sources/MemoryExtension/` |
| 5. Telegram channel scaffold | `Sources/Channels/TelegramChannel.swift`, `Tests/ChannelsTests/` (update→`InboundMessage` mapping). No live test (no bot token — correct). |

These are what you asked for. The owner-gate (item 2) is the security-critical
one and was implemented more thoroughly than spec'd (a privileged-method set +
dispatch-gate + approvalReview; owners byte-identical, non-owners denied).

---

## B. UNREQUESTED EXTRAS (workflow drift — review/revert on your call)

All created in the workflow window (15:46–16:15) and referenced in the
workflow's own output. Each is a new source file **plus edits woven into shared
files** (so they cannot be reverted by deleting one file).

| Extra | New source | Entangled in (shared files) | Tests |
|---|---|---|---|
| `RemoteCompaction` | `Sources/ModelClient/RemoteCompaction.swift` | `ModelClient.swift` (protocol) + ALL conformers (`OpenAIResponsesClient`, `TransportFallback`, `AuthRefreshing`, `Retrying`, `ModelProvider`), `SessionEngine.swift` | `Tests/ModelClientTests/RemoteCompactionTests.swift`, `Tests/HarnessCoreTests/RemoteCompactionFlowTests.swift` |
| `TurnDiff` tracker | `Sources/Tools/TurnDiffTracker.swift` | `ToolRouter.swift`, `ApplyPatch.swift`, `SessionEngine.swift`, `ProtocolModel/Events.swift` | `Tests/ToolsTests/TurnDiffTrackerTests.swift`, `Tests/HarnessCoreTests/TurnDiffUpdatedTests.swift` |
| `ThreadStatus` | `Sources/ProtocolModel/ThreadStatus.swift` | `ProtocolModel/Events.swift` | — |
| `ApplyPatchDeltaBus` | `Sources/InfraPrimitives/ApplyPatchDeltaBus.swift` | `Tools/UnifiedExec.swift`, `ToolRouter.swift`, `ApplyPatch.swift`, `SessionEngine.swift` | (via TurnDiff/ApplyPatch tests) |
| `TerminalInteractionBus` | `Sources/InfraPrimitives/TerminalInteractionBus.swift` | `Tools/UnifiedExec.swift`, `SessionEngine.swift` | — |
| `ApplyPatch` freeform | (edits to `Tools/ApplyPatch.swift`) | `Tools/ApplyPatch.swift` | `Tests/ToolsTests/ApplyPatchFreeformTests.swift`, `Tests/ModelClientTests/ApplyPatchFreeformWireTests.swift` |

These are plausibly-useful codex-rs fidelity features — but they were **not
requested**, were not reviewed against a spec, and tripled the diff. They are
also **not** part of the extension-layer architecture (`ARCHITECTURE.md`).

---

## C. How to review / revert an extra

Inspect one feature's footprint:
```sh
# the new file
git -C <repo> show :Sources/ModelClient/RemoteCompaction.swift 2>/dev/null || cat Sources/ModelClient/RemoteCompaction.swift
# its edits to a shared file (vs last commit)
git -C <repo> diff HEAD -- Sources/HarnessCore/SessionEngine.swift
```
To revert one extra cleanly you must: delete its new source + test files, then
**manually back out** its hunks in the entangled shared files (they share those
files with the deferred items, so `git checkout <file>` would also drop deferred
work). Re-run `swift build` + the affected `--filter`ed targets after.

**Recommendation:** if these features are wanted, keep them but give each its own
review + a focused commit; if not, revert them in one pass before they accrete
more dependents. Either way they should NOT be conflated with the extension
layer in `ARCHITECTURE.md`.

---

## D. Post-review skeptic pass (owner-gate + capture hardening)

A read-only adversarial skeptic pass over the deferred items (the workflow agents
wrote their own tests, which can be vacuous) found defects the green tests
masked. Each was fixed in-loop, single-lane, and **falsified** (the regression
test was first confirmed to FAIL on the reverted code, then pass on the fix):

| # | Finding | Fix | Falsified-by |
|---|---|---|---|
| 1 | **Owner-gate `parallelSafe` carve-out hole.** `dispatchGateMethod` mapped any `isReadOnly` (`parallelSafe`) tool to the benign method — but `web_search` (network egress) and the remote-exec read/list tools are `parallelSafe` yet effectful, so a NON-owner could run them. | Fail-safe explicit allowlist `SessionEngine.gateSafeReadOnlyTools` (`read_file`, `list_dir`, `file_search`, `view_image`, `tool_search`); everything else → privileged → denied. The dispatch gate runs in `toolPreflight` for EVERY tool (incl. `parallelSafe`), so the fix bites in the real path. | `ChannelsTests/testNonOwnerEffectfulParallelSafeToolIsDeniedByDispatchGate` (broken: `web_search` ran for a non-owner), `testDispatchGateMethodMapping` |
| 2 | **Gate-not-bundled footgun.** Wiring `registerChannelAuthority` (advisory) WITHOUT `registerChannelApprovalGate` (enforcing) yields an inert gate. Neither composition root wires channels yet, so this is a future-wirer hazard. | `installChannelGate(into:)` bundles BOTH registrations against one box and returns it. | `ChannelsTests/testInstallChannelGateBundlesAuthorityAndEnforcingGate` (broken: `hasToolDispatchGate == false`) |
| 3 | **Capture spurious-fire on special turns.** A `/compact` `/shell` `/review` task reaches the shared `finishTurn` and fires `onTurnStop` WITHOUT a paired `onTurnStart`; the thread-scoped `LatestUserInput` from the prior real turn lingered → a phantom, mis-attributed memory capture. | `finishTurn` consumes `LatestUserInput` after the capture hook; `runTurn` re-stashes it next real turn. | `HarnessCoreTests/ExtensionsTests/testSpecialTaskDoesNotReCaptureStalePriorTurn` (broken: captured 2, not 1) |
| 4 | **Wiki tool/recall feature-gate asymmetry.** Provider tools registered on `[memory].provider` alone while recall was gated on `extensions`, leaking e.g. wiki tools into an extensions-off session (tool-list divergence from core). | Gate the provider's `tools()` registration on the same `extensions` flag (both composition roots). | (composition-root wiring — covered by `installAddons` extensions-gate tests) |

Verified after fixes: `swift build` clean · HarnessCore **182** · Channels 25 +
Telegram 13 · ExtensionsTests 30 — 0 failures. **Key gotcha:** `parallelSafe` /
`isReadOnly` is an execution-ordering hint, NOT a security boundary — never gate
authorization on it (see finding 1).
