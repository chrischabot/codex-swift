# codex-swift

**codex-swift is a native Swift port of OpenAI's Codex agentic coding harness, re-architected as a long-running, multi-process macOS daemon.** It speaks the upstream Codex `app-server` JSON-RPC protocol, so the clients you already use connect unchanged — but underneath it runs as a supervised constellation of processes with Seatbelt sandboxing, Keychain auth, and crash/reboot-durable persistence. It is deliberately built as a **hardened base layer** onto which capabilities (channels, connectors, tools, providers) are layered as addons.

---

## Why this exists

Upstream Codex is a Rust binary. A Swift port targeted at macOS buys things a generic build can't:

- **Native macOS integration is the implementation, not a shim.** `launchd` lifecycle, ad-hoc + Developer ID signing, Hardened Runtime, Keychain-backed tokens, Seatbelt (`sandbox-exec`) sandboxing, `task_set_phys_footprint_limit` resource governance, `os_signpost` spans, and DispatchSource file watchers are first-class.
- **One toolchain end-to-end.** Clients, daemon, and tooling share one Swift package and one set of `Codable`/`Sendable` types. The portable core (wire, protocol, persistence, model contract, turn loop, tools, supervisor/worker/broker) also builds and tests green on Linux for CI.
- **Parity over invention.** Every decision is checked against the `codex-rs` source tree. On-disk rollouts are byte-compatible with the Rust reader, unknown methods get wire-correct defaults (`-32601` only for truly-unknown), and a schema-parity gate diffs the pinned upstream oracle on every release build. Point any Codex client at `codexd` and it should just work.

The trade-off: production targets **macOS 14+**; the OS-agnostic core stays portable for Linux CI.

---

## What it can do

**Agent core**
- **Agent turn loop** — one request becomes a streamed, durable, steerable model-and-tool loop, ported faithfully from upstream.
- **Models & providers** — one Responses-API `ModelClient` protocol with three interchangeable transports (curl SSE, URLSession, WebSocket), session-sticky retry/WS→HTTPS fallback, a per-model capability catalog, a provider registry, and a separate cheap small-model lane.
- **Built-in tools** — shell/exec, `apply_patch` edits, file read/write/list/search, `view_image`, `web_search`, `spawn_agent`, and JavaScript code-mode — all through one dispatcher that enforces parallel/serial gating, sandboxing, and approvals.
- **Prompts, AGENTS.md & context** — model-specific system prompt + project `AGENTS.md` + skills/connectors injection + token-aware auto-compaction.
- **Memory** — auto-consolidated per-thread `.md` notes plus an optional host-wide vector Memory Wiki, recalled into each turn as fenced, untrusted context.
- **Authentication** — ChatGPT browser/device-code login or API key, Keychain-backed, with single-flight token refresh.

**Durability & safety**
- **Persistence & resume** — append-only rollout JSONL as source-of-truth (upstream byte-compatible) + group-commit fsync durability + crash/reboot resume by replaying the log.
- **Security** — Seatbelt/bwrap kernel sandbox, writable-roots + network policy, the never/onFailure/onRequest/unlessTrusted/granular approval ladder, channel owner-gating, and an SSRF egress chokepoint.
- **Multi-process architecture** — a `codexd` supervisor, disposable per-session workers, a shared `codex-broker`, and a `codex-memory` daemon, so one bad session can't take the rest down.

**Surfaces (how you reach it)**
- **Web Gateway & UI** — built-in web server serving the chat UI, bridging each tab over a same-origin TLS WebSocket with bearer auth, a deny-default method gate, signed media URLs, and uploads.
- **Computer use** — the agent drives the real macOS desktop via OpenAI's `computer` tool, behind a dedicated host-control approval gate (off by default).
- **Realtime voice** — talk to the agent by voice in the browser over OpenAI's Realtime API (echo mock by default; live behind `CODEXKIT_REALTIME_LIVE`).
- **Workflows** — a JavaScript engine that fans work out across many GPT sub-agents deterministically (agent/parallel/pipeline primitives, token budgets, crash-resume).
- **Channels** — reach the agent from chat apps (Telegram today) with server-stamped owner identity and a hard owner-gate.
- **MCP** — plug in external tools/resources over stdio and streaming-HTTP servers, with `mcp__server__tool` naming, PKCE/loopback OAuth, and per-session secret isolation.

**Operations & integration**
- **Observability** — structured `os.Logger`/stderr logs, `os_signpost` spans, a non-blocking metrics ring, and an opt-in OTLP/JSON exporter.
- **Token usage & cost** — per-turn input/cached/output/reasoning accounting, per-model pricing, surfaced in notifications, rollouts, and benchmark reports.
- **Benchmarks** — a native runner (`codex-bench`/BenchKit) scoring the 113-task DeepSWE benchmark in air-gapped `apple/container` VMs (Pass@1 + confidence intervals).
- **App-server protocol** — the upstream-compatible Codex JSON-RPC surface (methods, items, streaming notifications, correlated server requests).
- **Connectors** — OAuth-installed external services surfaced to the agent (discovery + `app/list` skeleton built; Google Workspace runtime planned).
- **Skills, lifecycle hooks & the addon layer** — on-disk `SKILL.md` procedures discovered at startup; `hooks.json` shell hooks at agent lifecycle points; and a "reverse the pyramid" addon model where new capabilities attach to existing seams as one safe file.

---

## Quickstart

```sh
git clone https://github.com/chrischabot/codex-swift.git
cd codex-swift
swift build -c release          # builds codexd, codex-broker, codex-session, codex-memory

export OPENAI_API_KEY=sk-...
scripts/codexd-stdio-live-smoke.sh   # initialize → thread/start → turn/start → streamed turn
```

That smoke script drives the real `codexd` binary over stdio and runs one full streamed turn (it skips cleanly with no key). For Unix-socket and WebSocket transports use `scripts/codexd-uds-smoke.sh` / `scripts/codexd-ws-smoke.sh`. For the daemon layout, first connection, and a `launchd` install, see **[Getting Started — Build & Run](docs/guides/getting-started.md)**.

---

## Documentation

### Guides
- **[Getting Started — Build & Run](docs/guides/getting-started.md)** — Build the package and run your first streamed turn over stdio, Unix socket, or WebSocket; understand the codexd/codex-session/codex-broker/codex-memory layout; install under launchd.
- **[Configuration](docs/guides/configuration.md)** — Layered TOML config: `config.toml` files, profiles, `[features]` flags, `CODEX_CFG_*`/`CODEX_FEATURE_*` overrides, `$CODEX_HOME`, model/provider/approval/sandbox keys, and inspecting the merged config.
- **[Slash Commands](docs/guides/slash-commands.md)** — There's no in-band slash parser: `/review`, `/compact`, the shell affordance, and `/workflow` are client-side shortcuts mapped to RPC methods/turn kinds; custom `/<name>` commands are `prompts/` files; the word "workflow" auto-arms the workflow tool.
- **[Using MCP Servers](docs/guides/mcp.md)** — Plug in stdio and streaming-HTTP MCP servers: `mcp__server__tool` naming, OAuth (PKCE/loopback) login, and the secret-isolation/trust posture.
- **[Skills](docs/guides/skills.md)** — Reusable on-disk `SKILL.md` procedures the agent discovers at startup, lists compactly, and loads in full only on match or when named with `$SkillName`.
- **[Addons & Plugins](docs/guides/addons-and-plugins.md)** — The "reverse the pyramid" model: five plug-in surfaces (module, ToolPack, MCP, channel, provider), the `ExtensionAPI` registry wired by one `installAddons` root, the ToolPack→ToolRouter seam, and the Phase-0 foundations.
- **[Security, Sandboxing & Approvals](docs/guides/security.md)** — Running real commands safely: the Seatbelt/bwrap kernel sandbox, writable-roots and network policy, the never/onFailure/onRequest/unlessTrusted/granular approval ladder, channel owner-gating, and the SSRF egress chokepoint.

### Core
- **[The Agent Turn Loop](docs/features/agent-loop.md)** — How one user request becomes a streamed, durable, steerable model-and-tool loop.
- **[Models & Providers](docs/features/models-and-providers.md)** — One `ModelClient` protocol, three transports, session-sticky retry/fallback, a capability catalog, a provider registry, and a cheap small-model lane.
- **[Built-in Tools](docs/features/tools.md)** — The catalog of concrete actions — shell/exec, `apply_patch`, `web_search`, `view_image`, code-mode — through one parallel/serial-gating, sandboxing, approval-enforcing dispatcher.
- **[Memory](docs/features/memory.md)** — Per-thread `.md` notes plus an optional host-wide vector Memory Wiki, recalled into each turn as fenced, untrusted context.
- **[Persistence & Resume](docs/features/persistence-and-resume.md)** — Append-only rollout JSONL source-of-truth, upstream byte-compatibility, group-commit fsync durability, and crash/reboot resume.
- **[Multi-Process Architecture](docs/features/multi-process-architecture.md)** — Why codex-swift runs as a daemon constellation so one bad session can't take down the rest.
- **[Prompts, AGENTS.md & Context](docs/features/prompts-and-context.md)** — The system prompt, `AGENTS.md`, skills/connectors injection, and token-aware auto-compaction.
- **[Authentication](docs/features/auth.md)** — ChatGPT browser/device-code login or API key, Keychain-backed, single-flight refresh, transparent per-turn credential delivery.

### Surfaces
- **[Web Gateway & UI](docs/features/web-gateway.md)** — The built-in web server + same-origin TLS WebSocket bridge with bearer auth, a deny-default method gate, signed media URLs, and uploads.
- **[Computer Use (Desktop Control)](docs/features/computer-use.md)** — The agent drives the real macOS desktop via the `computer` tool, behind a host-control approval gate; off by default.
- **[Realtime Voice](docs/features/realtime-voice.md)** — Voice in the browser over OpenAI's Realtime API, bridged through the WebGateway, gated behind `CODEXKIT_REALTIME_LIVE`.
- **[Workflows](docs/features/workflows.md)** — A JavaScript engine fanning work across many GPT sub-agents deterministically, with token budgets, background execution, and crash-resume.
- **[Channels (Reach the Agent via Chat)](docs/features/channels.md)** — Reach the agent from chat apps (Telegram today): inbound message → turn → reply, server-stamped owner identity, hard owner-gate, per-conversation isolation.
- **[Connectors](docs/features/connectors.md)** — OAuth-installed external services surfaced to the agent (discovery + `app/list` skeleton built; Google Workspace runtime planned).

### Operations
- **[Observability](docs/features/observability.md)** — Structured logs, `os_signpost` spans, a non-blocking metrics ring, and an opt-in OTLP/JSON exporter.
- **[Token Usage & Cost](docs/features/usage-and-cost.md)** — Per-turn usage accounting, per-model pricing, and spend surfaced in notifications, rollouts, and benchmark reports.
- **[Benchmarks (DeepSWE Runner)](docs/features/benchmarks.md)** — A native runner scoring the 113-task DeepSWE benchmark in air-gapped `apple/container` VMs (Pass@1 + cost/time/tokens).

### For Integrators
- **[The App-Server Protocol](docs/features/protocol.md)** — Connecting a client over the upstream-compatible Codex JSON-RPC protocol: methods, items, streaming notifications, correlated server requests, wire rules, error codes.
- **[Lifecycle Hooks](docs/features/hooks.md)** — Run your own shell commands at lifecycle points (PreToolUse, PermissionRequest, Stop, …) to block, rewrite, approve, or observe — configured via a trusted `hooks.json`.

### Reference / internals
The deep design docs and the addon thesis:

| Doc | What it covers |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Process model, module map, request flow, IPC, durability |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | App-server JSON-RPC method registry, items, event channels |
| [`docs/MODEL_CLIENT.md`](docs/MODEL_CLIENT.md) | Responses API client, transports, retry/fallback |
| [`docs/TOOLS.md`](docs/TOOLS.md) | Built-in tool catalog, ToolRouter, code-mode |
| [`docs/MCP.md`](docs/MCP.md) | MCP stdio + streaming-HTTP clients, OAuth, elicitation |
| [`docs/PROMPTS.md`](docs/PROMPTS.md) | PromptComposer, AGENTS.md, skills |
| [`docs/HOOKS.md`](docs/HOOKS.md) | Hook lifecycle, trust gating, payloads |
| [`docs/SANDBOX.md`](docs/SANDBOX.md) | Seatbelt profiles, workspace policy, approval engine |
| [`docs/MEMORY.md`](docs/MEMORY.md) | `codex-memory` daemon, stages, MLX inference |
| [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) | Rollout JSONL, SQLite WAL, resume |
| [`docs/CONFIG.md`](docs/CONFIG.md) | `config.toml` schema, layering, config RPCs |
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Building, testing, release gates, CI |
| [`ADDONS.md`](ADDONS.md) | The "reverse the pyramid" addon portfolio and its design |
| [`CRATE_DISPOSITIONS.md`](CRATE_DISPOSITIONS.md) | Every `codex-rs` crate → Swift target mapping |
| [`STATUS.md`](STATUS.md) | Per-module completion vs. plan, macOS punch list — single source of truth |

---

## Project layout

The major `Sources/` targets:

```
codexd              Supervisor daemon: transports, request routing, resource policy, subscriptions
codex-session       Per-session worker: turn loop, tool calls, ContextManager, ModelClient, MCP child
codex-broker        Shared read-mostly service: auth refresh coalescing, catalog SWR
codex-memory        Memory daemon: ingest/process/score/retrieve/MCP stages
codex-bench         DeepSWE benchmark runner CLI (BenchKit)
codex-computer      Desktop-control CLI for the computer-use tool

Supervisor          SessionSupervisor, RequestRouter, ChannelManager, resource governor
SessionWorkerCore   SessionEngine + worker-side turn machinery
HarnessCore         Core turn loop, ContextManager, ToolPack/installAddons composition
Tools / Sandbox     Built-in tool catalog + ToolRouter; Seatbelt + workspace policy + approvals
ModelClient         Responses-API client (SSE / URLSession / WebSocket) + RealtimeClient
Persistence         Rollout JSONL + SQLite WAL + resume
Auth / Broker       Keychain token store, OAuth/device-code; broker refresh coalescing
MCP                 stdio + streaming-HTTP MCP clients, OAuth, elicitation
Memory*             codex-memory stages (Store/Infer/Score/Ingest/Process/Retrieve/MCP)
Channels            Channel/ChannelHost contract, owner-gate, TelegramChannel
Connectors          ConnectorRecord discovery + app/list surfacing
Workflows           JavaScript sub-agent fan-out engine
WebGateway          Hummingbird web server + WS bridge serving the chat UI
ComputerUse         macOS desktop control for the computer-use tool
Prompts / Skills    PromptComposer, AGENTS.md, skill discovery
Observability       os.Logger/signpost spans, metrics ring, OTLP/JSON exporter
ProtocolModel / WireProtocol / Transport   App-server JSON-RPC types + transports
ExtensionAPI / DeliveryCore / EgressGuard  Addon registry, durable outbound, SSRF chokepoint
InfraPrimitives     Backoff, TokenBucket, SingleFlight, MonotonicClock, BoundedChannel
Tokenizer / Config / IPC / CSQLite[Vec]    Token counting, layered TOML, typed duplex IPC, SQLite shims
```

---

## Status & parity

codex-swift is **wire-compatible with the upstream Codex app-server protocol** against a pinned schema oracle: 77 methods, 526 generated TypeScript manifest files, and 84 generic response shapes diffed on every release build. The test suite ships **~971 tests** across unit, adversarial, integration, and live targets; the live target runs against the real OpenAI Responses API when `OPENAI_API_KEY` is set (multi-session live coding, direct Responses WebSocket streaming with HTTPS fallback, JavaScriptCore code-mode tool calls, real MCP-routed calls).

Release-rehearsal gates `g0`–`g9` cover build/transport/model/persistence/tools/sandbox/auth/broker/memories, plus lifecycle (launchd plist render, ad-hoc + Developer ID signing, hardened runtime, install/status/uninstall, blue-green promote/rollback), reboot resume, active-turn crash, poisoned-worker recovery, physical-footprint cap evidence, and soak/noisy-neighbor SLOs.

**Production targets macOS 14+** (launchd, Seatbelt, Keychain, signing); the portable core runs green on Linux for CI. Known remaining work — full ChatGPT WebRTC realtime audio transport, full managed network-proxy parity, legacy Starlark `execpolicy-legacy` compatibility, and the native completion of `// MACOS-COMPLETION:` markers — is tracked openly in [`STATUS.md`](STATUS.md), the single source of truth for "what works / what needs fixing on a Mac." No placeholder happy paths; failure modes are surfaced and root-caused.

---

*codex-swift is a parity-driven port of [`openai/codex`](https://github.com/openai/codex) — not a fork, and it does not vendor Rust source. Licensed under the Apache License, Version 2.0; see [`LICENSE`](LICENSE).*
