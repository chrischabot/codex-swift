# DeepSWE-on-codex-swift — Design, Architecture & Implementation Plan

Status: **Design / Phase-0 spike complete.** Owner: benchmark subsystem.
Last updated: 2026-05-30.

This document specifies a native macOS benchmark runner that executes the
[deep-swe](https://github.com/datacurve-ai/deep-swe) task suite using
**codex-swift itself as the solving agent**, isolates each task in an
[`apple/container`](https://github.com/apple/container) lightweight VM (no
Docker, no Harbor/Pier), and produces a **Pass@1** score methodologically
comparable to the [deepswe.datacurve.ai](https://deepswe.datacurve.ai/)
leaderboard — plus two additional reported dimensions (code-quality and an
independent LLM judge driven by the local `codex` CLI).

---

## 1. Goals & non-goals

**Goals**

- Run deep-swe's **113 tasks** natively on macOS via `apple/container`; no Docker
  dependency at runtime (Docker remains a CI/Linux fallback backend).
- Drive **codex-swift** (our harness) as the agent, with its **full native tool
  surface** — we are benchmarking *our* harness against the leaderboard models.
- Three run modes:
  1. one specific named task (`--task <id>`),
  2. `N` randomly selected tasks with a recorded seed (`--random N`) — the cheap
     "run 3 to confirm everything works without burning hours of tokens" mode,
  3. the full 113-task suite (`--all`).
- A headline **Pass@1 (± binomial CI)** comparable to the leaderboard, **plus**
  separately-reported **code-quality** and **LLM-judge** dimensions.
- Reproduce the leaderboard's reportable columns: Pass@1, avg cost, avg
  wall-time, avg output tokens.

**Non-goals**

- Bit-exact reproduction of their *absolute* numbers. The agent scaffold differs
  (their mini-swe-agent is a single bash tool; we run codex-swift's real tools —
  see §11). We target *methodological* comparability with an explicit caveat
  banner on every report.
- Folding quality/judge scores into the headline Pass@1. The leaderboard doesn't;
  doing so would break comparability. They are independent dimensions.

---

## 2. Research findings that drive the design

### 2.1 deep-swe is task-data only; the grading contract is small and reproducible

The repo ships **no runner** — it assumes the external **Pier** tool (a Harbor
fork). Each task is a directory:

```
tasks/<task-id>/
  task.toml             # ext_id (= image tag), base_commit_hash, language,
                        # cpus/mem/storage, [verifier].timeout_sec, [agent].timeout_sec,
                        # [environment].docker_image, allow_internet=false
  instruction.md        # the natural-language prompt handed to the agent
  environment/Dockerfile  # FROM public.ecr.aws/.../mars-base; git clone + checkout
                        # base_commit; install deps  (FALLBACK build recipe)
  tests/test.sh         # OUTER verifier (the grading entrypoint)
  tests/test.patch      # hidden tests, git-applied at grade time (also drops an
                        # INNER test.sh at repo root)
  solution/solution.patch + solve.sh   # reference fix — HELD OUT, never graded
```

- **113 tasks**, 91 repos, languages: TypeScript 35, Go 34, Python 34, JS 5,
  Rust 5. Categories: feature_request 106, enhancement 3, bugfix 4.
  `manifest.json` declares `source_dataset = "swe-bench-ultra"`.
- Prebuilt images live on a **public ECR** (`public.ecr.aws/d3j8x8q7/swe-bench-202605:<ext_id>`,
  anonymous pull), all `FROM public.ecr.aws/x8v8d7g8/mars-base:latest`.
- The **grading contract** (outer `tests/test.sh`, identical across all 113 tasks
  modulo the embedded base-commit hash):
  1. `cd /app`; `git config --global --add safe.directory`; assert base commit exists.
  2. capture the agent diff: `git reset --soft <base>; git add -A; git diff --cached --binary > /logs/artifacts/model.patch; git reset -q`.
  3. reset any file the hidden `test.patch` touches: parse `b/<file>` targets, `git checkout HEAD -- <file>` (or remove). Prevents the agent pre-satisfying / clobbering tests.
  4. `git apply --whitespace=nowarn /tests/test.patch` (this also drops an *inner* `test.sh` + e.g. `vitest.new.config.ts` at the repo root).
  5. `bash /app/test.sh base` → `BASE_RESULT` (regression suite = PASS_TO_PASS) and `bash /app/test.sh new` → `NEW_RESULT` (new-behavior tests = FAIL_TO_PASS).
  6. **`reward = 1` iff `BASE_RESULT==0 && NEW_RESULT==0`, else `0`.** Written to `/logs/verifier/reward.txt`. Binary; no partial credit; no LLM judge in the grading path.
- Verifiers test **observable behavior via public APIs**, not implementation
  shape — so any correct implementation passes regardless of internal naming.

### 2.2 The leaderboard metric

- **Pass@1 = uniform mean of the binary reward over all 113 tasks**, with a
  binomial-style ± confidence interval ("ignore <5% differences").
- Their **LLM-as-judge exists only to audit verifiers** (QA), **not to score**
  (measured 0.3% FP / 1.1% FN on deep-swe). We mirror this: judge is a reported
  dimension and a verifier-audit, never part of Pass@1.
- Reference scaffold: **mini-swe-agent** (single shared bash tool, shared prompt,
  no model-specific edit primitives) via **Pier** on **Modal**. Top entries
  (May 2026): gpt-5.5 70%, claude-opus-4.8 58%, gpt-5.4 56%, claude-sonnet-4.6 32%.
- Air-gapped (`allow_internet=false`) + shallow clone at base commit (no git
  history / gold hash) → anti-cheat.

> ⚠️ **Name collision:** the *DeepSWE model* (Together AI/Agentica, ~59% on
> SWE-bench Verified) is unrelated to the *DeepSWE benchmark* (Datacurve) that
> this runner targets.

### 2.3 apple/container (validated on this machine: macOS 26.4.1, arm64)

- **Apple-silicon only; macOS 26** recommended (we have 26.4.1 ✓). One
  lightweight VM per container. Install is a signed **`.pkg`** (admin) — **not yet
  installed here** (prerequisite, see §12 Phase 0).
- CLI: `container build` (BuildKit), `container run` (foreground **propagates the
  inner exit code**), `container exec`, `container cp` (**requires a *running*
  container**), `container export`, `container system start`.
- Bind mounts via **virtiofs**: `-v /abs/host:/abs/ctr[:ro]`; host files appear
  **root-owned** inside the guest.
- The prebuilt swe-bench ECR images are **amd64-only** (single-arch manifest), but
  the shared `mars-base` is a **multi-arch manifest list with a native `linux/arm64`
  variant**, and every task Dockerfile is `FROM mars-base` + arch-agnostic install
  (`npm ci` / `pip install -e .` / `cargo fetch` / `go mod download`). ⇒ We **build
  each image natively for arm64 from its Dockerfile** — no Rosetta. (Optional amd64
  pull kept as a per-task fallback.)
- Each container gets its **own IP** on macOS 26 (reachable from host) — relevant
  for the exec-server bridge (§5).
- A real **Swift API** exists (`ContainerAPIClient` over XPC; or the lower-level
  daemon-free `Containerization` `LinuxContainer`). We start by shelling out to the
  `container` CLI (portable, simple) and can graduate to the Swift API later.

### 2.4 codex-swift already has everything we need to run *inside* a container

- **`SessionConfig.remoteEnvironment.execServerUrl`** is wired end-to-end:
  `Sources/codex-session/main.swift:233`, `Sources/codexd/main.swift:226`,
  `Persistence/ThreadStore.swift:329`, `Supervisor/RequestRouter.swift:1437`. When
  set, `RemoteExecServerTools.register(...)` swaps the entire tool surface to
  remote variants.
- **`Sources/Tools/RemoteExecServerTools.swift`** implements a *complete* remote
  toolset against a WebSocket JSON-RPC "exec-server" protocol:
  `shell_command`, `unified_exec`, `apply_patch`, `git_diff`, `file_search`,
  `read_file`, `write_file`, `list_dir`. Protocol methods: `initialize`,
  `process/start`, `process/read`, `process/write`, `process/terminate`,
  `fs/readFile`, `fs/writeFile`, `fs/remove`, `fs/createDirectory`,
  `fs/readDirectory`, `fs/copy`. URL schemes: `ws`/`wss` direct, or `http(s)`
  executor-registry that returns a rendezvous `wss://`.
- **The local `codex` CLI (0.134.0) is the *server* side of that exact protocol:**
  `codex exec-server --listen ws://IP:PORT` (also `--remote`, `--environment-id`).
- The same CLI gives us the **LLM judge**: `codex exec --output-schema <FILE>
  --output-last-message <FILE> [--json] -m <model> -s read-only` → a
  schema-validated structured verdict.
- Headless driving precedent: the `LiveTests` target drives `SessionEngine`
  in-process, gated on `OPENAI_API_KEY`. `TurnDiffTracker` accumulates the
  produced diff; `tokenUsageUpdated`/`ModelCatalog` give tokens + cost.

### 2.5 Native-macOS optimization validated

- **APFS `clonefile`** copy-on-write: cloning a 120 MB + 300-file tree took
  **33 ms**. ⚠️ Homebrew's GNU `cp` shadows BSD `cp` on PATH — **use
  `/bin/cp -c` explicitly, or `copyfile(3)` with `COPYFILE_CLONE_FORCE` /
  `clonefile(2)` from Swift.** Never bare `cp`.
- deep-swe task data is **9.4 MB** of text → vendored directly into the repo
  (largest task 160 KB).

---

## 3. Architecture overview

A new `BenchKit` library + `codex-bench` executable, beside the existing targets.
The orchestrator runs on the host; each task runs in an isolated `container` VM;
**codex-swift runs on the host but executes entirely inside the task's container**
via the exec-server bridge (§5).

```
                       ┌──────────────────────── codex-bench (host) ────────────────────────┐
 Benchmarks/deep-swe/  │  TaskCatalog ─► Scheduler ─► [ per task, K in parallel ] ─► Reporter│ ─► results/<run-id>/
 (vendored, 9.4MB)     │  (parse+validate)                                                   │   (Pass@1±CI, cost,
                       │                                                                      │    time, tokens, quality,
                       │   ┌──────────────────── per-task pipeline ─────────────────────┐    │    judge)
                       │   │ 1. ImageResolver  pull ECR ▸ else build Dockerfile ▸ cache  │    │
                       │   │ 2. Workspace      extract /app template ▸ APFS clonefile    │    │
                       │   │ 3. Container      run VM, bind-mount clone@/app + logs,     │    │
                       │   │                   network OFF (air-gap)                     │    │
                       │   │ 4. ExecBridge     ContainerExecServer (ws://) : fs→clone,   │    │
                       │   │                   process→`container exec -w /app`          │    │
                       │   │ 5. AgentDriver    codex-swift SessionEngine, remoteEnv=     │    │
                       │   │                   ws bridge, prompt=instruction.md, timeout │    │
                       │   │ 6. Verifier       faithful test.sh: capture patch ▸ reset   │    │
                       │   │                   test files ▸ apply test.patch ▸ base&new  │    │
                       │   │                   ▸ reward            ◀── Pass@1            │    │
                       │   │ 7. QualityScorer  diff vs solution.patch + lint/typecheck   │    │
                       │   │ 8. LLMJudge       `codex exec --output-schema` verdict      │    │
                       │   └─────────────────────────────────────────────────────────────┘   │
                       └──────────────────────────────────────────────────────────────────────┘
```

---

## 4. The container execution & workspace model

### 4.1 Per-task image (cache once, by `ext_id`)

`ImageResolver` (**build-arm64-from-Dockerfile** — the chosen policy; native, no
Rosetta):

0. **Cache the shared base once:** `container image pull --platform linux/arm64
   public.ecr.aws/x8v8d7g8/mars-base:latest` **with exponential backoff** (anonymous
   `public.ecr.aws` rate-limits aggressively — observed `429 TOOMANYREQUESTS`). All
   113 builds then reuse the cached arm64 base; only this *one* ECR fetch is needed
   (per-task `RUN` steps clone from GitHub and pull from npm/pip/cargo, not ECR).
   For unattended full-suite runs, consider authenticating to ECR Public or
   mirroring `mars-base` into a local/registry cache to avoid 429s entirely.
1. `container build --arch arm64 -t codex-bench/<ext_id>
   -f tasks/<id>/environment/Dockerfile tasks/<id>/environment` (native arm64;
   reuses the cached base + BuildKit layer cache).
2. Optional fallback: `container image pull
   public.ecr.aws/d3j8x8q7/swe-bench-202605:<ext_id>` (amd64 → Rosetta) for a task
   that misbehaves on arm64.
3. Record arch/source/digest in the run manifest for reproducibility.

### 4.2 Workspace: APFS clone over the deps-bearing template

The image installs deps **into `/app`** (`node_modules`, `.venv`, build caches),
so a naïve bind-mount of bare source over `/app` would **hide** them. Solution —
extract once, clone per run:

- **Template (once per `ext_id`):** start a throwaway container; `container cp
  <cid>:/app/. <cache>/templates/<ext_id>/` (full source **+ installed deps**);
  delete the throwaway.
- **Per run (instant):** `copyfile(COPYFILE_CLONE_FORCE)` (or `/bin/cp -cR`) the
  template → `<run>/<task>/workspace`. APFS COW ⇒ ~free even for large
  `node_modules`. This is the native optimization that makes the full suite +
  retries cheap.
- Start the task container with `-v <run>/<task>/workspace:/app` and `-v
  <run>/<task>/logs:/logs`. The clone already carries deps ⇒ bind-mount hides
  nothing.

### 4.3 Air-gap (faithful anti-cheat)

- The `solution/` directory **never enters the container** (host-side only, for
  quality + judge).
- **Container network disabled** during agent + verify phases. codex-swift's model
  calls are host-side and unaffected. (Phase-0 confirms the exact `apple/container`
  no-egress mechanism; floor: no published ports + `--no-dns` + no creds in env.)
- Optionally strip `.git` history in the template to match their shallow-clone
  posture (the verifier only needs the base commit object to exist; a grafted
  shallow checkout suffices).

### 4.4 Arch

**Default: native arm64** (build from Dockerfile; `mars-base` has an arm64 variant
and toolchain installs are arch-agnostic). No Rosetta. `--arch amd64` is an opt-in
per-task fallback (pull prebuilt, run under Rosetta) for the rare task whose tests
are arch-sensitive.

---

## 5. codex-swift ⇄ container integration (the crux)

We must make codex-swift's **file ops and exec run inside the container** while
its **model calls stay on the host**. codex-swift already exposes the seam:
`SessionConfig.remoteEnvironment.execServerUrl`. Three options were considered;
we choose **(A)**.

### (A) — *Chosen.* `ContainerExecServer` bridge (BenchKit owns the server)

BenchKit implements the WebSocket exec-server protocol (the contract is fully
specified by the existing client in `RemoteExecServerTools.swift`) and bridges:

- **`fs/*`** → the **host bind-mounted clone** (fast, native; visible in the
  container because it's mounted at `/app`).
- **`process/start|read|write|terminate`** → **`container exec -w /app <cid> …`**,
  streaming stdout/stderr back as base64 chunks with the seq-window semantics the
  client expects.

codex-swift connects with `remoteEnvironment.execServerUrl = ws://127.0.0.1:<port>`.

**Why this wins:**
- **Zero changes to codex-swift core** — only configuration. The full remote tool
  surface (`apply_patch`, `git_diff`, `file_search`, `shell`, `unified_exec`, …)
  already targets it.
- **Single path namespace** — everything is `/app`; no host/container path duality.
- `git_diff` (a built-in remote tool) yields the model patch directly.
- "Native and optimized for our project": we own the bridge, it needs no external
  Linux binary.

Cost: implementing the protocol server (process lifecycle + fs methods). Bounded
and well-specified.

### (B) — Fallback. `codex exec-server` inside the container

Run the codex CLI's own `codex exec-server --listen ws://0.0.0.0:PORT` *inside*
the container (needs a **Linux** codex binary in the image + reach the container
IP from the host). Zero protocol code, but adds a Linux-binary dependency and
auth/config surface. Kept as a fallback / cross-check.

### (C) — Fallback. Local tools + exec-wrap

Run codex-swift in-process with local tools (file ops on the host clone) and wrap
only `shell`/`unified_exec` to prefix `container exec -w /app`. Simplest to start,
but introduces host-cwd vs `/app` path duality (works for relative paths, fragile
for absolute). Useful for an early smoke test before (A) lands.

### Agent driving

`AgentDriver` follows the `LiveTests` pattern: in-process `SessionEngine` (later
optionally a spawned `codexd`) with:

- `cwd = /app`, `model` from config, `sandboxMode = workspaceWrite`,
  `remoteEnvironment = ws bridge`, network policy off for exec.
- One turn with `instruction.md` as user input.
- Collect `ServerNotification`s until `turnCompleted`; enforce the per-task
  **agent timeout** (`task.toml [agent].timeout_sec`) via cancellation.
- Capture: produced diff, full trajectory (for the judge), token usage, wall-time,
  computed cost.

---

## 6. Verification & scoring

### 6.1 Pass@1 — faithful `test.sh` reproduction (the comparable number)

`Verifier` reproduces the outer `tests/test.sh` flow **inside the container**
(§2.1 steps 1–6), with `tests/test.sh` + `tests/test.patch` mounted at `/tests`
and `/logs` writable. Per-task **verifier timeout** (`[verifier].timeout_sec`)
enforced by killing the container process group. Identical across all 113 tasks ⇒
one implementation.

**Aggregate Pass@1** = mean(reward) over selected tasks, with a **Wilson** (and
Wald, for direct comparison to their `±`) binomial CI. The `--random N` and
`--all` reports surface `n` and the CI prominently; the 3-task smoke run is
explicitly labeled "smoke test, not a score" (its CI spans tens of points).

### 6.2 Code-quality dimension (our extension, reported separately)

A composite `QualityScore ∈ [0,1]`, computed host-side, **gated on reward==1**:

- **Diff focus** — files-touched / lines-changed vs. `solution.patch` (soft
  signal; behavioral verifiers don't require shape-match → low weight).
- **Cleanliness** — run the repo's own linter/formatter/type-checker if present
  (`eslint`/`prettier`, `gofmt`/`go vet`, `ruff`/`mypy`, `cargo clippy`) against
  the diff inside the container; score = clean/total.
- **No collateral damage** — already enforced by `base` mode; surfaced here too.

Clearly labeled **not part of Pass@1**.

### 6.3 LLM judge via the codex CLI (mirrors deepswe's audit judge)

`LLMJudge` invokes the **independent** local `codex` CLI (a different model family
than the agent ⇒ judge independence):

```
codex exec --skip-git-repo-check -s read-only -m <judge-model> \
  --output-schema docs/benchmarks/judge.schema.json \
  --output-last-message <out>/verdict.json  <judge-prompt-on-stdin>
```

Inputs: `instruction.md`, the model diff, the agent trajectory, the verifier
base/new logs + reward, and the **reference solution** (the judge *may* see it —
post-hoc QA, never fed to the agent). Output (schema-validated):

```json
{ "outcome": "pass|fail", "agrees_with_verifier": true,
  "failure_mode": "none|incomplete|regression|wrong_approach|...",
  "quality_rubric": { "correctness": 5, "scope": 4, "idiomatic": 4 },
  "rationale": "…" }
```

Used for (a) **auditing our verifier reproduction** (flag pass/fail the judge
disagrees with) and (b) a reported quality signal. **Not** folded into Pass@1.

---

## 7. Run modes & CLI

```
codex-bench run --task <task_id>                  # 1) one named task
codex-bench run --random 3 [--seed 42]            # 2) N random (smoke run; seed recorded)
codex-bench run --all                             # 3) full 113-task suite
    [--lang go,python] [--category bugfix]        # filters
    [--concurrency K] [--attempts N]              # parallelism; Pass@k if N>1
    [--model gpt-5.5] [--judge on|off] [--quality on|off]
    [--arch amd64|arm64] [--keep-workspaces] [--resume <run-id>]
codex-bench list   [--lang …]                     # catalog
codex-bench prepare [--task …|--all]              # warm image + template cache
codex-bench report <run-id> [--format md|json]    # re-render a finished run
codex-bench doctor                                # container daemon, codex CLI, APFS, disk, macOS
```

Defaults: judge + quality **on** for `--task`/`--random`, **off** for `--all`
unless explicitly enabled (cost control on large runs). `--random` uses a seeded
RNG and records the seed + selected ids for reproducibility.

---

## 8. Results, reporting & leaderboard comparability

`results/<run-id>/`: `run.json` (config, seed, codex-swift git SHA, container
version, image digests, caveat banner), `tasks/<task>/` (model.patch, base/new
logs, reward, trajectory, usage, judge.json, quality.json), and top-level
`report.md` / `report.json`. **Resumable** (skip tasks with a completed result).

Report reproduces the leaderboard columns so a codex-swift row drops next to
theirs:

| Metric | Source |
|---|---|
| **Pass@1 ± CI** | mean reward; Wilson + Wald CI over `n` |
| Avg cost | Σ(usage × `ModelCatalog` price) / n |
| Avg wall-time | per-task agent+verify wall clock |
| Avg output tokens | `UsageSnapshot` |
| Quality (ours) | §6.2, separate |
| Judge agreement (ours) | §6.3, separate |

---

## 9. Code layout & new SwiftPM targets

```
Sources/BenchKit/                     # library (testable, no main)
  TaskCatalog.swift                   # parse manifest.json + task.toml; validate; TaskSpec
  ContainerRuntime.swift              # protocol; AppleContainerRuntime + DockerRuntime (fallback)
  ImageResolver.swift                 # pull-first / build-fallback; cache by ext_id
  Workspace.swift                     # template extract; copyfile(COPYFILE_CLONE) per run
  ContainerExecServer.swift           # WS exec-server bridge: fs→clone, process→container exec
  AgentDriver.swift                   # headless SessionEngine; capture diff/trajectory/usage/cost
  Verifier.swift                      # faithful test.sh (base/new/reward)
  QualityScorer.swift                 # diff metrics + lint/typecheck
  LLMJudge.swift                      # codex exec --output-schema verdict
  Scorer.swift                        # Pass@1, Wilson/Wald CI, aggregates
  Reporter.swift                      # md/json
  Scheduler.swift                     # concurrency, resume, timeouts
Sources/codex-bench/main.swift        # CLI (ArgumentParser)
Tests/BenchKitTests/                  # unit tests w/ fixtures + a MockContainerRuntime
Benchmarks/deep-swe/                  # VENDORED task data (9.4 MB; stripped of .git)
docs/benchmarks/DEEP_SWE_RUNNER.md    # this doc
docs/benchmarks/judge.schema.json     # LLM-judge output schema
scripts/run-deep-swe.sh               # convenience wrapper
```

- `BenchKit` deps: `HarnessCore`, `ModelClient`, `Persistence`, `Tools`,
  `ProtocolModel`, `WireProtocol`, `Sandbox`, `Config`, `Tokenizer`,
  `Supervisor`, `SessionWorkerCore`, `IPC`, `InfraPrimitives`, `Observability`.
- Add a **gated `BenchKitTests`** target that skips unless `CODEXKIT_BENCH=1` +
  container/Docker available + `OPENAI_API_KEY`, exactly like `LiveTests`, so
  `swift test` stays green without a runtime/daemon.
- `apple/container`-specific code is shelled out (CLI) ⇒ no macOS-26 SDK gating
  needed; the portable core still builds on Linux (Docker backend) for CI.

---

## 10. Performance & concurrency

- **APFS clonefile** templates ⇒ near-zero per-run workspace cost.
- **Image/template cache** keyed by `ext_id`; `codex-bench prepare` warms it.
- **Parallel containers**: Scheduler runs `--concurrency K` tasks at once at the
  per-task `cpus`/`memory_mb` from `task.toml` (2 CPU / 8 GiB) ⇒ size `K` to host
  headroom. Periodically recycle containers (apple/container doesn't return guest
  memory to the host).
- **Rosetta** amd64 is the perf floor; arm64 rebuild is the opt-in fast path.

---

## 11. Fidelity & comparability caveats (printed on every report)

1. **Scaffold differs.** deepswe uses mini-swe-agent (single bash tool, shared
   prompt, no model-specific edit primitives). We deliberately run **codex-swift's
   full tool surface** — our number measures *codex-swift + model*, theirs
   measures *mini-swe-agent + model*. This is the point of the exercise, but means
   the absolute Pass@1 for a *given model* is not apples-to-apples. (A future
   "lean mode" restricting to a single bash tool could be added for a closer
   comparison; out of scope for v1 per the chosen direction.)
2. **Single vs averaged rollouts** on their main leaderboard is undocumented; we
   default to `--attempts 1` and offer Pass@k.
3. **Timeouts/step-limits**: we use `task.toml` budgets; their mini-swe-agent step
   cap is undocumented.
4. **Arch divergence.** We run **native arm64**; the leaderboard's prebuilt images
   are amd64. For high-level language tests this is almost always irrelevant, but a
   rare arch-sensitive task (pointer width, float formatting, SIMD, platform-gated
   code) could differ. The base/new reruns + the judge help detect it; `--arch
   amd64` (Rosetta) is the per-task escape hatch.

---

## 12. Phased implementation plan

| Phase | Deliverable | Validates |
|---|---|---|
| **0. Spike** *(mostly done — see §13)* | `codex-bench doctor`; prove the grading pipeline end-to-end with **Docker** by applying `solve.sh` (reference) → reward 1 and empty → reward 0; confirm `apple/container` install + air-gap; confirm exec-server bridge shape. | All unknowns below |
| **1. Vendor + Catalog** | Vendor `Benchmarks/deep-swe`; `TaskCatalog` + `TaskSpec`; `codex-bench list`; schema validation; unit tests. | Data model |
| **2. Runtime** | `ContainerRuntime` (apple/container primary, Docker fallback) + `ImageResolver` + `Workspace` (clonefile); `codex-bench prepare`. | Containers + caching |
| **3. ExecBridge + Agent** | `ContainerExecServer` + `AgentDriver`; codex-swift solves one task in-container; capture diff/trajectory/usage. | codex-swift-in-container |
| **4. Verify** | `Verifier` (base/new/reward); end-to-end Pass@1 for one task. | **Headline metric** |
| **5. Score + report** | `Scorer` (Pass@1±CI, cost/time/tokens) + `Reporter`; `--random`, `--all`, filters, concurrency, resume. | Leaderboard columns |
| **6. Quality** | `QualityScorer` (diff + lint/typecheck). | Quality dimension |
| **7. Judge** | `LLMJudge` via `codex exec --output-schema`. | Judge dimension |
| **8. Harden** | severe-testing the runner (timeouts, flaky tests, crash recovery, disk pressure, concurrency); docs; `scripts/` + CI wiring. | Robustness |

Phases 0–4 yield a working, comparable Pass@1 on a single task + the 3-random
smoke run; 5 makes it a real suite; 6–7 add the extra dimensions.

---

## 13. Phase-0 spike results (2026-05-30)

| Check | Result |
|---|---|
| Host | macOS **26.4.1**, **arm64** ✓ (apple/container's supported platform) |
| `apple/container` | ✓ **installed & running 0.12.3**; `container run --arch arm64` → `aarch64` (no Rosetta); bind-mount host↔guest writeback ✓ (guest runs as root:0); `--network none` ✓ (air-gap) |
| Native arm64 image build | ✓ `container build --arch arm64` from the task Dockerfile in **40 s** (`mars-base` arm64 + native `npm ci`) |
| **Grading pipeline (native arm64)** | ✓ **PROVEN**: reference solution → base 81✓ + new 116✓ → **reward 1**; empty → new 80✗ → **reward 0**. Runtime-agnostic logic also cross-checked on Docker. |
| ECR (`public.ecr.aws`) | anonymous pull works but **rate-limits (429)**; cache `mars-base` once (backoff) → 113 builds reuse it |
| Docker | 29.4.0 present — cross-check + CI/Linux fallback backend |
| `codex` CLI | **0.134.0 present**; `codex exec` has `--json`, `--output-schema`, `--output-last-message`; `codex exec-server --listen ws://…` exists |
| APFS clonefile | ✓ 33 ms for 120 MB+300 files. ⚠️ use `/bin/cp -c` or `copyfile(COPYFILE_CLONE)` — GNU `cp` shadows BSD `cp` on PATH |
| codex-swift remote seam | ✓ `RemoteExecServerTools` is complete + wired via `SessionConfig.remoteEnvironment.execServerUrl` |
| Verifier setup gotcha | the verifier writes `/logs/verifier/reward.txt` but only auto-creates `/logs/artifacts/` → the runner **must pre-create `/logs/verifier/` and `/logs/artifacts/`** in the bind-mounted logs dir |
| deep-swe data | ✓ 9.4 MB, 113 tasks (ts35/go34/py34/js5/rust5); format confirmed |
| SwiftPM | ✓ clean target conventions; add `BenchKit` + `codex-bench` + gated `BenchKitTests` |

**Phase-0 is effectively complete.** The native-arm64 container + faithful verifier
+ reward pipeline are proven on the real runtime. The only piece not yet exercised
end-to-end is the **codex-swift agent driving inside the container** (the
`ContainerExecServer` bridge, §5A) — that is Phase 3 work.

---

## 15. Implementation status (2026-05-30) — BUILT & validated

The runner is implemented and validated end-to-end on this machine.

**Targets:** `Sources/BenchKit/` (lib), `Sources/codex-bench/` (CLI),
`Tests/BenchKitTests/`. Task data vendored at `Benchmarks/deep-swe/` (113 tasks).

**Key files:** `TaskCatalog`+`MiniTOML`+`TaskSpec` (catalog), `ContainerRuntime`
(apple/container CLI wrapper), `ImageResolver` (arm64 build + base cache +
template extract via bind-mounted `cp -a`), `Workspace` (APFS `copyfile(COPYFILE_CLONE)`),
`ContainerExecServer` (Network.framework WS server bridging codex-swift's
exec-server protocol → fs on host clone / process via `container exec`),
`CodexSwiftSession`/`CodexSwiftAgentDriver` (drives `SessionEngine` in-process,
remoteEnvironment → the bridge), `Verifier` (faithful `test.sh`), `QualityScorer`,
`LLMJudge` (`codex exec --output-schema`), `Scorer` (Pass@1 + Wilson/Wald),
`Reporter`, `Scheduler`/`BenchRunner`.

**CLI:** `codex-bench doctor | list | prepare | run | report`; modes
`agent|reference|empty`; selectors `--task/--random N/--all`; `--judge --quality
--concurrency --model --lang --category --seed`.

**Validated:** `run --mode reference` → reward 1; `--mode empty` → reward 0;
`--mode agent` (gpt-4o-mini) edits code via the bridge (`apply_patch`→host clone,
60 insertions across 2 files), environment stays intact (air-gap), verifier +
quality + judge all run, and the LLM judge **agreed with the verifier**
(`agrees_with_verifier=true`). A real Pass@1 needs a capable model (gpt-5.x) — the
smoke model demonstrates the machinery, not a passing solution.

**Implementation gotchas (resolved, captured for posterity):**
- `container cp` is an **uninstalled plugin** in 0.12.3 → extract `/app` via a
  bind-mounted one-shot `cp -a /app/. /out/` instead.
- The verifier writes `/logs/verifier/reward.txt` but only auto-creates
  `/logs/artifacts/` → pre-create both host-side.
- An air-gapped agent that runs `npm install`/`pip install` **wipes the
  pre-installed deps** (no network to reinstall) → the agent prompt states deps
  are pre-installed, network is off, and installers are forbidden.
- Default `autoCompactTokens=24_000` prematurely compacts → set model-aware
  (~0.85 × context window).
- The WS receive loop must stop on close/nil to avoid a CPU spin.
- Use `/bin/cp -c` or `copyfile(COPYFILE_CLONE)`, never PATH `cp` (GNU shadows BSD).

**Remaining / future:** lint/type-check in `QualityScorer` (currently diff-focus
only); `--attempts` Pass@k; resume polish; optional graduation from CLI shell-out
to the `Containerization` Swift API.

## 14. Open questions / risks

- `apple/container` no-egress flag (Phase-0 item 3); `container exec` exit-code +
  large-stdout streaming under load.
- ECR anonymous pull via `apple/container` from `public.ecr.aws` (scheme/auth) —
  else build-fallback is mandatory not optional.
- `ContainerExecServer` protocol-server effort (process seq-windows, fs methods) —
  bounded by the documented client contract.
- Judge cost on `--all` — default off; opt-in.
