# Benchmarks (DeepSWE Runner)

*A native macOS harness that scores codex-swift against the DeepSWE benchmark — real repos, real fixes, a single Pass@1 number, no Docker required.*

## Why it matters

You changed a prompt, swapped a model, or hardened a tool. Did the agent get *better*, or did you just move the needle on three tasks you happened to eyeball? Vibes don't answer that. The only honest way to know whether codex-swift solves real software-engineering problems is to point it at a fixed suite of real bugs and feature requests, let it work air-gapped with no peeking at the answer, and run the project's own hidden tests against whatever it produced.

That is exactly what the DeepSWE runner does. It takes 113 tasks drawn from real open-source repositories (TypeScript, Go, Python, JavaScript, Rust), hands each one to codex-swift with its full native tool surface, and grades the result with the task's *own* test suite — pass or fail, no partial credit. The output is a **Pass@1** percentage with a confidence interval, plus average cost, wall-time, and token counts: the same columns the public [deepswe.datacurve.ai](https://deepswe.datacurve.ai/) leaderboard reports. Now "is this version better?" has a number.

## What it is

`codex-bench` is a command-line tool (and a `BenchKit` library behind it) that runs the DeepSWE task suite **on your Mac**, using codex-swift itself as the solving agent.

For each task it:

- spins up an **isolated, network-disabled Linux VM** via [`apple/container`](https://github.com/apple/container) — Apple's native container runtime, no Docker daemon needed at run time;
- drops a fresh clone of the repo (at a specific base commit) into the VM;
- lets codex-swift read, search, edit, and run tests inside that VM until it thinks the task is solved;
- throws away the agent's container, brings up a clean one, applies the task's **hidden test patch**, and runs the grading script.

A task scores **reward 1 only if the existing regression tests still pass AND the new behavior tests pass** — otherwise 0. That binary reward, averaged over the tasks you ran, is your Pass@1.

It also computes two *separate, never-folded-in* dimensions: a **code-quality** score (how focused the diff is vs. the held-out reference fix) and an **independent LLM judge** verdict (via the local `codex` CLI) that audits whether the deterministic verifier got it right.

## How it works

The orchestrator runs on the host. The task runs in a VM. The model calls go out over your network from the host; the file edits and test runs happen inside the air-gapped VM. The pipeline per task:

```
 resolve image ─► clone workspace ─► WORK container ─► agent solves ─► tear down
 (build arm64    (APFS clonefile,    (mount /app only,  (codex-swift     (kills any
  from Dockerfile, ~instant even      network OFF)       edits the clone)  hung procs)
  cache by ext_id) for node_modules)                                          │
                                                                              ▼
                              reward ◄─ run test.sh ◄─ apply hidden ◄─ fresh VERIFY
                              (1 iff     (base + new    test.patch       container
                               base==0    suites)                       (mount /tests)
                               && new==0)
```

Key concepts to hold in your head:

- **Faithful grading.** `Verifier` runs the task's *own* `tests/test.sh` inside the container. That script captures the agent's diff to `model.patch`, resets any file the hidden tests touch (so the agent can't pre-satisfy or clobber them), applies `test.patch`, runs the baseline suite (`base`) and the new-behavior suite (`new`), and writes `reward.txt`. The runner only adds the plumbing Pier did implicitly: pre-creating `/logs/verifier` and `/logs/artifacts`, and clearing a stale `.git/index.lock` the agent might leave.
- **Air-gap = anti-cheat.** The agent's container runs `--network none`. The `solution/` directory is *never* mounted into the agent's VM (the held-out reference is host-side only, for quality + judge). Because dependencies are pre-baked into the image, the agent is told not to run installers — there's no network to reinstall from.
- **Two containers per task.** The agent's WORK container sees only `/app`. After it finishes, that container is destroyed (killing any deadlocked `go test` it left behind) and a *fresh* VERIFY container grades the edits — which survive because they live on the host-side workspace clone.
- **The exec bridge.** codex-swift's edits and shell commands run inside the container without any core changes, via `SessionConfig.remoteEnvironment` pointed at a local WebSocket exec-server (`ContainerExecServer`) that maps file ops to the host clone and process ops to `container exec -w /app`.
- **Scoring.** `Scorer` computes Pass@1 as the mean binary reward (timeouts/errors count as 0, matching SWE-bench semantics) with a **95% Wilson interval** and a **Wald ±** for direct leaderboard comparison.

## Using it

The CLI lives at `Sources/codex-bench/main.swift`; the library is `Sources/BenchKit/`. Task data is vendored at `Benchmarks/deep-swe/` (113 task directories under `tasks/`).

Build it: `swift build --product codex-bench`.

**First, check your machine is ready:**

```
codex-bench doctor
```

This prints a checklist: macOS version + arch, whether `apple/container` is running, the `codex` CLI (used by the judge), the task catalog count, whether `OPENAI_API_KEY` is set, and the cache root. Apple silicon + macOS 26 is the supported platform.

**Confirm the harness itself is sound** (no model, no cost) using the two self-test modes:

```
codex-bench run --task <id> --mode reference   # applies the reference fix → expect reward 1
codex-bench run --task <id> --mode empty        # changes nothing         → expect reward 0
```

**Run codex-swift on a smoke sample**, then the full suite:

```
codex-bench run --random 3 --seed 42            # cheap "does it all work" run (seed recorded)
codex-bench run --all --model gpt-5.5 --concurrency 4 --judge --quality
```

Selectors and key flags (parsed by the minimal `--key value` / `--flag` option parser):

- `--task <id>` | `--random N [--seed S]` | `--all` — what to run.
- `--lang go,python` and `--category bugfix` — filter the pool.
- `--mode agent|reference|empty` — default `agent`.
- `--model M` — default `gpt-5.5` (or `CODEXKIT_BENCH_MODEL` / `CODEXKIT_LIVE_MODEL`). `--effort high` by default.
- `--concurrency K` — parallel tasks (default 2; size to host RAM, each task gets ≥4 CPU / ≥2 GiB).
- `--attempts N` — N rollouts per task → variance-averaged Pass@1 plus Pass@k.
- `--judge` / `--quality` — opt-in extra dimensions.
- Env: `CODEX_BENCH_AGENT_TIMEOUT` (cap the agent turn for smoke runs), `CODEX_BENCH_JUDGE_MODEL`, `CODEX_BENCH_TASKS` (override task root).

Other subcommands: `codex-bench list [--lang …]` (catalog), `prepare` (warm the image + APFS-clone template cache by `ext_id`), `report <run-id>` (re-render a finished run), `analyze [<run-id>]` (harness-health forensics on the latest run).

**What you see.** On completion the run prints, e.g.:

```
Pass@1: 58.4% (66/113)  CI95 49.2%–67.1%  ±9.1%
report: ~/…/results/<run-id>/report.md
```

Results land in `results/<run-id>/`: `run.json` (config, seed, codex-swift git SHA, runtime + arch), per-task folders (`workspace`, `logs`, `model.patch`, verifier output, `result.json`, and an agent `transcript.md`), and a top-level `report.md` / `report.json`. The Markdown report opens with a **comparability caveat banner**, then a table with **Pass@1 (Wilson CI / Wald ±), avg cost, avg time, avg output tokens**, a per-language breakdown, and a per-task row (reward, base/new exit codes, diff size, cost, time).

## What it enables

- **A regression gate for the agent.** Run `--random N` (or `--all` overnight) before and after a change to the prompt, tools, or model and compare Pass@1 with its CI — the report tells you when a difference is real vs. noise ("ignore <5% differences").
- **A leaderboard-shaped row.** The report reproduces the deepswe columns so a codex-swift result drops in next to the public models, with an honest caveat about the scaffold difference.
- **Composability.** It drives the same `SessionEngine` your product uses, through the existing `remoteEnvironment` exec-server seam (the [ContainerExecServer bridge](./tools.md) — *link if present*), so you're benchmarking the *real* harness, not a stub. Costs are priced through the shared `ModelCatalog` / pricing tables.

## Status

Built and validated end-to-end on this machine: `reference` mode reaches reward 1, `empty` reaches 0, and `agent` mode edits code in-container with the air-gap intact, verifier + quality + judge all running. Caveats to keep in mind:

- **Not apples-to-apples with the leaderboard.** This runs codex-swift's full tool surface on native arm64; the leaderboard uses the single-bash mini-swe-agent on amd64. The number measures *codex-swift + model*, by design — every report says so.
- A real Pass@1 needs a capable model (gpt-5.x). The smoke validation used gpt-4o-mini to exercise the machinery, not to pass tasks.
- `QualityScorer` currently scores **diff focus only**; lint/type-check integration is planned. `--attempts` Pass@k, resume polish, and graduating from the `container` CLI to the `Containerization` Swift API are future work.

## Go deeper

Full design, research findings, fidelity caveats, and phased plan: [docs/benchmarks/DEEP_SWE_RUNNER.md](../benchmarks/DEEP_SWE_RUNNER.md).
