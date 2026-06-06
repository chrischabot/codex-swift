# codex-swift

**A coding agent that runs as a long-lived service on your Mac — architected so one session can't freeze another, the agent is boxed in by the operating system itself, and you can teach it new tricks without forking it.**

codex-swift is a native Swift port of [OpenAI's Codex](https://github.com/openai/codex) coding agent. It speaks the same protocol as upstream Codex, so the clients you already use connect to it unchanged. What's different is underneath: instead of a one-shot CLI, it's a small set of cooperating background processes you can leave running — with the Mac's own sandbox around every command, your logins in the Keychain, and memory that survives restarts.

If you just want to try it, jump to **[Get started](#get-started)**. If you want to understand it first, read on — this page goes from the 30-second picture to as deep as you care to follow.

---

## What it is, in plain words

- **It's a little constellation of processes, not one big program.** Each chat session runs in its own worker, so a session that hangs or crashes can't stall or take down the others — a supervisor notices and restarts it. → [Multi-process architecture](docs/features/multi-process-architecture.md)
- **The Mac's own security boxes the agent in.** Every command the agent runs is wrapped in the macOS sandbox (Seatbelt); your credentials live in the Keychain; by default it cannot write outside your project or reach the network. The dangerous knobs exist, but you turn them on deliberately. → [Security & sandboxing](docs/guides/security.md)
- **It runs small models on-device.** Cheap, fast little jobs — and the memory system's embeddings — run locally via Apple's MLX (on by default on Apple Silicon) instead of a round-trip to the API, so not every tiny task costs a network call. → [Models & providers](docs/features/models-and-providers.md)
- **It remembers across sessions.** Each thread keeps short notes, and an optional host-wide **memory wiki** — a local vector store — recalls the facts relevant to *this* turn, so the agent carries context forward instead of starting cold every time. → [Memory](docs/features/memory.md)
- **You extend it without touching the core.** A new tool, a chat channel, a connector — each attaches to a seam that already exists, as one small file. The hardened base stays faithful to upstream Codex, so new capabilities pile on top without making upstream updates a fight. → [Addons & extensions](docs/guides/addons-and-plugins.md)
- **You can reach it from anywhere — and it can reach you.** A built-in web UI, voice, and chat apps like Telegram on the way *in*; push notifications to your phone, scheduled jobs, and generated images on the way *out*. → [Channels](docs/features/channels.md) · [Push](docs/features/push.md) · [Cron](docs/features/cron.md)
- **Your existing Codex clients just work.** It's wire-compatible with the upstream `app-server` protocol — point a client at it and go. → [App-server protocol](docs/features/protocol.md)

---

## A closer look

A paragraph each on the ideas that shape everything else. Follow any link to go all the way down.

**Multi-process, so nothing blocks.** A single long-running daemon (`codexd`) supervises a disposable worker per session, a shared auth/catalog service (`codex-broker`), and a memory daemon (`codex-memory`). Because each session is its own process, a runaway turn, a wedged tool, or an out-of-memory worker is contained — the supervisor reaps and restarts it while every other session keeps going. It's the difference between "the app froze" and "one tab reloaded." → [Multi-process architecture](docs/features/multi-process-architecture.md)

**Hardened by the operating system, not by hope.** Letting a model run a shell on your laptop is risky by default. codex-swift leans on the kernel: every spawned command is launched inside a macOS Seatbelt profile that denies everything except reads, writes under your project directory, and — only if you allow it — the network. Credentials live in the Keychain, not a dotfile. An approval ladder decides when *you* get asked before something runs unsandboxed. The conservative defaults are the point; the escape hatches are explicit. → [Security & sandboxing](docs/guides/security.md)

**A local lane for the small stuff.** Not every task deserves a frontier model. codex-swift has a separate small-model lane with an on-device path (Apple's MLX-Swift, built in by default on Apple Silicon) for quick classifications and for the embeddings that power memory — so the cheap, high-frequency work can stay local and fast while real coding turns go to the big model. Linux builds skip MLX automatically; opt out on macOS with `CODEXKIT_MLX=0`. → [Models & providers](docs/features/models-and-providers.md)

**Memory that persists.** Each conversation keeps short markdown notes that are consolidated at the end of a turn. Beyond that, an optional **memory wiki** is a host-wide vector store the agent searches every turn, pulling in the handful of facts relevant to what you're doing now and injecting them as clearly-marked, untrusted context. The result is an agent that remembers your project's conventions and decisions across days, not just within one chat. → [Memory](docs/features/memory.md)

**Capabilities are addons, not forks.** The base layer is deliberately heavy and hardened; everything else is layered on through one of five plug-in *seams* (a context module, a tool pack, an MCP server, a chat channel, or a model provider). Adding a capability means writing one folder and wiring it in one place — never editing the prompt composer or the tool loop. That keeps the core byte-faithful to upstream Codex (cheap merges) while the fun stuff accretes on top: chat channels, a Google Workspace connector, scheduled jobs, push, generated media. → [Addons & extensions](docs/guides/addons-and-plugins.md) · [the addon portfolio](ADDONS.md)

**Reach it, and let it reach back.** On the way in: a built-in web chat UI, voice in the browser, and chat apps (Telegram) with a server-stamped owner check so a stranger can't make it do destructive things. On the way out: it can push a notification to your phone when a long job finishes, run a prompt on a schedule, or generate an image — each through one durable, SSRF-screened delivery path. → [Channels](docs/features/channels.md) · [Web Gateway](docs/features/web-gateway.md) · [Push](docs/features/push.md) · [Cron](docs/features/cron.md) · [Media](docs/features/media.md)

**Why a Swift port at all?** Because targeting macOS specifically buys things a generic binary can't: `launchd` lifecycle, code signing + Hardened Runtime, Keychain, Seatbelt, and OS resource governance are first-class, not shims. And it's *parity-driven* — checked against the `codex-rs` source so on-disk session files stay byte-compatible and any Codex client connects unchanged. Production targets **macOS 14+**; the OS-agnostic core also builds and tests on Linux for CI.

---

## Get started

```sh
git clone https://github.com/chrischabot/codex-swift.git
cd codex-swift
swift build -c release          # builds codexd, codex-broker, codex-session, codex-memory

export OPENAI_API_KEY=sk-...
scripts/codexd-stdio-live-smoke.sh   # initialize → thread/start → turn/start → streamed turn
```

That smoke script drives the real `codexd` binary over stdio and runs one full streamed turn (it skips cleanly with no key). For Unix-socket and WebSocket transports use `scripts/codexd-uds-smoke.sh` / `scripts/codexd-ws-smoke.sh`. For the daemon layout, first connection, and a `launchd` install, see **[Getting Started — Build & Run](docs/guides/getting-started.md)**.

---

## Dive deeper

Every capability has a focused doc that opens with *why it matters* and a plain-English overview before the internals — written to be read top-to-bottom or skimmed. Start with **[Getting Started](docs/guides/getting-started.md)** or **[Multi-Process Architecture](docs/features/multi-process-architecture.md)** for the mental model; follow your curiosity from there.

### Guides — how to use it
- **[Getting Started — Build & Run](docs/guides/getting-started.md)** — Build the package and run your first streamed turn over stdio, Unix socket, or WebSocket; understand the codexd/codex-session/codex-broker/codex-memory layout; install under launchd.
- **[Configuration](docs/guides/configuration.md)** — Layered TOML config: `config.toml` files, profiles, `[features]` flags, `CODEX_CFG_*`/`CODEX_FEATURE_*` overrides, `$CODEX_HOME`, model/provider/approval/sandbox keys, and inspecting the merged config.
- **[Slash Commands](docs/guides/slash-commands.md)** — There's no in-band slash parser: `/review`, `/compact`, the shell affordance, and `/workflow` are client-side shortcuts mapped to RPC methods/turn kinds; custom `/<name>` commands are `prompts/` files; the word "workflow" auto-arms the workflow tool.
- **[Using MCP Servers](docs/guides/mcp.md)** — Plug in stdio and streaming-HTTP MCP servers: `mcp__server__tool` naming, OAuth (PKCE/loopback) login, and the secret-isolation/trust posture.
- **[Skills](docs/guides/skills.md)** — Reusable on-disk `SKILL.md` procedures the agent discovers at startup, lists compactly, and loads in full only on match or when named with `$SkillName`.
- **[Addons & Plugins](docs/guides/addons-and-plugins.md)** — The "reverse the pyramid" model: five plug-in surfaces (module, ToolPack, MCP, channel, provider), the `ExtensionAPI` registry wired by one `installAddons` root, the ToolPack→ToolRouter seam, and the Phase-0 foundations.
- **[Security, Sandboxing & Approvals](docs/guides/security.md)** — Running real commands safely: the Seatbelt/bwrap kernel sandbox, writable-roots and network policy, the never/onFailure/onRequest/unlessTrusted/granular approval ladder, channel owner-gating, and the SSRF egress chokepoint.

### Core — how the agent works
- **[The Agent Turn Loop](docs/features/agent-loop.md)** — How one user request becomes a streamed, durable, steerable model-and-tool loop.
- **[Models & Providers](docs/features/models-and-providers.md)** — One `ModelClient` protocol, three transports, session-sticky retry/fallback, a capability catalog, a provider registry, and a cheap small-model lane.
- **[Built-in Tools](docs/features/tools.md)** — The catalog of concrete actions — shell/exec, `apply_patch`, `web_search`, `view_image`, code-mode — through one parallel/serial-gating, sandboxing, approval-enforcing dispatcher.
- **[Memory](docs/features/memory.md)** — Per-thread `.md` notes plus an optional host-wide vector Memory Wiki, recalled into each turn as fenced, untrusted context.
- **[Persistence & Resume](docs/features/persistence-and-resume.md)** — Append-only rollout JSONL source-of-truth, upstream byte-compatibility, group-commit fsync durability, and crash/reboot resume.
- **[Multi-Process Architecture](docs/features/multi-process-architecture.md)** — Why codex-swift runs as a daemon constellation so one bad session can't take down the rest.
- **[Prompts, AGENTS.md & Context](docs/features/prompts-and-context.md)** — The system prompt, `AGENTS.md`, skills/connectors injection, and token-aware auto-compaction.
- **[Authentication](docs/features/auth.md)** — ChatGPT browser/device-code login or API key, Keychain-backed, single-flight refresh, transparent per-turn credential delivery.

### Surfaces — how you reach it
- **[Web Gateway & UI](docs/features/web-gateway.md)** — The built-in web server + same-origin TLS WebSocket bridge with bearer auth, a deny-default method gate, signed media URLs, and uploads.
- **[Computer Use (Desktop Control)](docs/features/computer-use.md)** — The agent drives the real macOS desktop via the `computer` tool, behind a host-control approval gate; off by default.
- **[Realtime Voice](docs/features/realtime-voice.md)** — Voice in the browser over OpenAI's Realtime API, bridged through the WebGateway, gated behind `CODEXKIT_REALTIME_LIVE`.
- **[Workflows](docs/features/workflows.md)** — A JavaScript engine fanning work across many GPT sub-agents deterministically, with token budgets, background execution, and crash-resume.
- **[Channels (Reach the Agent via Chat)](docs/features/channels.md)** — Reach the agent from chat apps (Telegram, wired into the daemon): inbound message → turn → reply, server-stamped owner identity, a hard owner-gate enforced even across the spawned worker, per-conversation isolation, `channels/*` control RPC.
- **[Connectors](docs/features/connectors.md)** — OAuth-installed external services; the native Google OAuth-PKCE runtime + the `google_api` Workspace tool are built (`codexd google-connect`), the generic `app/list` discovery skeleton covers the rest.

### Proactive — how it reaches you
- **[Push & Outbound Delivery](docs/features/push.md)** — Durable, SSRF-screened delivery to ntfy/webhook via the approval-gated `push_send` tool and the owner-path `outbound/send` RPC + `codex-send` CLI.
- **[Cron & Scheduled Jobs](docs/features/cron.md)** — Run a prompt on a schedule as a locked-down, unattended turn (read-only, approval-`never`) whose result is pushed; `cron/*` RPC + automations migration.
- **[Media Generation](docs/features/media.md)** — `media_generate` runs async without blocking the turn — crash-safe ledger, daemon poller, bounded-retry pushed delivery.

### Operations — running it
- **[Observability](docs/features/observability.md)** — Structured logs, `os_signpost` spans, a non-blocking metrics ring, and an opt-in OTLP/JSON exporter.
- **[Token Usage & Cost](docs/features/usage-and-cost.md)** — Per-turn usage accounting, per-model pricing, and spend surfaced in notifications, rollouts, and benchmark reports.
- **[Benchmarks (DeepSWE Runner)](docs/features/benchmarks.md)** — A native runner scoring the 113-task DeepSWE benchmark in air-gapped `apple/container` VMs (Pass@1 + cost/time/tokens).

### For integrators — connecting to it
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
