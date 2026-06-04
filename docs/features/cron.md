# Cron & Scheduled Jobs

*Run a prompt on a schedule — "summarize yesterday's incidents at 8am," "every 5 minutes, check the queue" — as an **unattended, locked-down** agent turn whose result is pushed to you.*

## Why it matters

The difference between a tool you invoke and an assistant that works for you is *initiative*. You want the agent to do things while you sleep: a morning digest, a periodic health check, a nightly cleanup report. That means a turn that fires on a schedule with no human at the keyboard.

"No human at the keyboard" is exactly what makes it dangerous. A normal turn can pause and ask "this command needs approval — allow it?". An unattended turn has no one to answer, so a naive scheduler would either **hang forever** on the prompt or — worse — be configured to auto-approve and hand a cron job your shell. And the prompt itself, or anything it reads, could try to escalate. Cron exists to make scheduled turns *safe by construction*.

## What it is

A daemon-resident scheduler that fires saved jobs and delivers their output through [push](push.md):

- **A job** is `{ schedule, prompt, deliverTo?, skipMemory }`. Schedules are one-shot (`at` an epoch second), interval (`every` N seconds), or a cron expression.
- **The turn is locked down.** A cron turn runs under `approvalPolicy = .never` (a tool that *would* need approval is denied inline — never an unanswerable prompt), `sandboxMode = .readOnly`, and no network. By default `skipMemory = true`, so an unattended run never silently rewrites your user model.
- **Delivery** funnels the result to an optional `deliverTo` push target through the same `EgressGuard`-screened, durable `PushRouter`.
- **An owner-only control surface** — `cron/list`, `cron/add`, `cron/remove` over the daemon's owner-trusted transport — manages jobs at runtime.

## How it works

**Scheduling (`CronScheduler`).** Jobs persist to `$CODEX_HOME/cron_jobs.json`. A self-driving tick loop calls `tick(now:)` periodically. A job is *due* when its next fire time has passed; a fire missed within a **grace window** (`grace_seconds`, default 1h) is caught up once, while an older missed fire is **fast-forwarded** (skipped, not replayed) — so a daemon that was down for a week doesn't replay a week of stale ticks. One-shot `at` jobs disable themselves after firing.

**The unattended-turn config (the load-bearing security decision).** When a job fires, `CronGlue.makeCronRunner` builds a `SessionConfig` with `.never` / `.readOnly` / no-network and runs it via `SessionSupervisor.collectTurn`. Because `collectTurn` wires a no-op approval handler, `.never` is what keeps the turn from hanging: an approval-required tool is *denied inline* and the turn proceeds. `skipMemory = true` maps to an `ephemeral` thread so the engine skips memory consolidation entirely. This config travels *with* the turn to the worker process, so the lockdown holds in both in-process and spawned worker modes — there is no in-process gate that a separate worker could miss.

**Delivery + SSRF.** The runner pushes `deliverTo` through `PushRouterHolder.shared` — the same durable, screened router the owner push path uses — so a cron `deliverTo: "webhook:https://…"` is SSRF-contained at the one chokepoint and never opens its own HTTP.

**Migration from automations.** codex-swift already had a lighter "automations" scheduler. When `[features].cron` is on, cron becomes the *single* source of truth: legacy `automations.json` is migrated **once** into `cron_jobs.json` (manual/no-schedule automations are skipped; `hourly`/`daily`/`weekly`/numeric map to `every`), the original is backed up to `.bak`, and the old automation scheduler is **not** started — so the same job never fires twice.

## Using it

**Enable it.** Deny-default. Turn it on with `[features].cron = true` (or `CODEX_FEATURE_CRON=1`):

```toml
[features]
cron = true

[cron]
grace_seconds = 3600   # optional; catch-up window for a missed fire
```

**Manage jobs over the owner-only RPC** (`cron/add`, `cron/list`, `cron/remove`). A `cron/add` request takes a stable schedule shape and an optional push target:

```jsonc
// cron/add
{ "id": "morning-digest",
  "schedule": { "kind": "every", "every": 86400 },   // or {"kind":"at","at":<epoch>} / {"kind":"cron","cron":"0 8 * * *"}
  "prompt": "Summarize yesterday's commits and open PRs.",
  "deliverTo": "ntfy:my-digest",
  "skipMemory": true }
```

The schedule is sent and returned as `{kind, at?, every?, cron?}` — a stable wire shape, not the fragile synthesized enum form. `cron/*` is reachable only over the owner-local transport; the browser tier is refused.

**What you see:** at 8am the daemon fires the prompt as a read-only, approval-`never` turn; its answer is pushed to `ntfy:my-digest`. If the prompt (or a prompt-injection in what it reads) tries to run a shell command or write a file, that action is denied inline — the job can't escalate.

## What it enables

- **A proactive assistant.** Digests, health checks, reminders, periodic cleanups — work that happens without you asking.
- **Safe unattended autonomy.** The `.never` / `.readOnly` / no-network lockdown means a scheduled prompt is a *read-and-report* primitive, not a standing shell. Escalation-requiring work still needs an interactive, owner-present turn.
- **One delivery + egress path.** Cron results ride the same durable, SSRF-screened `PushRouter` as everything else.

## Status

**Built, tested, and wired.** The `Cron` module (`Schedule`, `CronJob`, `FileCronStore`, `CronScheduler` with the tick loop + grace-window semantics), the owner-gated `cron/*` RPC family, the `CronGlue` runner + `automations.json → cron_jobs.json` migration, and the codexd wiring (single-source-of-truth, stopped on SIGTERM/SIGINT) are all live. Severe tests cover the tick loop, persist-on-change, the unattended-turn security config (`.never`/`.readOnly`/no-network/ephemeral), owner-gate refusal on the web tier, schedule/bounds/deliverTo validation, the wire round-trip (no synthesized `_0` key), tick-time actor reentrancy (a concurrent `cron/remove` during a fire is respected), and the migration (lossy-but-correct, idempotent, corrupt-input-resilient).

## Go deeper

Source: `Sources/Cron/` (scheduler + store + holder), `Sources/Supervisor/CronGlue.swift` (runner + migration + the `cronSessionConfig` security helper). Design: [ADDONS.md](../../ADDONS.md) section "6. Cron / scheduler". The unattended-turn lockdown shares its rationale with the [channels](channels.md) non-owner gate; both are explained in [security.md](../guides/security.md).
