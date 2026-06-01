# JSON-RPC ⇄ Web-UI coverage audit

Bidirectional mapping between the app-server JSON-RPC surface and the shadcn web
UI, bridged by `www/src/runtime/connector-codex.ts`. Produced by a 9-agent audit
(2 backend enumerators, 5 UI walkers, synthesis, completeness critic). Verdicts
were spot-checked against `connector-codex.ts`.

## Coverage at a glance

- **155** backend endpoints (~110 client methods, ~40 notifications, ~12 server-requests) · **211** UI elements.
- **Wired live:** 11 client methods, 10 notifications, 2 server-requests (+`/api/upload` over HTTP). **~80% of the backend is unused capability.**
- Live methods: `initialize, thread/list, thread/resume, thread/read(includeTurns), thread/start, thread/fork, thread/archive, thread/unarchive, thread/name/set, turn/start, turn/interrupt`.
- Live notifications: `turn/started, turn/completed, item/started, item/completed, item/agentMessage/delta, item/reasoning/textDelta, item/commandExecution/outputDelta, turn/plan/updated, thread/name/updated, error`.
- Live server-requests: `item/commandExecution/requestApproval, item/fileChange/requestApproval` (all others auto-replied empty `{}`).

## A. Correctness gaps in the ALREADY-wired path (fix first — dead/decorative controls)

1. **`sendMessage` drops `SendOptions`** → the approval-mode picker and model/effort picker are decorative. Forward `opts.approval`→`turn/start.approvalPolicy` and `opts.modelTier`→`turn/start.effort`, `opts.modelLabel`→`turn/start.model`.
2. **`createThread` sends empty `thread/start {}`** → no project cwd / model. Forward project cwd + default model.
3. **`forkThread` ignores the worktree target** (signature drops it) → fork target chooser is inert.
4. **Reasoning**: summary deltas (`item/reasoning/summaryTextDelta`, `summaryPartAdded`) are dropped; text deltas render as markdown unless an `item/started` reasoning item precedes them.
5. **`subscribeThread` unsubscribe is a no-op** → `thread/unsubscribe` never called; sinks accumulate.
6. **Silent auto-ack of interactive server-requests** (`item/tool/requestUserInput`, `item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`) → QuestionBlock / permission / elicitation flows never function.
7. **`respondToApproval` collapses decisions** to accept/decline/cancel → the "Allow always" button can't send `acceptForSession`.

## B. REMOVE — UI with no backend source (no endpoint can power it)

| UI element | Why |
|---|---|
| **Pin chat** (`setThreadPinned`) | No-op; no pin endpoint exists. Demote to localStorage or remove. |
| **Diff-rail Commit / Commit&push / +PR / Revert** | "coming soon" toasts; no git-write endpoint anywhere (`gitDiffToRemote` is dead deprecated-v1). |
| **Automations page + edit page** | No automation/cron/scheduler endpoint anywhere; connector methods are volatile in-memory snapshot mutations lost on reload. |
| **Thread row "Open in Finder"** | Toast; no `fs/reveal`/host-shell endpoint. |
| **Project "Open in new window"** | Toast placeholder (the thread-level one does `window.open`). |
| **PluginDetailPage static sections + "Claudette" sample** | Hardcoded arrays, not tied to any data model. |
| **Settings → Data controls → "Export"** | No-op; no export endpoint. |

## C. CONNECT — orphan UI with an existing backend endpoint to wire

| UI element | Backend endpoint | How |
|---|---|---|
| Approval-mode picker | `turn/start.approvalPolicy` | forward `SendOptions` |
| Model / effort picker | `model/list` + `turn/start.model/effort` | populate from `model/list`; forward opts |
| Thinking block + reasoning summary | `item/reasoning/{textDelta,summaryTextDelta,summaryPartAdded}` | seed thinking block; handle summary cases |
| Token-usage block | `thread/tokenUsage/updated` | add handler → token-usage block |
| Model-switch block | `model/rerouted` | add handler → model-switch block |
| Side-panel DIFF / REVIEW / `getDiff()` | `turn/diff/updated` | track latest unified diff; parse → DiffFile[] |
| Inbox tab (pending approvals) | the two `requestApproval` server-requests | push into a `pendingApprovals` snapshot array |
| QuestionBlock | `item/tool/requestUserInput` | build question form; reply `RequestUserInputResponse` |
| Elicitation card | `mcpServer/elicitation/request` | route to elicitation form |
| Permission/allow-network card | `item/permissions/requestApproval` | build permissions card; reply `RequestPermissionsResponse` |
| Mission block + goal controls | `thread/goal/{get,set}` + `thread/goal/updated` | fetch on open; subscribe; add set-objective control |
| @-mention Files | `fuzzyFileSearch` (+ session variants) | replace static list with search |
| @-mention Skills/Plugins/Apps/Agents | `skills/list, mcpServerStatus/list, app/list, collaborationMode/list` | populate from list RPCs |
| /clear, /title, /review slash cmds | `thread/compact/start, thread/name/set, review/start` | replace coming-soon toast |
| Plugins page/manage/detail/marketplace | `plugin/{list,installed,read,install,uninstall}, marketplace/*` | populate + wire toggle (currently no-op) |
| Manage → MCPs (+ status/reload/OAuth) | `mcpServerStatus/list, mcpServer/startupStatus/updated, config/mcpServer/reload, mcpServer/oauth/login` | populate + live badges |
| Manage → Skills (+ toggle) | `skills/list, skills/changed, skills/config/write` | populate + persist toggle |
| Manage → Hooks (+ live runs) | `hooks/list, hook/started, hook/completed` | populate + live run feed |
| Settings → Agent/General config | `config/read, config/value/write, config/batchWrite` | hydrate + persist switches |
| Settings → Profile/Connections/Usage | `account/read, account/rateLimits/read` (+ `updated`) | connect account + rate limits |
| Settings → Clear cache / Delete all chats | `memory/reset`, loop `thread/archive` | wire actions |
| "Connect a device" | `remoteControl/{status/read,enable,disable}` | enrollment flow |
| Settings → Environments | `environment/add` | wire Add-environment |
| Working-dir pill / git branch | `thread/start` result cwd + `thread/metadata/update` | show real cwd + git sha/branch |
| subscribeThread teardown | `thread/unsubscribe` | call on unsubscribe |
| Live sidebar (new/changed/archived threads) | `thread/started, thread/status/changed, thread/archived, thread/unarchived` | add handlers → upsert snapshot threads |

## D. BACKEND UNUSED — capabilities with no UI (grouped)

- **Turn control:** `turn/steer` (mid-turn steering), `review/start` (REVIEW tab), `thread/rollback` (undo N turns), `thread/inject_items` (paste-as-context), `thread/shellCommand` (user-shell terminal), `thread/increment/decrement_elicitation` (pause/resume), `thread/approveGuardianDeniedAction`.
- **Models/config:** `model/list`, `modelProvider/capabilities/read`, `config/{read,value/write,batchWrite}`, `experimentalFeature/{list,enablement/set}`, `configRequirements/read`.
- **Account:** `account/{read,rateLimits/read,login/start,login/cancel,logout,sendAddCreditsNudgeEmail}` (+ `updated`, `login/completed`).
- **Extensions surface:** `skills/list` (+`changed`,`config/write`), `mcpServerStatus/list` (+`startupStatus/updated`), `mcpServer/{tool/call,resource/read,oauth/login}`, `collaborationMode/list`, `app/list`, `plugin/*`, `marketplace/*`, `hooks/list` (+`hook/started`,`hook/completed`), `externalAgentConfig/{detect,import}`, `feedback/upload`.
- **Filesystem/exec:** `fs/{readFile,writeFile,readDirectory,getMetadata,createDirectory,copy,remove,watch,unwatch}` (+`fs/changed`), `fuzzyFileSearch` (+ session + `sessionUpdated`/`sessionCompleted`), `command/exec` (+write/terminate/resize), `process/spawn` (+stdin/kill/resize, `process/outputDelta`/`exited`).
- **Goals/memory:** `thread/goal/{set,get,clear}` (+`updated`/`cleared`), `thread/memoryMode/set`, `memory/reset`.
- **Realtime/voice:** `thread/realtime/{listVoices,start,appendText,appendAudio,stop}` — no UI at all.
- **Remote/env:** `remoteControl/{enable,disable,status/read}`, `environment/add`, `config/mcpServer/reload`, `thread/metadata/update`, `thread/backgroundTerminals/clean`.
- **Notifications with no consumer:** `turn/diff/updated`, `thread/tokenUsage/updated`, `model/rerouted`, `thread/{status/changed,archived,unarchived,started,closed}`, `warning`, `deprecationNotice`, `serverRequest/resolved`, `item/fileChange/patchUpdated`, `item/reasoning/summary*`, `item/commandExecution/terminalInteraction`, `item/autoApprovalReview/{started,completed}`, `model/verification`.
- **Server-requests auto-acked (functionally unmet):** `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`.

## Notes

- The wired core (chat send/stream/approval, thread list/open/rename/archive, uploads) is correct and validated; this audit is about *breadth*.
- The mock connector (`connector-mock.ts`) shows the UI's full *intended* surface — most "orphan-connectable" items already have a mock shape, so wiring is mostly connector-side.
