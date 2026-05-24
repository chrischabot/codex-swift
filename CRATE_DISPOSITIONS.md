# Crate dispositions (codex-rs → CodexKit)

Per implementation-plan §2. **RC** Reimplement-Core · **RT** Reimplement
Transport/Protocol · **RM** Replace-with-macOS · **OR** Oracle/test-only ·
**SK** Skip (non-macOS/unneeded) · **XF** Out-of-scope frontend.
State: ✅ shipped+tested · 🟦 portable core, macOS surface gated · ⛔ pending.

## Transport / protocol / server
| crate | disp | target | state |
|---|---|---|---|
| app-server | RT | Supervisor/RequestRouter | 🟦 (documented method registry, command/process PTY with exit-after-output ordering, documented `account/read` account unions, auth/account notifications, concrete `getAuthStatus`, managed ChatGPT browser callback and device-code login/cancel, external token refresh, ChatGPT-auth-gated backend rate-limit fetching and add-credits/usage-limit nudge emails, runtime `experimentalFeature/list` and `experimentalFeature/enablement/set` with config/app-list effects, built-in `collaborationMode/list` presets, stateful request-level `remoteControl/status/read`/`enable`/`disable` with Rust-oracle target normalization, ChatGPT enrollment response parsing, `environmentId` propagation, websocket handshake/header setup, connected/errored status transitions, disable race guarding, and remote-control websocket envelope routing through isolated virtual clients with `server_message`, `server_message_chunk`, `client_message_chunk` reassembly, `ping`/`pong`, `client_closed`, acked outbound-buffer pruning, reconnect replay of unacked server envelopes, duplicate sequence suppression, idle virtual-client sweeping, and websocket heartbeat/pong-failure reconnect, remote `environment/add` registration plus remote-bound session `shell`/`unified_exec`/`read_file`/`write_file`/`list_dir`/`file_search`/`apply_patch`/`git_diff` exec-server websocket data path with replay-safe read reconnect, documented `thread/archive`/`thread/unarchive` persistence plus notifications, stateful `thread/increment_elicitation`/`thread/decrement_elicitation` pause counter, app-server E2E-covered `thread/shellCommand` validation/streaming/persistence and `thread/compact/start` streaming/persistence, validated no-op `thread/backgroundTerminals/clean` boundary, loaded-context `thread/inject_items` persistence, loaded-context `thread/rollback` persistence, schema-faithful `config/mcpServer/reload` with stale-status clearing, skills config invalidation, watched skill-file `skills/changed`, durable `memory/reset`, local `plugin/installed`, local `plugin/read` by `marketplacePath` or configured `remoteMarketplaceName`, shared-plugin `plugin/skill/read`, real local `getConversationSummary` by thread id or rollout path, and real local/remote git diff coverage; remaining parity is full exec-server remote network/non-idempotent replay/active-process resume coverage plus any long-tail generic method real clients require) |
| app-server-transport | RT | Transport/StdioConnection | 🟦 (stdio ✅; UDS/WS macOS) |
| app-server-protocol | RT | WireProtocol/ProtocolModel | ✅ |
| app-server-daemon | RM | codexd + (launchd P6) | 🟦 |
| app-server-client / -test-client / debug-client | OR | IntegrationTests harness | ✅ |
| stdio-to-uds | RT | StdioConnection | 🟦 |
| uds | RM | UnixSocketListener / Transport | ✅ (portable POSIX UDS JSONL + UDS WebSocket, canonical control dir/socket permissions, real daemon smokes; Network.framework is optional future product shape only) |
| codex-client | OR/RC | test harness | ✅ |
| codex-experimental-api-macros | RT | WireProtocol/ExperimentalGate | ✅ |

## Core harness
| crate | disp | target | state |
|---|---|---|---|
| core | RC | HarnessCore | ✅ (turn loop/context/compaction); prompt parity P2/P7 |
| core-api / protocol | RC | ProtocolModel | ✅ |
| tools | RC | Tools | ✅ |
| state / thread-store / rollout / message-history | RC | Persistence | ✅ (on-disk byte-parity P2/P7) |
| rollout-trace | RC | (FlightRecorder analog) | 🟦 |
| core-skills / core-plugins / agent-graph-store | RC | (PluginsSkillsHooks) | ⛔ P5 |

## Model / API
| crate | disp | target | state |
|---|---|---|---|
| codex-api / model-provider / model-provider-info / backend-client / codex-backend-openapi-models / response-debug-context | RC | ModelClient | 🟦 (contract+mapper+retry+mock ✅; HTTP/WS client P2-M1) |
| models-manager | RC | Broker/CatalogCache | ✅ (cache/SWR ✅) |
| realtime-webrtc | RC | Realtime | 🟦 (app-server realtime list/start/appendText/appendAudio/stop with structural WebRTC SDP answer, transcript/audio/closed notifications, and E2E coverage; live provider WebRTC/audio transport remains P5) |
| lmstudio / ollama / responses-api-proxy | RC/SK | (providers) | ⛔ P8 |

## Auth / secrets
| crate | disp | target | state |
|---|---|---|---|
| login | RC | Broker/AuthRefreshBroker | 🟦 (coalescing ✅; OAuth flows P4-A1) |
| keyring-store / secrets | RM | Auth/TokenStore | ✅ (macOS Keychain-backed production store, legacy `auth.json` migration, explicit file fallback override, AuthTests coverage) |
| aws-auth / agent-identity / cloud-requirements | RC | (providers/policy) | 🟦 (`configRequirements/read` surfaces system requirements.toml, macOS MDM `requirements_toml_base64`, and legacy managed config constraints; cloud-fetched requirements, aws-auth, and agent-identity remain P8/P5) |

## Tools / exec / sandbox
| crate | disp | target | state |
|---|---|---|---|
| apply-patch | RC | Tools/ApplyPatch | ✅ |
| exec / exec-server / shell-command / unified-exec | RC/RM | Tools/Sandbox | 🟦 (router+gate ✅; child exec P3) |
| sandboxing | RM | Sandbox | 🟦 (policy ✅; Seatbelt apply P3-T3) |
| execpolicy / execpolicy-legacy | RC | (execpolicy) | 🟦 (current `execpolicy` prefix-rule subset ✅: `.rules`/`.codexpolicy` loading, `prefix_rule` alternatives and strictest-decision matching, `host_executable` basename fallback, `network_rule` domain compilation, explicit provider-host denial for `web_search`, example validation, and fail-closed parse errors; legacy Starlark `execpolicy-legacy` compatibility remains P3-T4) |
| file-system / file-search / file-watcher / network-proxy / code-mode | RC/RM | (fs/tools) | 🟦 (`fs/*`, direct `fuzzyFileSearch`, connection-scoped `fuzzyFileSearch/sessionStart`/`sessionUpdate`/`sessionStop` updates and completion notifications, missing/stopped-session failures, independent sessions, empty-query clearing, connection-close cleanup, and `fs/watch`/`fs/unwatch` DispatchSource-backed watcher with snapshot-diff backstop, file/directory notification coverage, unwatch, duplicate/relative-path rejection, and connection-close E2E coverage ✅; execpolicy domain denials now gate provider-backed `web_search`; full managed network-proxy and remaining code-mode parity remain P3/P5) |
| linux-sandbox / bwrap / windows-sandbox-rs / v8-poc | SK | — | n/a |

## MCP / plugins / skills / hooks / ext / memories
| crate | disp | target | state |
|---|---|---|---|
| codex-mcp / rmcp-client / mcp-server | RC | MCP | 🟦 (stdio MCP client/runtime, tool proxy, `mcpServerStatus/list`, `mcpServer/tool/call`, `mcpServer/resource/read`, reload path, session-bound direct tool/resource calls through the owning `codex-session` MCP child, `mcpServer/oauth/login` authorization URL plus loopback callback token exchange, and stdio MCP `elicitation/create` request/response routing implemented with real process/loopback-backed E2E coverage) |
| plugin / utils-plugins / skills / hooks / connectors | RC | PluginsSkillsHooks | 🟦 (local plugin marketplace list plus `marketplace/add`, `marketplace/remove`, `marketplace/upgrade`, `plugin/install`, `plugin/uninstall`, local `plugin/installed` installed/suggested filtering, local `plugin/read` by `marketplacePath` or configured `remoteMarketplaceName` with persisted skill enablement state, shared local `plugin/skill/read`, plugin/share save/list/update/checkout/delete, `skills/config/write` plus watched local skill-file `skills/changed` invalidation, `hooks/list`, hook pre/post/stop dispatch, unmanaged hook trust gating, legacy after-agent `notify`, and local `app/list` connector metadata/pagination/enabled-state implemented with E2E coverage; remote connector orchestration and remote marketplace parity remain P5) |
| ext/extension-api / ext/guardian | RC | ExtensionAPI / (ext) | 🟦 (`ext/extension-api` typed scoped stores + contributor registry ✅; `ext/guardian` model-backed auto-review of approval requests ✅ with fail-closed deterministic coverage) |
| ext/memories / memories-read|write|mcp / collaboration-mode-templates | RC | HarnessCore/Memories + Supervisor | 🟦 (durable memory store, memory tool list/read/search, consolidation, live memory-tool citation, and app-server `memory/reset` persistence clearing covered; remote trace summarize and richer collaboration-mode templates remain P4/P5) |

## Config / features / feedback / observability / misc
| crate | disp | target | state |
|---|---|---|---|
| config / features / feedback / install-context / external-agent-* | RC | Config/Supervisor | 🟦 (Config/features ✅; `externalAgentConfig` CONFIG/MCP_SERVER_CONFIG/HOOKS/SKILLS/COMMANDS/SUBAGENTS/AGENTS_MD/PLUGINS/SESSIONS detect+import ✅ with local plugin marketplace/cache/list readback; feedback/upload local spool + bounded feedback log-layer + attachment readback ✅; install-context detection + bundled rg resolution ✅) |
| cloud-tasks* | RC/OR | — | ⛔ P8 |
| otel / analytics | RM/RC | Observability | 🟦 (metrics/signpost ✅; OTLP export P6) |
| cli | XF (+RM lifecycle) | codexd/executables | 🟦 |
| tui | XF | — | n/a |
| utils/* (absolute-path, output-truncation, stream-parser, fuzzy-match, template, cache, string, elapsed, path-utils, home-dir, readiness, sandbox-summary, approval-presets, oss, image, json-to-toml, pty, sleep-inhibitor, cli, rustls-provider, cargo-bin) | RC/RM | folded into InfraPrimitives/leaf usage | 🟦 (output-truncation=HeadTailBuffer ✅; remainder as-needed) |
| arg0 / async-utils / git-utils / process-hardening / terminal-detection / ansi-escape | RM/RC | (leaf) | ⛔ as-needed |

CI must fail if a newly-pinned crate has no row here (plan P0-W3).
