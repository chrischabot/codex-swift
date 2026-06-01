# Web UI full-coverage build-out plan

Closing the gaps from `COVERAGE_AUDIT.md`: wire all CONNECT items, add backend
for Pin/Diff-rail/Automations/Plugin-metadata, fix the wired-but-broken items,
add UI for every backend-unused capability, and remove the few true-dead
placeholders.

**Key verified finding:** every read/action endpoint the audit flagged
**already exists** in `RequestRouter.swift` (model/list, config/_, account/_,
skills/mcp/hooks/plugins/marketplace lists, fuzzyFileSearch, thread/goal/_,
rollback, steer, review, shellCommand, remoteControl/_, environment/add, …). So
Chunks 1–4 are **connector-only** (no backend); only git-rail, automations, pin,
and plugin-metadata need new Swift (Chunks 5–8); Chunks 9–14 are new UI.

Serial only — build+test after each chunk; never parallel builds; shared files
(`connector-codex.ts`, `RequestRouter.swift`, `ClientRequest.swift`,
`Package.swift`, `App.tsx`) edited one chunk at a time.

## Rendering-fidelity pass (2026-05-31) — COMPLETE + browser-validated

A four-dimension audit (message rendering, settings, side panels/diffs, server-requests/realtime) found the transport was wired but rendering/panel accuracy was not. All P0–P2 items fixed in `www/` and validated in real Chrome (0 console errors):
- **Tool calls** (MCP/`web_search`) now route to `tool-call`/`web-fetch` blocks, not raw shell/JSON; reasoning reads `summary` (was blank on reload); `fileChange` diff blocks get real +/− counts.
- **`contextMessage` no longer dumped as JSON** on history reload (internal dev/skills/AGENTS context → filtered); history-load double-load race fixed with a synchronous guard.
- **Dropped notifications consumed**: `warning`/`model/verification` → toasts, `item/fileChange/patchUpdated` → live diff, `hook/*` → timeline, `account/*` → snapshot nudge.
- **Approvals**: `allow_always` → real `acceptForSession`; file-change card shows the patch (itemId-correlated); MCP **elicitation** + **permission** requests now render real cards (were auto-acked `{}`).
- **Side panels**: Plan/Inbox/Timeline now derive from live snapshot (were hardcoded samples); side panel un-gated (MCP/Tools/Timeline reachable without a diff); diff parser handles renames/binary/new-deleted + file badges + word-diff highlight; commit-message input in Review.
- **Settings**: General(approval/sandbox)/Configuration(model from `model/list` + reasoning effort + hide_agent_reasoning) are config-backed via `config/value/write`; MCP/Hooks/Environments show real data; experimental toggle payload fixed; Data-controls buttons wired.
- **Realtime**: `listVoices` nested-shape fix (19 voices), mic capture (PCM16 → `appendAudio`), transcript rendering + audio playback.
- **Capability fix (root cause):** the connector now negotiates `experimentalApi: true` on `initialize` — the backend gates `thread/goal/*`, `thread/realtime/*`, `remoteControl/*`, `collaborationMode/list` behind it, so those silently failed before. MethodGate allowlist remains the security boundary.
- Backend-limited (documented): agent-produced media (`imageView`/`imageGeneration`) wired defensively but never emitted by this backend; `thread/fork` has no worktree-target field; syntax highlighting in diffs deferred.

## Status — COMPLETE (all phases)
- ✅ **Phase 1** — connector quick wins (token-usage, model-switch, reasoning→thinking, live sidebar, unsubscribe, 686mo fix).
- ✅ **Phase 2** — connector wired to ALL existing endpoints; snapshot hydration (skills/MCP/hooks/plugins/apps show real data); `model/list` picker; `getDiff` via `turn/diff/updated`; `SendOptions` forwarding (model/approval pickers functional); QuestionBlock server-request flow; Settings account/usage/experimental. MethodGate allowlist expanded for the single-tenant full-UI surface.
- ✅ **Phase 3** — new backends: thread PIN (StateDB migration + `thread/pin/set`), git diff-rail (`git/action` via GitDiffRail.swift), automations (`AutomationStore` JSON persistence + `AutomationScheduler` interval ticker + `automation/action` CRUD+run), plugin-metadata (`plugin/*` already existed). All validated over WS.
- ✅ **Phase 4** — removed dead placeholders (Open in Finder, project Open-in-new-window); `ThreadToolsTab` (exec/fuzzy-find/goal/rollback/memory/realtime-voice) side-panel tab; automations page + git-rail buttons wired to backends; Settings sections live.
- Tests: `WebGatewayTests` 28/28 green. Builds: codexd + www clean. Browser regression: 0 console errors, chat round-trip works.
- Follow-up (documented, not blocking): realtime **live mic-audio** capture (text-mode realtime is wired); permissions/elicitation server-requests are auto-approved (single-tenant default) rather than carded.

## Chunks (serial)
1. **connector** — wire existing read endpoints: model/list, modelProvider/capabilities/read, config/read, account/read, account/rateLimits/read, skills/list, mcpServerStatus/list, collaborationMode/list, app/list, experimentalFeature/list. Add Connector interface signatures.
2. **connector** — wire fuzzyFileSearch(+sessions), thread/goal/{get,set,clear}, thread/memoryMode/set, memory/reset, thread/rollback, thread/inject_items, turn/steer, review/start, thread/shellCommand, config/value/write, config/batchWrite, config/mcpServer/reload, remoteControl/{status,enable,disable}, environment/add, experimentalFeature/enablement/set, plugin/{list,installed,read,install,uninstall}, marketplace/add.
3. **connector** — notification consumers: warning/deprecationNotice (toast), thread/status/changed|closed, item/fileChange/patchUpdated (streaming diff), item/reasoning/summary*, item/commandExecution/terminalInteraction. *(token-usage/model-switch/diff/started/archived already done.)*
4. **connector** — ✅ getDiff() (done) + getTimeline() from cached item/turn events.
5. **backend** — git diff-rail: `git/status,commit,push,createPullRequest,revert` in ClientRequest.swift + RequestRouter.swift via GitUtils (force-push filter, approval/sandbox gating) → connector wiring.
6. **backend** — automations: extend `SessionSupervisor.submit`→(ThreadId,TurnId); `Automation.swift`+`AutomationStore.swift`+`AutomationScheduler.swift` (Package.swift edit); `automation/{list,create,update,delete,run,status}`; codexd scheduler init/teardown → connector wiring (replace local-only).
7. **backend** — thread pin: StateDB `pinned` column + getters/upsert; ThreadStore `ThreadRow.pinned`; `ThreadSummary.pinned` (migration-safe); `thread/pin/{set,get}` → connector setThreadPinned + mapThread.
8. **backend** — plugin metadata: StateDB `plugin_metadata` table; `plugin/metadata/{list,sync}` (resolve plugin.json + mcp status + hooks/apps/skills) → connector wiring.
9. **UI** — FileBrowserTab, ExecPanel (thread/shellCommand), GoalEditorTab; mount in DiffPanel + routes.
10. **UI** — functional ModelSelector→turn/start (+approval/effort forwarding — the wired-broken SendOptions fix), ExperimentalFlags, ConfigEditor, Profile+BillingUsage, MemoryToggle, CollaborationModeSelector, Environment/RemoteDevice in Settings.
11. **UI** — Automations page repointed to the Chunk-6 backend + status polling.
12. **UI** — pinned indicator in thread list; Plugins/Manage consume plugin/metadata + sync.
13. **UI+backend** — PermissionCard, ElicitationForm, ToolCallUI wired to real `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request` (replace auto-ack `{}`); extend respondToApproval for `acceptForSession`.
14. **UI+backend** — RealtimeVoicePanel (`thread/realtime/*`); verify browser audio codecs. Last.

## Removals (true-dead placeholders only — NOT the features the user wants kept)
- Thread row "Open in Finder" (no host-shell endpoint), Project "Open in new window" toast. *(Pin, Diff-rail, Automations, PluginDetails are being ADDED, not removed.)*
