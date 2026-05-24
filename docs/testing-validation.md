# Testing and Validation Guide

CodexKit's test strategy is evidence-driven: write a reproducer, make it pass,
then run the broadest relevant gate before calling behavior complete.

## Test layers

Focused unit tests:

- `InfraPrimitivesTests`
- `WireProtocolTests`
- `ProtocolModelTests`
- `PromptsTests`
- `PersistenceTests`
- `ModelClientTests`
- `HarnessCoreTests`
- `ToolsTests`
- `MCPTests`
- `SkillsTests`
- `ConnectorsTests`
- `ExtensionAPITests`
- `BrokerTests`
- `AuthTests`
- `TokenizerTests`
- `ConfigTests`
- `ObservabilityTests`

Integration and adversarial tests:

- `IntegrationTests`
- `AdversarialTests`
- `LiveTests`

Release and e2e gates live under `tools/e2e/` and `scripts/`.

## Everyday commands

```sh
swift build
swift test
swift build -c release
swift test --filter 'EndToEndTests.testName'
swift test --filter 'EndToEndTests|AuthTests|SocketServerTests|SupervisorResourceTests|SpawnWorkerTests|ResumeTests'
```

The focused app-server regression set above is useful after touching
`RequestRouter`, transport, auth, process execution, subscriptions, or worker
supervision.

## E2E gates

Important gates:

- `tools/e2e/g0_baseline.sh`: release build, non-live tests, wire smokes, and
  live stdio smoke when credentials exist.
- `tools/e2e/g1_transport.sh`: transport and app-server listener behavior.
- `tools/e2e/g2_model_persistence.sh`: model and persistence/resume behavior.
- `tools/e2e/g3_tools_sandbox.sh`: tools, sandbox, and exec policy.
- `tools/e2e/g4_auth_broker_memories.sh`: auth, broker, MCP, and memories.
- `tools/e2e/g5_full_corpus.sh`: schema oracle, transcript replay,
  deterministic corpus, and live OpenAI suite when configured.
- `tools/e2e/g6_lifecycle.sh`: packaging, signing, lifecycle install/status,
  restart survival.
- `tools/e2e/g6_clean_machine.sh`: empty-root install and purge.
- `tools/e2e/g6_blue_green.sh`: versioned worker promote/rollback.
- `tools/e2e/g6_reboot_resume.sh`: durable resume after launchd restart.
- `tools/e2e/g6_true_reboot_resume.sh`: two-phase real reboot gate.
- `tools/e2e/g6_active_turn_crash.sh`: daemon crash during active turn.
- `tools/e2e/g6_poison_worker.sh`: bad worker containment.
- `tools/e2e/g6_physical_footprint.sh`: physical-footprint enforcement
  evidence.
- `tools/e2e/g6_soak.sh`: soak/noisy-neighbor/liveness/perf evidence.
- `tools/e2e/g9_final_rehearsal.sh`: final release evidence rehearsal.

## Live OpenAI validation

Live tests require `OPENAI_API_KEY`. They are intentionally more expensive and
should be used for behavior that depends on the real Responses API, auth
refresh, multi-turn coding sessions, multiple concurrent sessions, or model
tool use.

Before claiming a live-sensitive behavior:

1. Run the smallest live test that exercises the path.
2. Run `tools/e2e/g5_full_corpus.sh` with `OPENAI_API_KEY`.
3. Confirm the live count reported by the gate and update `STATUS.md`.
4. Root-cause any live failure. Do not tune prompts or loosen assertions
   without preserving the original behavior being tested.

## App-server parity validation

For official app-server changes:

1. Fetch the current official docs:

   ```sh
   # Use the OpenAI developer docs MCP in Codex, or official docs only.
   https://developers.openai.com/codex/app-server
   ```

2. Compare method names with `Sources/ProtocolModel/V2.swift`.
3. If a method is already in the registry, check whether it has concrete
   behavior in `Sources/Supervisor/RequestRouter.swift` or is still a generic
   default response.
4. Add tests for the real behavior, not just the method string.
5. Run schema parity:

   ```sh
   tools/conformance/bootstrap.sh
   tools/conformance/diff.sh
   ```

6. Run `tools/e2e/g5_full_corpus.sh`.

The pinned Codex oracle is part of this gate. If Cargo stalls while building
the oracle, the known workaround is:

```sh
CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build -p codex-cli --bin codex
```

## Severe testing checklist

Use this checklist for high-risk changes:

- Focused reproducer test fails before the fix.
- Focused reproducer passes after the fix.
- Related integration group passes.
- Release build passes.
- Schema/conformance gate passes when protocol is touched.
- Live OpenAI gate passes when model/auth behavior is touched.
- Multi-session behavior is exercised when supervisor/worker/session code is
  touched.
- Connection close, cancellation, duplicate request, malformed params, and
  no-initialize cases are covered for new app-server methods.
- Persistence is verified after restart/resume for anything durable.
- Resource isolation is verified for worker, process, or long-running turn
  changes.
- Docs and status reflect what is actually implemented.

## Recent verified app-server slice

On 2026-05-21, watched local skill-file notifications were added and verified:

- `swift test --filter 'EndToEndTests.testSkillsChangedEmitsWhenWatchedSkillFileChanges'`
  passed.
- `swift test --filter 'EndToEndTests|AuthTests|SocketServerTests|SupervisorResourceTests|SpawnWorkerTests|ResumeTests'`
  passed with 97 tests. Later runs after backend rate-limit fetching and
  managed device-code login passed with 98 and 101 tests respectively; the
  browser OAuth callback completion slice later passed with 103 tests.

This closed the official-doc `skills/changed` watcher gap for local watched
skill roots. Remaining official-doc app-server gaps are listed in
[app-server-api.md](app-server-api.md).

The same day, `account/rateLimits/read` was changed from a local empty
snapshot to a ChatGPT-auth-gated backend fetch path:

- `swift test --filter 'EndToEndTests.testAccountRateLimitsReadReturnsAndEmitsSnapshot|EndToEndTests.testAccountRateLimitsRequireChatGPTAuth'`
  passed.
- `swift test --filter 'EndToEndTests|AuthTests|SocketServerTests|SupervisorResourceTests|SpawnWorkerTests|ResumeTests'`
  passed with 98 tests.

The same day, managed `chatgptDeviceCode` login was added:

- `swift test --filter 'EndToEndTests.testAccountDeviceCodeLoginCompletesAndPersistsChatGPTAuth|EndToEndTests.testAccountDeviceCodeLoginFailureEmitsCompletionWithoutPersisting|EndToEndTests.testAccountDeviceCodeLoginCancelStopsCompletionAndDoesNotPersist|EndToEndTests.testAccountLoginCancelAndLogoutEmitDocumentedNotifications'`
  passed.
- `swift test --filter 'EndToEndTests|AuthTests|SocketServerTests|SupervisorResourceTests|SpawnWorkerTests|ResumeTests'`
  passed with 101 tests.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 245 deterministic tests, and 28 live OpenAI tests.

The same day, managed browser OAuth callback completion was added:

- `swift test --filter 'EndToEndTests.testAccountBrowserLoginCallbackCompletesAndPersistsChatGPTAuth|EndToEndTests.testAccountBrowserLoginCallbackFailureDoesNotPersist|EndToEndTests.testAccountLoginCancelAndLogoutEmitDocumentedNotifications'`
  passed.
- `swift test --filter 'EndToEndTests|AuthTests|SocketServerTests|SupervisorResourceTests|SpawnWorkerTests|ResumeTests'`
  passed with 103 tests.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 247 deterministic tests, and 28 live OpenAI tests.

The same day, `memory/reset` was changed from a wire-default response into a
real durable-memory clear, and a process-streaming race was fixed so
`process/exited` is sent after stdout/stderr drain tasks complete:

- `swift test --filter 'EndToEndTests.testMemoryResetClearsDurableMemories'`
  passed.
- `swift test --filter 'EndToEndTests.testProcessSpawnWriteKillAndNotifications|EndToEndTests.testProcessSpawnTTYResizeAndExitNotification|EndToEndTests.testMemoryResetClearsDurableMemories'`
  passed.
- `swift test --filter 'EndToEndTests|HarnessCoreTests|LiveDeepTests.testLiveMemoryToolCitation'`
  passed with 113 tests, including one live OpenAI memory-tool citation test.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 249 deterministic tests, and 28 live OpenAI tests.

The same day, local `plugin/read` and shared local `plugin/skill/read` were
changed from generic placeholder responses into concrete bundle reads:

- `swift test --filter 'EndToEndTests.testPluginReadAndSkillReadReturnLocalBundleContents'`
  passed.
- `plugin/read` now covers both `marketplacePath` and configured
  `remoteMarketplaceName` lookup and reports skill enablement from persisted
  `[skills].config`.
- `swift test --filter 'EndToEndTests.testMarketplaceAddInstallUpgradeUninstallRemoveRoundTrip|EndToEndTests.testPluginShareSaveListUpdateCheckoutDeleteRoundTrip|EndToEndTests.testExternalAgentPluginDetectImportListAndIdempotency|EndToEndTests.testPluginReadAndSkillReadReturnLocalBundleContents|EndToEndTests.testSkillsConfigWritePersistsAndEmitsSkillsChanged'`
  passed with 5 tests.
- `swift test --filter EndToEndTests` passed with 51 tests.
- `swift test --filter 'EndToEndTests|HarnessCoreTests|LiveDeepTests.testLiveMemoryToolCitation'`
  passed with 114 tests.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 249 deterministic tests, and 28 live OpenAI tests.

The same pass also expanded the full streamed-turn E2E to cover experimental
stored turn history retrieval:

- `thread/turns/list` returns the persisted completed turn with full items.
- `thread/turns/items/list` returns the persisted assistant item for that
  turn.

The same day, `getConversationSummary` was changed from a synthetic generic
default into a real local-thread summary lookup:

- `swift test --filter EndToEndTests.testGetConversationSummaryReturnsStoredThreadByIdAndRolloutPath`
  passed.
- `swift test --filter EndToEndTests` passed with 52 tests.
- Coverage verifies `conversationId` lookup, `rolloutPath` lookup, persisted
  preview/cwd/timestamps/path/source/model-provider/CLI-version/git-info, and
  missing-thread error behavior. It also locks the upstream untagged-union
  precedence: when both params are present, `rolloutPath` wins.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 251 deterministic tests, and 28 live OpenAI tests.

The same day, `gitDiffToRemote` was changed from a synthetic empty generic
default into a real git diff response:

- `swift test --filter EndToEndTests.testGitDiffToRemoteReturnsRealShaAndDiff`
  passed.
- `swift test --filter EndToEndTests` passed with 53 tests.
- Coverage creates a real git repo, plants an `origin/main` remote ref,
  modifies a tracked file, adds an untracked file, verifies the returned
  baseline SHA and diff content, and verifies non-repo failure.

The same day, `getAuthStatus` was changed from a generic placeholder and
credential-agnostic auth check into a concrete app-server compatibility
handler:

- `swift test --filter EndToEndTests.testGetAuthStatusMatchesAppServerCredentialContract`
  passed.
- `swift test --filter EndToEndTests.testGetAuthStatusRefreshesChatGPTBearerAndOmitsTokenOnRefreshFailure`
  passed.
- `swift test --filter EndToEndTests` passed with 55 tests.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 253 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies no-auth state, API-key `apikey` reporting, token omission
  unless `includeToken` is true, API-key refresh no-op behavior, managed
  ChatGPT bearer refresh, stale-token omission after refresh failure, and token
  recovery once fresh credentials are persisted.

The same pass corrected `account/read` to match the documented app-server
account-state response instead of returning token-store internals:

- `swift test --filter EndToEndTests.testAccountReadReturnsDocumentedAccountUnionShapes`
  passed.
- `swift test --filter EndToEndTests.testAccountReadUsesProviderRequiresOpenAIAuth`
  passed.
- `swift test --filter EndToEndTests` passed with 57 tests.
- Coverage verifies explicit `account: null`, API-key and ChatGPT account
  union shapes, absence of stale `authenticated`/`accountId` fields,
  ChatGPT email/plan extraction from token claims, `refreshToken` handling,
  and provider-level `requiresOpenaiAuth = false`.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 255 deterministic tests, and 28 live OpenAI tests.
- During the first full-corpus rerun, `testCommandExecRunsBufferedCommand`
  exposed a harness wait-budget mismatch: the product command timeout was
  5000 ms, but the test helper only waited 3000 ms under full-corpus load. The
  test now waits 10000 ms for the response while preserving the product
  timeout and real buffered stdout/stderr/exit behavior.

The same day, `account/sendAddCreditsNudgeEmail` was changed from a generic
`sent` response into a real ChatGPT-backend action:

- `swift test --filter 'EndToEndTests.testSendAddCreditsNudgeEmailPostsThroughChatGPTBackend|EndToEndTests.testSendAddCreditsNudgeEmailAuthValidationCooldownAndFailure'`
  passed.
- `swift test --filter EndToEndTests` passed with 59 tests.
- `swift build -c release` passed.
- `swift test --filter SchemaParityTests` and `tools/conformance/diff.sh`
  passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 257 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies unauthenticated and API-key rejection, `creditType`
  validation, ChatGPT token/account/base-URL and credit-type propagation,
  `sent` response, HTTP 429 to `cooldown_active`, and backend-failure
  internal-error mapping.

The same day, `experimentalFeature/list` and
`experimentalFeature/enablement/set` were changed from static/default feature
responses into supervisor runtime state:

- `swift test --filter 'EndToEndTests/testExperimentalFeature'` passed with 3
  tests.
- `swift test --filter EndToEndTests` passed with 62 tests.
- `swift build -c release`, `swift test --filter SchemaParityTests`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 260 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies listed feature metadata and default state, boolean
  runtime updates, `config/read` overlay behavior, empty enablement no-op
  responses, rejection of unsupported canonical keys, rejection of legacy
  aliases with canonical-key guidance, rejection of unknown keys, rejection of
  non-boolean values, and `apps` enablement gating plus `app/list/updated`.

The same day, `collaborationMode/list` was changed from an empty placeholder
into the upstream built-in preset list:

- `swift test --filter EndToEndTests/testCollaborationModeListReturnsBuiltInPresetsInStableOrder`
  passed.
- `swift test --filter EndToEndTests` passed with 63 tests.
- `swift build -c release`, `swift test --filter SchemaParityTests`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 261 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies the stable Plan then Default order, `mode` values, null
  model fields, Plan's `medium` reasoning effort, and Default's null reasoning
  effort.

The same pass replaced the static `remoteControl/*` generic response with
router-owned stateful app-server behavior, and the follow-up passes closed the
enrollment-response, remote-control target-normalization, websocket handshake,
and enable/disable race gaps:

- `swift test --filter 'EndToEndTests/testRemoteControl'` passed with 7
  tests.
- `swift test --filter EndToEndTests` passed with 79 tests.
- `swift build -c release`, `swift test --filter ProtocolModelTests`,
  `swift test --filter HarnessCoreTests`, `swift test --filter PersistenceTests`,
  and `tools/conformance/diff.sh` passed.
- The then-current `tools/e2e/g5_full_corpus.sh` passed with schema/oracle
  parity, transcript replay, deterministic corpus coverage, and 28 live OpenAI
  tests.
- Coverage verifies `status/read` returns `disabled` plus nonempty
  `serverName` and persisted `installationId`, `enable` requires ChatGPT-style
  auth and rejects missing/API-key auth, `enable` transitions to
  `connecting`, emits `remoteControl/status/changed`, and starts enrollment
  with the configured ChatGPT backend base URL, token, account id,
  installation id, and server name. The default HTTP enroller now parses
  `server_id`/`environment_id`, publishes the returned `environmentId`, and
  tests the exact enrollment path and headers against a local HTTP capture
  server. Target-normalization coverage matches the Rust oracle for HTTPS
  `chatgpt.com`/`chatgpt-staging.com` hosts and subdomains, HTTP/HTTPS
  `localhost`, derived `ws`/`wss` websocket URLs, and rejection of unsupported
  or insecure hosts. The websocket boundary now builds the upstream handshake
  headers, publishes `connected` after connector success, publishes `errored`
  after connector failure, closes the active connection on disable, and ignores
  late enrollment/connect completions after disable. Enrollment failure records
  `errored` and emits a status-change notification. `disable` returns to
  `disabled` while preserving identity and notifying clients.
- At that point, remote-control websocket envelope routing was still the next
  implementation target and was not claimed.

The next pass implemented and tested non-segmented remote-control websocket
envelope routing:

- `swift test --filter 'EndToEndTests/testRemoteControl' --disable-sandbox`
  passed with 8 tests.
- `swift test --filter EndToEndTests --disable-sandbox` passed with 80 tests.
- `swift build -c release --disable-sandbox`, `swift test --filter
  ProtocolModelTests --disable-sandbox`, `swift test --filter HarnessCoreTests
  --disable-sandbox`, `swift test --filter PersistenceTests --disable-sandbox`,
  and `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 278 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies remote `client_message` envelopes create isolated virtual
  app-server clients keyed by `client_id`/`stream_id`, route `initialize` and
  `model/list` through a child router, emit `server_message` envelopes with
  increasing server sequence ids, suppress duplicate inbound sequence ids,
  answer `ping` with `pong(active)` while the virtual client exists, process
  `client_closed`, and then answer `ping` with `pong(unknown)`.
- Remaining limitation: ack/replay buffering, chunk
  segmentation/reassembly, idle/pong timeout sweeping, and the remote
  environment data path remain open before claiming full ChatGPT
  remote-control parity.

The follow-up pass implemented and tested remote-control chunking and acked
outbound-buffer pruning:

- `swift test --filter 'EndToEndTests/testRemoteControl' --disable-sandbox`
  passed with 9 tests.
- `swift test --filter EndToEndTests --disable-sandbox` passed with 81 tests.
- `swift build -c release --disable-sandbox`, `swift test --filter
  ProtocolModelTests --disable-sandbox`, and `tools/conformance/diff.sh`
  passed.
- The then-current `tools/e2e/g5_full_corpus.sh` passed with schema/oracle
  parity, transcript replay, deterministic corpus coverage, and 28 live OpenAI
  tests.
- Coverage verifies an out-of-order `client_message_chunk` does not open a
  virtual client, ordered chunks reassemble into `initialize`, a large remote
  `command/exec` response splits into multiple `server_message_chunk`
  envelopes, the chunks decode back into the original JSON-RPC response, and
  all chunks retain the correct `client_id`/`stream_id`.
- At that point, websocket reconnect/replay from the outbound buffer,
  idle/pong timeout sweeping, and the remote environment data path were still
  open before claiming full ChatGPT remote-control parity.

The next pass implemented and tested reconnect replay from the outbound
buffer:

- `swift test --filter 'EndToEndTests/testRemoteControl' --disable-sandbox`
  passed with 10 tests.
- `swift test --filter EndToEndTests --disable-sandbox` passed with 82 tests.
- `swift build -c release --disable-sandbox`, `swift test --filter
  ProtocolModelTests --disable-sandbox`, and `tools/conformance/diff.sh`
  passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 280 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies a websocket close preserves the remote virtual client,
  opens a second websocket connection, rebinds the child connection, and
  replays only the unacked `server_message` envelope after a prior `ack`
  removed the acknowledged initialize response.
- At that point, idle/pong timeout sweeping and the remote environment data path
  were still open before claiming full ChatGPT remote-control parity.

The next pass implemented and tested idle-client sweeping plus websocket
heartbeat/pong-failure reconnect:

- `swift test --filter
  EndToEndTests/testRemoteControlIdleSweepClosesInactiveVirtualClients
  --disable-sandbox` passed.
- `swift test --filter
  EndToEndTests/testRemoteControlWebSocketHeartbeatFailureReconnects
  --disable-sandbox` passed.
- `swift test --filter 'EndToEndTests/testRemoteControl' --disable-sandbox`
  passed with 12 tests.
- `swift test --filter EndToEndTests --disable-sandbox` passed with 85 tests.
- `swift test --filter ProtocolModelTests --disable-sandbox`, `swift build -c
  release --disable-sandbox`, and `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 283 deterministic tests, and 28 live OpenAI tests.
- `swift test --filter EndToEndTests/testRemoteExecServerReadToolsReconnectAfterWebSocketClose --disable-sandbox`
  passed after the shared exec-server JSON-RPC client was changed to reset stale
  websocket state and retry replay-safe reads after reconnect.
- Coverage verifies an inactive remote virtual client is swept and a later
  `ping` returns `pong(unknown)`, websocket ping failure closes the connection
  and reconnects, and broad E2E ordering keeps the initial
  `connecting(null)` status notification before enrollment-specific
  `connecting(environmentId)` status even under full-suite scheduling.
- At that point, the remote environment data path was still open before claiming
  full ChatGPT remote-control parity.

During this validation pass, `tools/conformance/transcript_replay.py`
root-caused an intermittent `item/completed` timeout to the replay harness
dropping notifications that arrived before a request response. The harness now
buffers those pre-response notifications for later `waitNotification` steps;
targeted `tools/conformance/replay.sh` and the full `g5_full_corpus.sh` rerun
both passed. A later `g5` run also exposed that the new local HTTP capture
server test could block forever on helper-process exit after the request had
already been captured; the test now waits for the captured request file with a
timeout and terminates the helper in cleanup.

The next app-server pass aligned thread archive notifications with the
documented upstream behavior:

- `swift test --filter EndToEndTests/testThreadArchiveUnarchivePersistAndNotify`
  passed.
- `swift test --filter EndToEndTests` passed with 66 tests.
- `swift build -c release`, `swift test --filter SchemaParityTests`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 264 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies `thread/archive` persists the archived state, removes the
  thread from active `thread/list`, includes it in archived `thread/list`, and
  emits `thread/archived` with `threadId`; `thread/unarchive` returns the
  restored thread, emits `thread/unarchived`, and restores the thread to the
  active list.

The next pass replaced the static out-of-band elicitation placeholder with
stateful per-thread counter behavior:

- `swift test --filter EndToEndTests/testThreadElicitationCounterIsStatefulAndValidated`
  passed.
- `swift test --filter EndToEndTests` passed with 67 tests.
- `swift build -c release`, `swift test --filter SchemaParityTests`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 265 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies increment count/paused transitions `1/true` and `2/true`,
  decrement transitions `1/true` and `0/false`, invalid-request on decrement
  at zero, and invalid-request for unknown thread ids.
- Remaining limitation: this proves app-server request state. Local process
  deadline extension while paused is not claimed until specifically wired and
  tested.

The next pass replaced `environment/add`'s generic empty response with a
stateful remote-environment registry, then added the remote exec-server data
path for the core model-visible tools:

- `swift test --filter EndToEndTests/testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath --disable-sandbox`
  passed.
- After remote `unified_exec` was added, the same focused E2E was re-run and
  passed, proving remote interactive process open and continuation in the
  remote-bound session.
- `swift test --filter EndToEndTests/testRemoteControlWebSocketReassemblesClientChunksAndSplitsLargeServerMessages --disable-sandbox`
  passed after the full corpus exposed a fragile seq-id assumption and a brittle
  shell-pipeline output producer; the test now reassembles the chunked response
  by JSON-RPC response id, uses deterministic Python output with a wider wait
  budget under suite load, and sends the required virtual-client `initialized`
  notification before follow-up app-server requests.
- `swift test --filter ProtocolModelTests --disable-sandbox` passed.
- `swift test --filter EndToEndTests --disable-sandbox` passed with 85 tests.
- `swift build -c release --disable-sandbox` and `tools/conformance/diff.sh`
  passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 283 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies experimental gating, invalid id rejection, empty URL
  rejection, successful registration response shape, local environment
  selection acceptance, unknown environment rejection, registered remote
  environment selection, exec-server websocket initialization, remote
  `process/start`/`process/read` routing for model `shell`, remote
  `unified_exec` process-id mapping, PTY-style `process/start`, bounded
  `process/read`, continuation input over `process/writeStdin`, and persisted
  open/continue tool-output readback, remote
  `fs/readFile`/`fs/writeFile`/`fs/readDirectory` routing for file tools,
  recursive remote `file_search` over `fs/readDirectory`, remote
  `apply_patch` update/add/delete replay over `fs/readFile`, `fs/getMetadata`,
  `fs/createDirectory`, `fs/writeFile`, and `fs/remove`, remote cwd propagation,
  remote `git_diff` repo detection, upstream merge-base diffing, untracked diff
  inclusion, persisted command-output readback, and persisted remote
  `file_search`, `apply_patch`, and `git_diff` tool-output readback.
- Remaining limitation: this proves `shell`, `unified_exec`, `read_file`,
  `write_file`, `list_dir`, `file_search`, `apply_patch`, and `git_diff` over
  the remote exec-server websocket plus replay-safe read reconnect. Full
  upstream parity for HTTP/MCP network path, automatic replay for
  non-idempotent remote writes/process starts, full active-process resume, and
  turn-scope environment switching is still open.

The next pass hardened and proved the app-server special thread task routes
for `thread/shellCommand` and `thread/compact/start`:

- `thread/shellCommand` now trims commands and rejects empty commands with the
  upstream `command must not be empty` invalid-request error.
- `swift test --filter EndToEndTests/testThreadShellCommandAppServerValidatesRunsAndPersists`
  passed.
- `swift test --filter EndToEndTests/testThreadCompactStartAppServerStreamsAndPersistsCompaction`
  passed.
- `swift test --filter EndToEndTests` passed with 70 tests.
- `swift test --filter SchemaParityTests`,
  `swift test --filter ProtocolModelTests`, `swift build -c release`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 268 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies app-server response shape, shell notification streaming,
  persisted trimmed `commandExecution` output/exit code, manual compaction
  notification streaming, `thread/compacted`, and persisted model-produced
  compacted history.

The next pass replaced `thread/backgroundTerminals/clean`'s schema-only `{}`
default with a concrete validated boundary:

- `swift test --filter EndToEndTests/testThreadBackgroundTerminalsCleanIsGatedValidatedAndThreadScoped`
  passed.
- `swift test --filter AuthGatingAdversarialTests` passed with 7 tests.
- `swift test --filter EndToEndTests` passed with 71 tests.
- `swift test --filter SchemaParityTests`, `swift build -c release`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 269 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies experimental gating, missing `threadId`, malformed thread
  id, well-formed unknown thread rejection, and successful `{}` only for a real
  loaded thread. The accepted path is explicitly a no-op until Swift grows a
  Rust-style unified-exec background-terminal registry.

The next pass made `config/mcpServer/reload` schema-faithful and stateful:

- Root cause: reload stopped MCP clients but left old status entries in
  `McpManager`, so removed servers could still appear in `mcpServerStatus/list`.
  The route also returned status-shaped `data` even though the pinned response
  policy for `config/mcpServer/reload` is `{}`.
- `McpManager.stopAll()` now clears clients and statuses, and
  `config/mcpServer/reload` returns `{}` after reloading current disk config.
- `swift test --filter EndToEndTests/testConfigMcpServerReloadClearsStaleServersAndLoadsNewConfig`
  passed.
- `swift test --filter EndToEndTests` passed with 72 tests.
- `swift test --filter MCPTests` passed with 19 tests.
- `swift test --filter SchemaParityTests`, `swift build -c release`, and
  `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 270 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies a configured MCP server is initially visible, rewriting
  `mcp.json` and reloading removes the old server, the newly configured server
  is listed and callable, removed server calls fail, and the app-server error
  preserves actionable MCP error text.

The next pass hardened `thread/inject_items` from durable-only best-effort
storage into a loaded-session mutation:

- Root cause: the router used `try?` around `store.injectItems`, accepted
  unknown well-formed thread ids, and did not update a bound worker's in-memory
  context. A loaded session could therefore miss injected items until
  unload/resume.
- `thread/inject_items` now rejects malformed and unknown thread ids, persists
  injected items with a completed synthetic turn boundary, and submits mapped
  assistant text to the bound worker context.
- `swift test --filter EndToEndTests/testThreadInjectItemsValidatesPersistsAndUpdatesLoadedContext`
  passed.
- `swift test --filter EndToEndTests` passed with 73 tests.
- `swift test --filter PersistenceTests` passed with 7 tests.
- `swift test --filter HarnessCoreTests` passed with 62 tests.
- `swift test --filter ProtocolModelTests` passed with 14 tests.
- `swift build -c release --disable-sandbox` passed.
- `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 271 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies malformed id rejection, unknown-thread rejection, `{}`
  success for a real loaded thread, durable completed injected history, and the
  next loaded-session model prompt containing injected assistant text.

The next pass hardened `thread/rollback` from silent best-effort persistence
into a validated durable-plus-loaded-context mutation:

- Root cause: the router used `try?` around `store.rollback`, so malformed
  storage failures and unknown threads could collapse into an apparently
  successful empty rollback response. It also did not update a bound worker's
  in-memory context, so a loaded session could continue sending rolled-back
  turns to the model until unload/resume.
- `thread/rollback` now rejects malformed ids, unknown threads, and
  `numTurns < 1`, propagates store errors as invalid-request messages, rewrites
  durable rollout history, and drops the matching user turn from any bound
  worker context.
- `swift test --filter EndToEndTests/testThreadRollbackValidatesPersistsAndUpdatesLoadedContext`
  passed.
- `swift test --filter EndToEndTests` passed with 74 tests.
- `swift test --filter PersistenceTests` passed with 7 tests.
- `swift test --filter HarnessCoreTests` passed with 62 tests.
- `swift test --filter ProtocolModelTests` passed with 14 tests.
- `swift build -c release --disable-sandbox` passed.
- `tools/conformance/diff.sh` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 272 deterministic tests, and 28 live OpenAI tests.
- Coverage verifies malformed id rejection, unknown-thread rejection, invalid
  turn-count rejection, updated durable turn history, and the next
  loaded-session model prompt excluding the rolled-back user and assistant
  messages.

The follow-up pass replaced `plugin/installed`'s generic empty response with a
local installed/suggested plugin filter:

- `plugin/installed` returns installed local marketplace plugins.
- `plugin/installed` includes uninstalled local catalog entries named in
  `installSuggestionPluginNames`.
- `swift test --filter EndToEndTests.testMarketplaceAddInstallUpgradeUninstallRemoveRoundTrip`
  passed.
- `swift test --filter 'EndToEndTests.testMarketplaceAddInstallUpgradeUninstallRemoveRoundTrip|EndToEndTests.testPluginReadAndSkillReadReturnLocalBundleContents|EndToEndTests.testFullStreamedTurnEndToEnd'`
  passed with 3 tests.
- `swift test --filter EndToEndTests` passed with 51 tests.
- `swift build -c release` passed.
- `tools/e2e/g5_full_corpus.sh` passed with schema/oracle parity, transcript
  replay, 249 deterministic tests, and 28 live OpenAI tests.
