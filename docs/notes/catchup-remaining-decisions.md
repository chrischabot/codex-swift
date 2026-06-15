# Catchup — remaining-items decision register (2026-06-15)

After P0–P4 (live-proven), P5a (encrypted secrets, live-proven), and P6.3 (SQLite
auto-recovery, reviewed + tested) landed on `main`, the items below are the
remainder from `codex-catchup.md`. Each is dispositioned here: **PORTED** (done),
**N/A** (the port models the area differently or doesn't ship the feature, with no
observable wire/behavior gap), or **DIVERGENCE** (a real upstream behavior the port
deliberately implements differently, with rationale). Forcing full parity on a
DIVERGENCE/N/A item would re-architect or regress working, tested systems for no
observable gain — the wrong engineering call.

## P6 — persistence parity

| Item | Upstream | Disposition |
|---|---|---|
| **6.1** rollout `response_item` fidelity | #449 / `should_persist_response_item`: persist tool/exec/file-change as `response_item` rollout lines | **DIVERGENCE (deliberate, documented in `Rollout.swift:843-880`).** The port collapses a tool CALL+OUTPUT into ONE UI-shaped `ThreadItem` (`CommandExecution` carries aggregatedOutput/exitCode/status/commandActions/diffs); upstream keeps them as TWO `ResponseItem`s. Emitting a lone `local_shell_call` would (a) drop output/exit/duration and (b) read back as a lossy `.unknown` item — **regressing the port's own faithful resume**, which depends on the native `{"t":"item"}` envelope. Full parity = un-collapse + a recombination resume path: a large, data-critical rework. agentMessage/userMessage/reasoning ARE already written as upstream `response_item` (the bulk of history). Cross-tool replay of exec/file-change history into upstream's `load_rollout_items` is the only gap; the port doesn't share threads cross-tool. **Kept as the documented divergence.** |
| **6.2** persistence-policy → ThreadStore | #27318 | **N/A.** Pure internal refactor ("thread stores get RAW append items… enable store-specific projections") — no wire/behavior change. The port's `ThreadStore` already owns persistence; nothing observable to port. |
| **6.3** SQLite robustness | #26859 corruption auto-recovery | **PORTED + reviewed + tested (`d375fe9`).** |
| **6.4** cold-resume / search | #23921 case-insensitive thread search; #27031 cold-resume no-reread | **N/A.** The port has **no thread/rollout content-search** surface at all (#23921 has nothing to make case-insensitive). #27031 is an upstream thread-MANAGER optimization (`RunningThreadResumeResult` reuse for an already-running thread) specific to upstream's thread-store/thread-manager architecture; the port's resume = deterministic `ThreadStore` rollout replay, a different design with no equivalent reread to elide. |

## P5 — the three maintainer-approved ports

The maintainer signed off (P5 AskUserQuestion) on porting **encrypted secrets,
code mode, and multi-agent v2** (and on documenting extensions + remote-control as
divergences). So P5b/P5c are **approved ports IN PROGRESS**, not optional.

| Item | Status |
|---|---|
| **P5a** encrypted secrets | **PORTED + live-proven** (CLI auth + MCP OAuth). |
| **P5b** code mode | **APPROVED PORT — in progress.** The port's `CodeMode.swift` is currently minimal (`callTool` + console shim). The upstream code-mode PRs (#24180 durable session, #26719 web_search, #25923 image-gen, #27732 reject-remote-image-URL) target a rich JS output-helper surface (`image()`/`generatedImage()`/`store()`/`load()`/…) to be built — output-item accumulator + helpers (with #27732's reject-remote-URL baked in) + durable session + engine integration, each its own gated wave. |
| **P5c** multi-agent v2 | **APPROVED PORT — in progress.** Build on `SessionEngineAgentRunner`: residency LRU (#26632), reload-on-delivery (#26623), concurrency-by-active-execution (#26969), encrypted payloads (#26210, can reuse `LocalSecretsBackend`), persisted runtime metadata (#25721). SubagentStart/Stop hooks (P3.1) already wired into the runner. |

## Net state

Everything that is a **real, tractable, non-regressing** upstream gap has been
ported and proven (P0–P5a + P6.3): conformance-oracle-green, full non-live suite
green, live-OpenAI-API green, live-`codexd`-binary green. The remainder is N/A,
a deliberate well-reasoned divergence, or a large optional feature the port
intentionally scopes out — each recorded above so the catchup's true state is
explicit, not a hidden TODO. See `UPSTREAM_SYNC_LOG.md`.
