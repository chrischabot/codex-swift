# CodexKit Development Guide

This guide is the working manual for building, testing, running, and
extending codex-swift on a developer machine. It assumes you have read
`ARCHITECTURE.md` for the process model and the module layout. For the
wire protocol see `app-server-api.md`; for the canonical implementation
status see `../STATUS.md`.

## 1. Prerequisites

- **Swift 6.x toolchain.** The package is pinned to
  `swift-tools-version: 6.1` and `swiftLanguageModes: [.v6]`. Strict
  concurrency is on (`ExistentialAny` upcoming feature enabled). The
  current live verification was done on Swift 6.3.2.
- **macOS 14+ for production features.** The package's deployment
  target is `.macOS(.v14)` so it builds with current toolchains, but
  many production features require macOS 26 APIs and are conditionally
  available behind `if #available(macOS 26, *)` / `#if canImport(...)`.
  Lines tagged `// MACOS-COMPLETION:` in the sources mark surfaces that
  ship a portable core today and a macOS-native surface gated on the
  target SDK. Search for them with `grep -rn "MACOS-COMPLETION" Sources`.
- **Xcode (optional).** Only the SwiftPM toolchain is required. If you
  use Xcode, open `Package.swift` directly.
- **Linux.** The portable core (everything not behind a macOS gate)
  builds and tests on Linux. macOS-only paths — Seatbelt sandbox
  profile install, `task_set_phys_footprint_limit`,
  `task_policy_set`, Keychain token storage, launchd lifecycle,
  notarization, native URLSession SSE — are unavailable on Linux and
  are either gated out or replaced with a portable fallback (curl-SSE
  model client, plain-file token store under `$CODEX_HOME/auth`).
- **OpenAI API key (optional).** Live tests and live smokes auto-run
  when `OPENAI_API_KEY` is set in the environment, and skip cleanly
  with a clear message otherwise.
- **Apple Silicon Mac (optional).** Setting `CODEXKIT_MLX=1` opts the
  MemoryInfer module into MLX-backed embedding inference. Unset, the
  module uses a portable fallback. Linux ignores the flag.

## 2. Build

```sh
# Debug build (default).
swift build

# Release build (used by the e2e gates and smokes).
swift build -c release

# Via the Makefile.
make build      # == swift build
make release    # == swift build -c release
```

The package produces five executable targets:

- `codexd` — the supervisor daemon (see `Sources/codexd/main.swift`).
- `codex-session` — the per-session worker (see
  `Sources/codex-session/main.swift`).
- `codex-broker` — the shared auth/catalog daemon (see
  `Sources/codex-broker/`).
- `codex-memory` — the memory daemon.
- `mock-responses` — a deterministic local Responses fixture server
  used by tests and smokes that do not have an API key.

Library targets are listed in `Package.swift`. The dependency graph is
acyclic and documented in `ARCHITECTURE.md` §11.

macOS-gated modules and surfaces:

- Native URLSession SSE — picked at runtime when present; curl-SSE is
  the portable fallback.
- Seatbelt SBPL — emitted on all platforms but only installed when
  running under macOS sandbox-exec.
- Keychain-backed token store — used on macOS; on Linux the broker
  writes auth state to a `0600` file under `$CODEX_HOME/auth/`.
- Lifecycle (`launchctl`-driven) — only the macOS path is wired.
- Physical-footprint cap and QoS throttle — only enforced on macOS;
  on Linux the calls are no-ops with a documented degradation log line.

## 3. Test

```sh
# Run everything that does not require an API key by default,
# plus the live tier when OPENAI_API_KEY is set.
swift test

# Same, via Makefile.
make test

# Skip the live tier explicitly.
swift test --skip LiveTests --skip LiveDeepTests --skip LiveRealWorldTests

# Run only the live tier.
swift test --filter Live

# Run a single test by name (substring match).
swift test --filter HarnessCoreTests/testSessionSandboxBuilderHonorsClientSuppliedMode

# Release configuration regression gate (build + full suite + mock-responses self-test).
bash scripts/run-tests.sh --release
```

Filter syntax is SwiftPM's `--filter <regex>`. Common patterns:

- `--filter ToolsTests` — every test in the `ToolsTests` target.
- `--filter 'Tools.*Patch'` — every test under `ToolsTests` matching
  the regex.
- `--filter HarnessCoreTests/testFoo` — exact test method.
- `--skip <pattern>` — same syntax, applied as an exclude.

Live test gating: live test targets (`LiveTests`, `LiveDeepTests`,
`LiveRealWorldTests`) check `OPENAI_API_KEY` at test-method entry. Without
it they record a skip rather than failing. The same gating applies to
the `WebSearchTests` cases that require live web search credentials.

The full test grid is large (~580 deterministic tests + ~28 live OpenAI
tests at last verification). A focused inner loop should run the
affected target only and lean on the gate harness (next section) to
catch cross-module regressions.

Adversarial and integration tests are first-class targets:

```sh
swift test --filter AdversarialTests   # failure modes, malformed input, DoS
swift test --filter IntegrationTests   # supervisor↔worker, full transports
```

`make e2e` runs both:

```sh
make e2e   # swift build && swift test --filter IntegrationTests
           # && swift test --filter AdversarialTests
```

## 4. End-to-end harnesses (`tools/e2e/`)

The `tools/e2e/` directory holds the phase gates. Each gate is a thin
shell wrapper around the existing Swift tests and daemon smokes; they
fail fast and do not maintain an expected-failure list. The full per-
gate description lives in `tools/e2e/README.md`; what each gate proves
in shorthand:

| Gate | Proves |
|---|---|
| `g0_baseline.sh` | Release build, full non-live suite, stdio/WS/UDS smokes, live stdio smoke, and the live-filtered tests when keyed. |
| `g1_transport.sh` | Wire and local transport contracts, app-server method coverage, stdio↔UDS bridge compatibility, real UDS JSONL through a spawned worker. |
| `g2_model_persistence.sh` | Model request shaping, persistence, Rust-shaped rollout read/write parity, resume, byte-faithful prompt continuity. |
| `g3_tools_sandbox.sh` | Tools, sandbox policy and profile generation, live kernel network denial, symlink containment, adversarial tool tests. |
| `g4_auth_broker_memories.sh` | Auth, broker, MCP, hooks, and memory flows. Builds `codex-broker`. |
| `g5_full_corpus.sh` | Schema-oracle parity (pinned Codex types), transcript replay against the Rust oracle, the broad deterministic protocol/prompt/persistence/tools/MCP/hooks/connectors/realtime suite, and live OpenAI coverage. The largest gate. |
| `g6_hardening_smoke.sh` | Adversarial/failure campaign, fsync `EINTR` retry, fork-bomb process-group containment, worker isolation, model-transport fault campaign. |
| `g6_lifecycle.sh` | launchd plist render, hardened-runtime entitlements, ad-hoc and Developer ID signing verification, install/status/uninstall, KeepAlive restart. |
| `g6_codesign_smoke.sh` | Stage release binaries, ad-hoc sign with entitlements, verify strict signatures. |
| `g6_developer_id_sign_smoke.sh` | Developer ID signing, signed-only Gatekeeper rejection, optional notarization/stapler/Gatekeeper assessment when `CODEXKIT_NOTARY_PROFILE` is set. |
| `g6_clean_machine.sh` | Empty-root install, first initialize/turn, explicit purge uninstall, launchd/file cleanup; gated trueCleanMachine evidence when run on the release hardware. |
| `g6_blue_green.sh` | Versioned lifecycle release staging plus `promote-worker` swap/rollback; quiet sessions keep running. |
| `g6_reboot_resume.sh` | Durable same-thread resume after launchd restarts `codexd`. |
| `g6_true_reboot_resume.sh` | Two-phase real reboot gate; prepare records kernel boot time, verify requires it to change. |
| `g6_active_turn_crash.sh` | SIGKILL `codexd` during an active turn, verify the turn is durable as `interrupted` and a later turn completes. |
| `g6_poison_worker.sh` | Worker binary that exits immediately on launch cannot break the daemon or quiet sessions. |
| `g6_physical_footprint.sh` | Real `task_set_phys_footprint_limit` enforcement evidence; strict mode requires SIGKILL after the cap was set. |
| `g6_soak.sh` | Configurable soak/noisy-neighbor harness, TTFT/output-rate SLOs, durability p99, fd/RSS trends, optional live multi-session coding through spawned workers. |
| `g6_noisy.sh` | Heavier noisy-neighbor preset over `g6_soak.sh`. |
| `g6_fault.sh` | Fault containment composite: adversarial, poison worker, real launchd SIGKILL restart. |
| `g6_launchd_smoke.sh` | Direct user-domain launchd smoke: bootstrap, probe sockets, SIGKILL, restart, bootout. |
| `g9_final_rehearsal.sh` | The release-certification rehearsal. Composes the above, writes a final manifest, and runs the strict evidence verifier. |

When to run which:

- **During iteration on a single module:** `swift test --filter <Target>`.
- **Before opening a PR that touches transport, wire, or
  supervisor/worker:** `g0_baseline.sh` plus the matching narrow gate
  (`g1_transport.sh`, `g2_model_persistence.sh`, …).
- **Before claiming app-server parity for a method:** `g5_full_corpus.sh`.
- **Before a release rehearsal:** `g9_final_rehearsal.sh` with the
  strict environment described in `docs/release-certification-runbook.md`.

Most gates honor `CODEXKIT_EVIDENCE_DIR=/path/to/dir` to emit JSON
evidence artifacts. `verify_release_evidence.py` audits the directory
in local or strict mode. `strict_release_readiness.py` is the fast
preflight that checks the external strict inputs (notary profile, true
clean-machine attestation, soak sizing, …) without running the
rehearsal.

## 5. Smoke scripts (`scripts/`)

Smokes are short bash scripts that drive the real `codexd` binary
against either the mock-responses fixture server or the live OpenAI
Responses API. They are intentionally minimal so a failure is easy to
read.

```sh
# stdio JSONL against mock-responses. Always runs.
make smoke
# == bash scripts/codexd-stdio-smoke.sh

# stdio JSONL against the live OpenAI Responses API.
# Skips cleanly when OPENAI_API_KEY is unset.
make live-smoke
# == bash scripts/codexd-stdio-live-smoke.sh

# Unix-socket app-server smoke: `0600` socket, `/readyz`,
# Origin→403, WebSocket upgrade, JSONL initialize,
# spawned-worker thread/start → turn/start → turn/completed.
bash scripts/codexd-uds-smoke.sh

# A second UDS shape: drive the daemon over stdio while it
# also serves an internal UDS path.
bash scripts/codexd-stdio-to-uds-smoke.sh

# Loopback TCP WebSocket smoke.
bash scripts/codexd-ws-smoke.sh

# Lifecycle (install/status/uninstall) smoke through the
# codexkit CLI wrapper, when present.
bash scripts/codexkit-lifecycle.sh

# Build + swift test + mock-responses self-test in one shot.
bash scripts/run-tests.sh           # debug
bash scripts/run-tests.sh --release # release
```

What to expect from `codexd-stdio-live-smoke.sh` on a green run:

- Builds debug.
- Drives `initialize → initialized → thread/start (model=gpt-4o-mini)
  → turn/start`.
- A spawned `codex-session` worker logs its startup.
- The response stream carries a streamed assistant delta and a
  terminal `turn/completed` notification.
- A pure-bash watchdog kills the run after a fixed budget if it stalls.

If `OPENAI_API_KEY` is unset, the script prints `SKIP` and exits 0.

## 6. Cat-scan tooling

`catscan` is the comprehensive harness validator used during real-
world driving against the live API; it catches wire-protocol
regressions that unit tests do not (the `URLSessionResponsesClient`
log line tagged `[catscan]` is the standard breadcrumb). Production
catscan harnesses live as `/tmp/codex_real_world_drive*.py` style
drivers; they spawn the release `codexd` binary, run multi-turn
coding sequences against the live API, and assert on the streamed
event sequence plus the durable rollout.

Use a catscan run when:

- A change touches `Sources/ModelClient/`, `Sources/HarnessCore/
  PromptAssembly.swift`, or any tool that the model actually calls
  in real workloads.
- The unit suite is green but a real-world session degrades. See
  the `STATUS.md` "Current real-world driver evidence" entries for
  examples of defects unit tests missed and catscan caught (sandbox
  wire-through, file-tool symlink containment on the workspace root,
  `code` tool description vs. JavaScriptCore semantics, etc.).
- Before claiming a model-facing behavior change is shippable.

The drivers are not committed to the repo today; they live next to
each investigation. When you need one, lift the most recent shape
out of the `STATUS.md` narrative and adapt it.

## 7. Running a local daemon

The supervisor decides its transport from `--listen`. Examples:

```sh
# stdio (default if no --listen): drive the daemon directly over its stdin/stdout.
swift run codexd

# Unix domain socket, JSONL by default, with WebSocket upgrade on the same socket.
swift run codexd --listen unix:///tmp/codexd.sock

# Loopback TCP WebSocket. Non-loopback binds are rejected.
swift run codexd --listen ws://127.0.0.1:9101

# Pass --listen=value or --listen value; both work.
swift run codexd --listen=unix:///tmp/codexd.sock
```

`CODEX_HOME` controls where durable state lives. Override it for a
sandboxed local run so the daemon does not touch your real
`~/.codex`:

```sh
WORK=$(mktemp -d)
CODEX_HOME="$WORK/home" swift run codexd --listen unix:///tmp/codexd.sock
```

`CODEXKIT_SESSION_BIN=/path/to/codex-session` overrides where the
supervisor finds the worker binary; this is what `g6_poison_worker.sh`
swaps to drive containment tests.

`CODEXKIT_LIVE_MODEL` overrides the model id used by live smokes and
some live tests; default is `gpt-4o-mini`.

The daemon logs to stderr (`os.Logger` on Apple platforms, bridged
through `Observability.Logger`). The structured feedback log buffer
(`FeedbackLogStore.shared`) is in-memory and is what powers
`feedback/*` and crash-context capture.

## 8. Driving via JSON-RPC

The wire dialect is `codex app-server` JSON-RPC: untagged
request/response/notification shapes, ids may be integer or string,
the literal `"jsonrpc":"2.0"` field is omitted. See
`docs/app-server-api.md` for the full surface; the example below is
the minimum a client needs.

```sh
# 1. Start the daemon over stdio so we can hand-drive it.
swift run codexd <<'EOF'
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"hello"}}}
{"method":"initialized"}
{"id":2,"method":"thread/start","params":{"cwd":"/tmp","model":"gpt-4o-mini"}}
{"id":3,"method":"turn/start","params":{"threadId":"thr_REPLACE","input":[{"type":"text","text":"Reply with: hello"}]}}
EOF
```

Expected on stdout:

1. `initialize` response with the supported capabilities.
2. `initialized` is a notification — no response.
3. `thread/start` response carrying the new `threadId` (use it for
   `turn/start`). Parse the `thr_…` id from the response stream
   before you send `turn/start`; the live smoke script demonstrates
   the pattern.
4. `turn/started` notification.
5. A burst of `item/started` + `item/updated` notifications carrying
   the streamed assistant deltas.
6. A `turn/completed` notification with status `completed`.

Common flow variants:

- `thread/resume` — instead of `thread/start` with a fresh
  conversation, rebind a persisted one by id. The supervisor
  reconstructs from rollout + SQLite and spawns a worker.
- `turn/interrupt` — request cancellation of the in-flight turn. The
  worker exits the stream with `interrupted` status.
- `thread/compact/start` — manual compaction; streams normal item
  progress plus a terminal `thread/compacted` notification.

## 9. Adding a new tool

Tools are the model-visible action surface. The pattern is:

1. **Implement the protocol.** Add a new file under `Sources/Tools/`
   (for example `Sources/Tools/MyTool.swift`). Conform to
   `Tools.Tool` (see `Sources/Tools/ToolRouter.swift`):

   ```swift
   public protocol Tool: Sendable {
       var name: String { get }
       var description: String { get }
       var schema: ToolSchema? { get }   // optional, default nil
       func call(_ args: ToolCallArgs, ctx: ToolContext) async throws -> ToolCallResult
   }
   ```

   The description is what the model actually reads. Be explicit about
   runtime semantics, side effects, and containment — see the
   `unified_exec`, `shell`, and `code` description fixes in `STATUS.md`
   for examples of where vague descriptions confused live models.

2. **Register the tool.** Add a registration call to
   `Tools.DefaultTools.register` in `Sources/Tools/ShellTool.swift`.
   `DefaultTools.register` is the single registration site used by
   both production entry points (`Sources/codexd/main.swift` and
   `Sources/codex-session/main.swift`) and by integration tests, so a
   tool added here lights up everywhere.

   ```swift
   await router.register(MyTool(/* deps */))
   ```

   If the tool should only appear under specific configuration
   (experimental flag, sandbox mode, MCP catalog presence), gate the
   `register` call inside `DefaultTools.register` rather than at the
   call sites — this keeps the policy in one file.

3. **Add tests.** Add a `MyToolTests.swift` under
   `Tests/ToolsTests/`. Include:
   - happy-path argument decoding;
   - schema parity test if `schema` is non-nil;
   - sandbox containment tests where the tool touches files or
     processes;
   - adversarial input (malformed args, oversize input, path escape
     attempts) — these belong in `Tests/AdversarialTests/`.

4. **Hook into `PromptComposer` if needed.** Most tools are exposed
   purely through `ToolRouter`. If the tool needs a prompt sample,
   inline doc, or special tool-search ranking, update
   `Sources/HarnessCore/PromptAssembly.swift` and the matching
   `PromptsTests` cases.

5. **Run the gate.** `swift test --filter ToolsTests` first;
   `g3_tools_sandbox.sh` for sandbox-touching tools; a catscan run
   if the tool's description affects model behavior.

6. **Update `STATUS.md`.** Add the tool to the implemented-tools
   list and note any macOS-only behavior.

## 10. Adding a new MCP server config

MCP server lifecycle is owned by the worker. To add a new server,
extend the configuration surface and the worker registration path.
The end-to-end story — discovery, configuration, status, tool-call
routing, OAuth flow — lives in `docs/MCP.md`. Start there; this
guide does not duplicate the per-feature steps.

## 11. Adding a new hook event handler

Hooks bridge external scripts into turn lifecycle events (after-agent,
trust-gated tool runs, notify). The wire surface and the trust-hash
contract live in `docs/HOOKS.md`. Add new events there and update
`Sources/HarnessCore/Hooks.swift`.

## 12. Common debugging

Log locations:

- `~/.codex/log/` — production launchd installation log path. The
  `g6_lifecycle.sh` and `g6_launchd_smoke.sh` gates exercise this
  path.
- stderr — debug and `swift run` log destination by default. On Apple
  platforms this also bridges to `os.Logger` (subsystem
  `dev.codexkit.*`), so `log stream --predicate
  'subsystem CONTAINS "codexkit"'` shows live output without
  redirecting stderr.
- `FeedbackLogStore.shared` (`Sources/Observability/Observability.swift`)
  — in-memory ring of recent log lines, retained per process. The
  router exposes this through the `feedback/*` methods so a client
  can ask the daemon for its recent log tail.

Observability primitives worth knowing:

- `InfraPrimitives.FlightRecorder` — bounded ring of
  high-frequency events (model deltas, IPC frames, watchdog
  samples). Used by adversarial tests to assert that a stress run
  did not drop into an unbounded growth pattern.
- `InfraPrimitives.Rings` — generic coalescing and overwrite ring
  buffers. The `g6_soak.sh` bounded-primitives probe is the
  canonical evidence path.
- `Observability.MetricsSink` — typed metric counters with OTLP
  export support (`Sources/Observability/OTLP.swift`). Drain through
  `OTLPExporter.drainAndExport(_:)`.

Common debugging recipes:

- **A worker is not starting.** Check `CODEXKIT_SESSION_BIN`. The
  supervisor logs the resolved path on spawn. Check that the
  binary's stdin/stdout pipes are correctly inherited (the
  `g6_poison_worker.sh` shape is the reference).
- **A method returns `-32601` (method not found).** The router
  intentionally returns `-32601` only for truly unknown methods.
  Most schema-known methods return a documented default response
  instead — see `app-server-api.md`.
- **A method returns `-32001` (overload).** The resource governor
  is in hard/terminal state for the affected worker. Inspect the
  resource sampler logs and the `ResourceLedger` snapshot in the
  supervisor.
- **A live test passes but a real session degrades.** Run a catscan
  driver. The driver's tool-call tracking surfaces issues the unit
  suite cannot reach (model misinterpretation of tool descriptions,
  multi-turn pathological loops, etc.).

## 13. Performance and profiling

Production performance patterns are spelled out in
`docs/system-guide.md` (the "Performance practices" section). The
short list when extending the system:

- Keep accept loops cheap. Listener accept threads must never block
  on header parsing; `Sources/Supervisor/SocketServer.swift` is the
  reference shape.
- Prefer bounded channels and rings over unbounded arrays for
  high-frequency deltas. `InfraPrimitives.BoundedChannel` and
  `InfraPrimitives.Rings` are the primitives.
- Single-flight shared expensive work (`InfraPrimitives.SingleFlight`).
  Auth refresh, catalog loads, and repeated metadata fetches are
  the canonical examples; the broker uses it as its primary
  coalescing mechanism.
- Cache only when invalidation is explicit. `skills/changed`,
  `fs/changed`, MCP startup updates, and config writes are all
  explicit invalidation signals.

Profiling tools:

- **`os_signpost`.** Hot paths in the model client and turn loop
  emit signposts under the `dev.codexkit.signposts` subsystem. Open
  Instruments → Time Profiler → Signposts to scope a profile to one
  turn.
- **`MetricsSink` + OTLP.** Drive `Observability.OTLPExporter`
  against a local collector (Jaeger/Tempo/etc.) for a low-friction
  trace view. The metric points exported are documented in
  `Sources/Observability/OTLP.swift`.
- **Ring metrics.** `InfraPrimitives.Rings` exposes per-ring
  drop/coalesce counters. Adversarial coverage in
  `bounded_primitives_probe.py` reads these to prove flat-growth
  behavior under saturation.
- **`g6_soak.sh`.** The release soak harness produces fd/RSS/worker-
  count trend evidence plus rollout/SQLite p99 latency assertions.
  Use it as the perf regression detector before a release.

When you change anything in the turn loop, the model client, or the
prompt assembly, attach `g6_soak.sh` output to the change. When the
target is steady-state cost (idle daemon, hot reload, large
`thread/list`), Instruments + signposts is faster than a soak run.
