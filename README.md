# codex-swift

codex-swift is a native Swift port of [OpenAI's Codex](https://github.com/openai/codex) coding agent that runs as a long-lived service on your Mac. It is for developers who want to keep several agent conversations going at once, leave some of them working unattended, and connect to them from a terminal, a browser or their own client. It speaks upstream Codex's app-server protocol as of June 2026, when its schema was last pinned, so a `codex` CLI from around then can be one of those clients, while a newer one may call methods the port has not caught up with.

Keeping an agent running for days brings problems that a short session can ignore. Every conversation streams from a model, runs shell commands, talks to MCP servers and appends to its history, and when those conversations share a process, a wedged MCP server or a tool that runs away with memory can stall all of them. The model also has a shell on your machine, so its limits have to hold even when it misbehaves. codex-swift leans on the operating system for both problems. Each conversation gets its own disposable worker process under a small supervisor, commands run inside a kernel sandbox by default, and history is written to disk as it happens, so a worker that crashes or gets killed affects only its own conversation, which can then resume in a fresh worker. Targeting one operating system keeps this direct: launchd keeps the service alive, Seatbelt confines commands and Mach task policies let the supervisor throttle and cap workers.

## How it works

```text
codex CLI, web UI or your own client
        │  stdio, Unix socket or WebSocket
        ▼
     codexd            supervisor: transports, routing, worker lifecycle
        │  one socketpair per conversation
        ▼
  codex-session        worker: turn loop, tools, sandbox, MCP servers
```

`codexd` is the only process clients connect to, and it never runs a model turn or a tool itself. That work happens in `codex-session`, one process per loaded conversation. Each worker leads its own process group and reaches the supervisor only through a socketpair, so when one dies the supervisor sees end-of-file on that socket, clears the thread and tells subscribed clients it has closed. The next `thread/resume` starts a fresh worker that replays the conversation from disk.

The supervisor also catches workers that are alive but stuck or greedy. A worker sends a heartbeat every two seconds and is killed after missing four in a row, which covers hangs that burn no CPU. CPU and memory are sampled for each worker, so a heavy one is throttled first, then refused new turns and finally killed, and each worker requests a kernel-enforced 2 GiB physical-footprint cap, reporting a warning if macOS cannot apply it. Two separate daemons take on work that sessions share: `codex-broker` collapses concurrent token refreshes into one upstream call and caches the model catalog, and `codex-memory`, which `codexd` starts only when `CODEXKIT_MEMORY=1`, handles ingest and retrieval for the Memory Wiki. The [multi-process architecture](docs/features/multi-process-architecture.md) guide has the details.

Commands run through `sandbox-exec` with a Seatbelt profile generated for each launch, on top of upstream's deny-by-default base policy. In the default `workspace-write` mode a command can read whatever your user can read, can write only under the session's writable roots, and has no network unless you allow it. `.git`, `.codex` and `.agents` stay read-only even inside a writable root, which stops a sandboxed process from planting a git hook or loosening its own config, and if `sandbox-exec` is missing the command is refused rather than run unconfined. The default `on-request` approval policy decides when you are asked before something runs outside the sandbox. See [security, sandboxing and approvals](docs/guides/security.md).

Each conversation's source of truth is an append-only JSONL rollout under `$CODEX_HOME/sessions/`, fsynced in small batches and always at a turn boundary. A SQLite index makes listing fast and can be rebuilt from the rollouts, so `sessions/` is the directory worth backing up. This is what lets a conversation survive a killed worker, a daemon restart or a reboot. See [persistence and resume](docs/features/persistence-and-resume.md).

## Getting started

You need macOS 14 or later and a Swift 6.1 or newer toolchain. There are no prebuilt releases, so you build from source. On macOS the build pulls in MLX for on-device models, which needs Apple Silicon, and `export CODEXKIT_MLX=0` beforehand gives you a lighter build without it.

```sh
git clone https://github.com/chrischabot/codex-swift.git
cd codex-swift
swift build
make smoke    # no API key: starts codexd against a mock model and checks the wire contract
```

State lives under `CODEX_HOME`, which defaults to `~/.codex`. Upstream Codex uses that directory too, so point it elsewhere while you try this out. `codexd-cli.sh` then starts `codexd` on a Unix socket, waits until it is healthy and hands you the official `codex` CLI connected to it, passing along any extra arguments. The helper needs Python 3 and `codex` on your `PATH`; a CLI version from around the [pinned upstream commit](#compatibility-and-limits) is the closest match.

```sh
export CODEX_HOME="$HOME/.codex-swift"
export OPENAI_API_KEY='<your key>'    # or: export CODEXKIT_MOCK=1 for the mock model
./codexd-cli.sh
```

To watch one real streamed turn with no other client, run `scripts/codexd-stdio-live-smoke.sh` with the key set. It uses `gpt-4o-mini` unless you set `CODEXKIT_LIVE_MODEL`. The [getting started guide](docs/guides/getting-started.md) walks through all of this in more detail.

### Other ways to run it

**In a browser.** `make webui-install` installs the UI's dependencies once, and Node is needed only to build the bundle. `make web-smoke` then builds everything and serves the chat UI at `http://127.0.0.1:8443` against the mock model, with no key and no TLS. For real use, run `make webui` and start `.build/debug/codexd --listen off --listen-web 127.0.0.1:8443`, which serves the same UI over TLS with a generated self-signed certificate. Binding beyond loopback forces bearer-token auth. See the [web gateway guide](docs/features/web-gateway.md).

**From your own client.** `codexd` speaks a line-oriented, JSON-RPC-style protocol over stdio by default. `--listen unix://` serves it on `$CODEX_HOME/app-server-control/app-server-control.sock` with mode 0600, and `--listen ws://127.0.0.1:PORT` serves it over a loopback WebSocket and refuses other addresses. A client sends `initialize` first, and the [protocol guide](docs/features/protocol.md) covers the methods, the streamed items and the deliberate departures from strict JSON-RPC.

**As a launchd service.**

```sh
swift build -c release
scripts/codexkit-lifecycle.sh install --build-dir .build/release \
  --install-root "$HOME/Library/Application Support/CodexKit" \
  --codex-home "$HOME/.codex-swift"
scripts/codexkit-lifecycle.sh status \
  --install-root "$HOME/Library/Application Support/CodexKit" \
  --codex-home "$HOME/.codex-swift"
```

This installs user LaunchAgents for `codexd` and `codex-broker`, which launchd restarts if they die. The explicit paths keep binaries in your user Library and session data in `~/.codex-swift`; without `--codex-home`, the script chooses `~/.codex` even if you exported a different `CODEX_HOME`. Use the same path flags with `uninstall`. The generated LaunchAgents do not carry your shell's `OPENAI_API_KEY`, so configure a stored login in the selected home using the [authentication guide](docs/features/auth.md).

**Logging in.** Without `OPENAI_API_KEY`, `codexd` looks for a running broker's token and then a stored login. ChatGPT browser and device-code logins go through the `account/login/*` methods. Credentials are kept in `$CODEX_HOME/auth.json` with mode 0600 by default, the same file the official CLI reads, and setting `cli_auth_credentials_store = "keyring"` in `config.toml` selects the Keychain for credential storage. Selecting it does not migrate or remove an existing `auth.json` file. See [authentication](docs/features/auth.md) and [configuration](docs/guides/configuration.md).

## What else is in it

Tools run through one router that applies the sandbox and approval rules: shell and persistent exec sessions, `apply_patch`, file and image tools and web search. MCP servers connect over stdio or streaming HTTP with OAuth, lifecycle hooks let your own commands block, rewrite or approve actions, `SKILL.md` skills and `AGENTS.md` feed the prompt, and a JavaScript workflow engine fans work out across sub-agents.

Memory comes in two parts. Personal memory, a native Swift implementation of mem0, is on by default: it extracts durable facts from completed turns into `$CODEX_HOME/mem0/mem0.db` and recalls them into later prompts as fenced, untrusted context. The Memory Wiki is a separate, source-backed knowledge base for research, fed by `codex-memory`. Setting `provider = "none"` under `[memory]` turns personal memory off, and `CODEXKIT_MEMORY=0` skips the end-of-turn consolidation, which can add several seconds to a turn. See [memory](docs/features/memory.md).

New capabilities attach as [addons](docs/guides/addons-and-plugins.md) through one of five seams, a context module, a tool pack, an MCP server, a chat channel or a model provider, so adding one doesn't mean editing the turn loop or the prompt composer, and the core can keep tracking upstream. The addons here are all off until you enable them: Telegram and Gmail channels with owner checks based on the authenticated sender rather than the message text, push notifications over ntfy or webhooks, scheduled prompts, media generation and Google Workspace access. Desktop computer use and browser voice are opt-in as well.

## Compatibility and limits

- **Protocol.** `tools/conformance` checks the wire surface against a schema pinned to upstream commit `dfd03ea01b` from June 2026, which defines 84 client methods. [`UPSTREAM_SYNC_LOG.md`](UPSTREAM_SYNC_LOG.md) records each catch-up, and the deliberate differences are written down in the [divergence](docs/notes/catchup-p5-divergences.md) and [decision](docs/notes/catchup-remaining-decisions.md) notes.
- **Session files.** Messages and reasoning are written in upstream's rollout format, but a tool call and its output are stored together as one native record, so upstream's tools can't fully replay a session written here.
- **Models.** Agent turns use OpenAI's Responses API, with an API key or a ChatGPT login. `wire_api = "responses"` is enforced at startup, so any provider you add has to expose that API.
- **On-device models.** Memory work prefers local MLX models on Apple Silicon and falls back to an OpenAI-compatible endpoint. `swift build` compiles this lane in but doesn't produce the Metal library it needs, the Nomic embedder needs a patch to a dependency checkout, and the default extractor model is about 17 GB, so follow the [bring-up notes](docs/notes/on-device-mlx-bringup.md) before expecting it to run locally.
- **Linux.** macOS is the production target. The portable core is written to build on Linux, with Bubblewrap in place of Seatbelt and a file token store, but without launchd, the memory cap or QoS throttling.
- **Still open.** Native realtime audio routing, honouring the system network proxy and native Starlark exec-policy evaluation are tracked in [`STATUS.md`](STATUS.md).

## Development

```sh
swift test                        # full suite; live tests run only with OPENAI_API_KEY set
swift test --filter ToolsTests    # one target
make e2e                          # integration and adversarial targets
scripts/run-tests.sh --release    # release build, full suite, mock-responses self-test
```

The non-live suite is large: at the last upstream catch-up it ran about 3,200 tests in roughly 15 minutes, and a few timing-sensitive tests can fail in a full run and pass on their own. The `g0` to `g9` gates in [`tools/e2e/`](tools/e2e/README.md) go further, covering launchd install and signing, blue-green worker promotion, reboot resume, a daemon killed mid-turn, poisoned workers and soak tests, and some of them need an API key, a signing identity or a real reboot. The conformance gates need an upstream checkout, by default at `../codex` or wherever `CODEX_TREE` points. [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) is the working manual.

The Swift package is called CodexKit and exports its layers as libraries. Useful places to start reading:

```text
Sources/codexd, Supervisor                  daemon, routing, worker lifecycle, resource governor
Sources/codex-session, SessionWorkerCore    per-session worker
Sources/HarnessCore                         turn loop, context manager, approvals, addon wiring
Sources/Tools, Sandbox                      tool catalog and router, Seatbelt and Bubblewrap policy
Sources/ModelClient                         Responses API over SSE and WebSocket
Sources/Persistence                         rollouts, SQLite index, resume
Sources/WireProtocol, ProtocolModel         app-server protocol types
Sources/Mem0*, Memory*, Wiki*               personal memory and the Memory Wiki
www/                                        React web UI
```

## Documentation

- **Using it:** [getting started](docs/guides/getting-started.md), [configuration](docs/guides/configuration.md), [security](docs/guides/security.md), [MCP](docs/guides/mcp.md), [skills](docs/guides/skills.md), [slash commands](docs/guides/slash-commands.md), [addons](docs/guides/addons-and-plugins.md)
- **Core:** [turn loop](docs/features/agent-loop.md), [models and providers](docs/features/models-and-providers.md), [tools](docs/features/tools.md), [memory](docs/features/memory.md), [persistence](docs/features/persistence-and-resume.md), [multi-process architecture](docs/features/multi-process-architecture.md), [prompts and context](docs/features/prompts-and-context.md), [authentication](docs/features/auth.md)
- **Surfaces:** [web gateway](docs/features/web-gateway.md), [computer use](docs/features/computer-use.md), [realtime voice](docs/features/realtime-voice.md), [workflows](docs/features/workflows.md), [channels](docs/features/channels.md), [connectors](docs/features/connectors.md), [push](docs/features/push.md), [cron](docs/features/cron.md), [media](docs/features/media.md)
- **For client authors:** [app-server protocol](docs/features/protocol.md), [lifecycle hooks](docs/features/hooks.md)
- **Operations:** [observability](docs/features/observability.md), [usage and cost](docs/features/usage-and-cost.md), [DeepSWE benchmark runner](docs/features/benchmarks.md)
- **Internals and status:** [architecture](docs/ARCHITECTURE.md), [development](docs/DEVELOPMENT.md), [addon portfolio](ADDONS.md), [status](STATUS.md), [upstream sync log](UPSTREAM_SYNC_LOG.md), [crate dispositions](CRATE_DISPOSITIONS.md)

## Project background

- [codex-swift project overview](https://chabot.dev/projects/#codex-swift) on Chris Chabot’s site.
- [A hung agent shouldn't freeze the others](https://chabot.dev/blog/coding-agents-as-supervised-local-services/): process isolation, supervision and shared authentication.

## License and credits

codex-swift is licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).

It is a port of [OpenAI Codex](https://github.com/openai/codex), which is Copyright 2025 OpenAI and also Apache-2.0 licensed, and upstream's Rust implementation is the reference for its protocol, behaviour and session format. It contains no Rust source, but its prompt templates, model catalog and Seatbelt policy fragments are vendored verbatim from upstream so that behaviour matches, and [`CRATE_DISPOSITIONS.md`](CRATE_DISPOSITIONS.md) maps each upstream crate to its Swift target. The supervisor and per-session workers, the macOS lifecycle and resource governance, the memory systems, the addons and the parity tooling are specific to this project.

Personal memory reimplements [mem0](https://github.com/mem0ai/mem0) in Swift, and vector search uses a vendored copy of [sqlite-vec](https://github.com/asg017/sqlite-vec). The package builds on [Hummingbird](https://github.com/hummingbird-project/hummingbird), [SwiftNIO](https://github.com/apple/swift-nio), [MLX Swift](https://github.com/ml-explore/mlx-swift) and [swift-transformers](https://github.com/huggingface/swift-transformers), and the tasks in `Benchmarks/deep-swe` come from [DeepSWE](https://github.com/datacurve-ai/deep-swe).
