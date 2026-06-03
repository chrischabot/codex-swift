# Security, Sandboxing & Approvals

*How the agent runs real shell commands, edits real files, and reaches the network without becoming a foothold on your machine.*

## Why it matters

You are about to hand a language model a shell on your laptop. It will run `git`, edit source files, install packages, and occasionally do something you did not expect — because the model misread the task, or because a hostile string in a file it `cat`ed told it to. The blast radius of "an AI with a terminal" is your home directory, your SSH keys, your cloud credentials, and any internal service your machine can reach.

codex-swift's answer is layered confinement plus human-in-the-loop consent: a misbehaving — or hostile — tool action cannot read secrets outside the working directory, cannot write into your home, cannot open a network socket you did not approve, and cannot quietly escalate its own privileges. The defaults are conservative; the dangerous knobs exist but are explicit opt-ins.

## What it is

Five cooperating mechanisms, each independent so that any one failing does not undo the others:

- **A kernel sandbox** wraps every spawned command (macOS Seatbelt via `sandbox-exec`; Linux via `bwrap`). The kernel itself denies anything not explicitly allowed.
- **A writable-roots policy** bounds where files can be written — by default, just the directory you launched the session in.
- **A network policy** that defaults to *no outbound network at all* for sandboxed commands.
- **An approval ladder** (`never` → `onFailure` → `onRequest` → `unlessTrusted` → `granular`) that decides when you get prompted before an action runs unsandboxed.
- **Identity gating for channels** (Telegram/Discord-style inbound) so a non-owner messaging the bot cannot drive destructive tools, plus an **egress chokepoint** primitive that screens model-driven outbound HTTP for SSRF.

What this means for you day-to-day: by default the agent can freely read your files and edit/run things inside your project, but writing outside it, going to the network, or doing something the policy classifies as risky will either fail safely or stop and ask you first.

## How it works

### The three enforcement layers for a command

```
  model wants to run `argv`
        │
        ▼
  ┌──────────────┐   classify argv → safe / needsApproval / forbidden
  │  ExecPolicy  │   (from $CODEX_HOME/rules/*.rules; invalid files fail CLOSED)
  └──────┬───────┘
         ▼
  ┌──────────────────────┐  decideCommand(policy, safety, modelRequestedEscalation)
  │ ApprovalPolicyEngine │  → proceed sandboxed | ask-then-escalate | reject
  └──────┬───────────────┘
         ▼  (if it runs)
  ┌──────────────────────┐  sandbox-exec / bwrap wraps the exec:
  │   Kernel sandbox     │  deny-by-default; writes only under writable roots;
  └──────────────────────┘  no network unless allowed. Backstop if the rest err.
```

The kernel layer is the backstop; `ExecPolicy` and the approval engine decide *before* the child is even spawned.

### Sandbox modes

The mode is a per-session choice (`SessionConfig.sandboxMode`, default `workspaceWrite`):

| Mode | Wire string | Filesystem writes | Network |
|------|-------------|-------------------|---------|
| `readOnly` | `read-only` | denied | denied |
| `workspaceWrite` | `workspace-write` | allowed under writable roots + cwd | denied by default; rules can allow |
| `dangerFullAccess` | `danger-full-access` | unconstrained | allowed |

`dangerFullAccess` short-circuits *both* the kernel sandbox and the workspace policy — it effectively turns the sandbox off and should only be chosen by an operator who knows that.

### The macOS Seatbelt profile

Every sandboxed exec on macOS is launched as `sandbox-exec -p <profile> <argv>`, with the profile regenerated per launch. Its spine is:

```
(version 1) (deny default)
(allow process-fork) (allow process-exec)
(allow file-read*)
```

Reads are allowed filesystem-wide; writes are added with one `(allow file-write* (subpath …))` clause per writable root plus the cwd; `(allow network*)` is emitted *only* when network is allowed. Several hardening details matter:

- **Symlink canonicalization** (`realpath(3)`) runs before any path lands in the profile, so a tool cannot escape the writable root by writing through a symlink that points outside it.
- **Protected metadata carve-out**: even inside a writable root, `.git`, `.codex`, and `.agents` stay unwritable — otherwise a sandboxed process could drop a `.git/hooks/pre-commit` shim and escalate on the next commit, or rewrite `.codex/config.toml` to disable the sandbox next time.
- **SBPL string/regex escaping** neutralizes hostile paths (control bytes, embedded quotes) so a quirky filename cannot inject raw SBPL into the profile.

On Linux the equivalent is `bwrap` with `--ro-bind / /`, per-root `--bind`, read-only tmpfs over the protected dirs, and `--unshare-net` when network is off. On macOS, if `sandbox-exec` is missing the resolver refuses to run unsandboxed rather than silently dropping confinement.

### The approval ladder

The pure decision engine is `ApprovalPolicyEngine` (`Sources/HarnessCore/Approvals.swift`). It takes your `ApprovalPolicy`, the command's safety classification, and whether the model asked to escalate, and returns one of: run sandboxed, run escalated (unsandboxed), ask-then-escalate, ask-then-proceed (the patch path), or hard-reject.

| Policy | What prompts |
|--------|--------------|
| `never` | Nothing ever prompts; commands run only in the sandbox. If an action would need to escape, it simply fails. |
| `onFailure` | Run sandboxed; only ask to re-run unsandboxed *after* the sandbox blocks it. |
| `onRequest` *(default)* | Ask when the model requests escalation, when the command isn't classified safe, or when a patch targets outside the writable roots. |
| `unlessTrusted` (wire: `untrusted`) | Prompt for almost everything except a small safe-read allowlist. |
| `granular` | Per-category gating (see below). |

Worth internalizing: only `apply_patch` inside the writable roots and `safe`-classified commands run without a prompt under `onRequest`. A patch *outside* the roots prompts; under `never` it is hard-rejected, never silently allowed.

`granular` carries five booleans — `sandbox_approval`, `rules`, `skill_approval`, `request_permissions`, `mcp_elicitations`. Each `false` value auto-rejects that category of prompt instead of surfacing it. Only `sandbox_approval` actually branches the command/patch decision; the other four shape what the model is told it may ask for. When `sandbox_approval` is on, granular behaves like `onRequest`; when off, command escalations are suppressed (run sandboxed, let it fail) and out-of-root patches are rejected rather than prompted.

### Destructive / host-control tools

`apply_patch` (file writes) follows the patch decision table above. The `computer_use` tool — which drives the real mouse, keyboard, and screen — is its own category: there is no sandbox to escalate out of, so the decision is binary, prompt-then-run or run. It prompts under every cautious policy (`unlessTrusted`, `onRequest`, and `granular`) and runs without a prompt only under `never` and `onFailure`. Notably, granular *always* prompts for host control, because mapping it to `sandbox_approval` would invert the safety meaning.

### Durable approvals

When you choose "always allow", the prefix key is the first two argv tokens (so approving `git status` does not approve `git push`). It is written to two stores — the legacy `approved_commands.json` and the canonical `$CODEX_HOME/rules/default.rules` (the same file the Rust codex CLI reads). Writes go through `flock(LOCK_EX)` so codexd, the Rust CLI, and tests serialize cleanly without losing a concurrent append.

### Channel owner-gating

For inbound chat channels, the sender's identity is **server-stamped** from the authenticated transport id (`ChannelIdentity.normalize`), never read from the message text — the text is untrusted. The `senderIsOwner` bit then powers a *hard* dispatch-time gate (`registerChannelApprovalGate`): a non-owner's attempt to run shell, `apply_patch`, escalate permissions, or invoke a dynamic/MCP tool is denied outright, regardless of approval policy. The gate matches on the server-stamped `method=` line, fails closed on timeout, and is byte-neutral for owners. Use `installChannelGate(into:)` to wire both the advisory developer fragment and the enforcing gate against one box — wiring only the fragment yields an *inert* gate.

### Egress chokepoint (SSRF defense)

`EgressGuard` (`Sources/EgressGuard/EgressGuard.swift`) is the screen for model-driven outbound HTTP (push notifications, cron webhooks, media fetches). It enforces HTTPS-only, an optional exact-host allowlist, rejection of URL credentials and `*.internal` names, and — critically — it blocks by **resolved IP**: loopback, RFC1918, link-local (including cloud metadata `169.254.169.254`), CGNAT, ULA, and IPv4-embedded-in-v6 forms are all denied, with strict dotted-decimal parsing so an octal/hex host like `0x7f.1` can't sneak past. To defeat DNS rebinding it is *connect-bound*: `vet(_:)` returns the vetted IPs the caller must pin, and `EgressApproval.allows(peerIP:)` re-checks the actually-connected peer. Redirect-following must be disabled by the caller and each hop re-vetted.

## Using it

**Pick a sandbox mode and approval policy** in config (`$CODEX_HOME/config.toml`), or per session over the wire:

```toml
sandbox_mode    = "workspace-write"   # default; or "read-only" / "danger-full-access"
approval_policy = "on-request"        # default; or "never" / "on-failure" / "untrusted"
```

Aliases like `sandboxMode` / `approvalPolicy` and `unless-trusted` are accepted on decode for back-compat. Defaults are intentionally *not* baked into `defaults()` — they resolve at runtime to model `gpt-5.5`, sandbox `workspace-write`, approval `on-request`.

**Grant durable command approvals** by editing `$CODEX_HOME/rules/default.rules` (or accepting "always allow" at a prompt):

```text
prefix_rule(pattern=["git", ["status","diff"]], decision="allow")   # no prompt
prefix_rule(pattern=["rm", "-rf"], decision="prompt")               # always ask
network_rule(host="api.github.com", protocol="https", decision="allow",
             justification="GitHub API")
```

A pattern token is an exact string or an array of alternatives; the first token is the command basename. `decision` is `allow` / `prompt` / `forbidden` (network rules also accept `deny`). A typo here **fails closed** — every command becomes `forbidden` rather than silently widening the allowlist.

**Allow specific network hosts** with `network_rule(...)`. These are operator-controlled and sourced from disk, so the model cannot widen them per-turn.

**What you'll see:** under the default `on-request`, a `safe` read command and an in-project edit run silently; an out-of-project write, a non-safe command, or a model escalation request pops an approval prompt where you can allow once or always.

## What it enables

With confinement and consent in place, the riskier capabilities become safe to offer: the agent can run real builds and tests, drive [Computer Use](../features/computer-use.md) on the desktop, accept inbound messages over channels, and fire push/webhook notifications — each behind a layer that fails closed. The writable-roots model is what lets parallel read-only review panels run while the main loop edits. The egress guard is the dependency the push/cron/media features should screen through before any agent-chosen URL is fetched.

## Status

The kernel sandbox, writable-roots policy, network rules, approval ladder, and channel owner-gating are fully wired and live-tested (including a live test that attempts a TCP connect inside a sandboxed exec and asserts it fails). `EgressGuard` is a complete, tested primitive but is **not yet consumed** by the push/cron/media call sites — it currently has no importers outside its own test target, so today it is a verified building block awaiting wiring at those egress points. `granular`'s `rules` / `skill_approval` / `request_permissions` / `mcp_elicitations` axes shape prompt assembly but do not branch the command/patch runtime decision (only `sandbox_approval` does).

## Go deeper

Internals and exact SBPL/bwrap profiles, the `ExecPolicy` classifier, process-group containment, and resource governance: `docs/SANDBOX.md`.
