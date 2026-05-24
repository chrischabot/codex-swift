# Sandbox

The sandbox subsystem isolates tool-spawned child processes from the rest of
the host so that a misbehaving model action — or a hostile one — cannot read
secrets outside the working directory, write into the user's home, or open
network sockets that the operator did not approve. It is layered, with three
independent enforcement points:

1. **Kernel-enforced confinement.** A platform-specific kernel sandbox wraps
   every exec: macOS Seatbelt (`sandbox-exec`) emits an SBPL profile per
   launch; Linux uses `bwrap` (`bubblewrap`) to assemble a private
   filesystem/PID/network namespace.
2. **Workspace policy engine.** `Sources/Sandbox/Sandbox.swift` evaluates
   filesystem writes and network egress against the configured policy in pure
   Swift. Tools that don't (or can't) fork still consult the policy through
   `WorkspaceSandbox.evaluateWrite` / `evaluateNetwork`.
3. **`ExecPolicy` rules.** `Sources/Tools/ExecPolicy.swift` classifies a
   command argv into `safe` / `needsApproval` / `forbidden` based on
   `$CODEX_HOME/rules/*.rules` files. Decisions feed into the approval engine
   so the user can grant durable approval that survives across processes.

Each layer is independent. Kernel confinement is the backstop; the workspace
policy and `ExecPolicy` decide before the child is even spawned. A tool that
clears all three is launched; failing any one is denied or escalated for
approval.

## Sandbox modes

The sandbox mode is a per-session choice carried on `SessionConfig.sandboxMode`
(`ProtocolModel.SandboxModeKind`). Three values:

| Mode                 | Wire string             | Filesystem writes                  | Network                                   |
|----------------------|-------------------------|------------------------------------|-------------------------------------------|
| `readOnly`           | `"read-only"`           | denied                             | denied (unless policy says otherwise)     |
| `workspaceWrite`     | `"workspace-write"`     | allowed under `writableRoots`+`cwd`| denied by default; ExecPolicy can allow   |
| `dangerFullAccess`   | `"danger-full-access"`  | unconstrained                      | allowed                                   |

The default is `workspaceWrite` (set in `Config.defaults()` and surfaced via
`config/read`). `dangerFullAccess` short-circuits both the kernel sandbox and
the workspace policy — it should only be selected by an operator who
understands they have effectively turned the sandbox off.

### Mapping `SessionConfig` to a runtime policy

`Sources/HarnessCore/SandboxBuilder.swift` (the `SessionSandboxBuilder` enum)
is the single place where the protocol-level kebab-cased `SandboxModeKind`
becomes a runtime `Sandbox.SandboxPolicy.Mode`. Both the spawned worker, the
in-process worker, and test factories all go through this helper so the
client's `thread/start` / `turn/start` selection is honored uniformly:

```swift
public enum SessionSandboxBuilder {
    public static func make(config: SessionConfig,
                            execPolicy: ExecPolicy) -> WorkspaceSandbox {
        let networkDomains = execPolicy.compiledNetworkDomains()
        let mode = mapMode(config.sandboxMode)
        let roots = config.writableRoots.isEmpty ? [config.cwd] : config.writableRoots
        return WorkspaceSandbox(RuntimeSandboxPolicy(
            mode: mode,
            writableRoots: roots,
            networkAllowed: config.networkAccess || mode == .dangerFullAccess,
            networkAllowedDomains: networkDomains.allowed,
            networkDeniedDomains: networkDomains.denied))
    }

    public static func mapMode(_ kind: SandboxModeKind) -> RuntimeSandboxPolicy.Mode {
        switch kind {
        case .readOnly: return .readOnly
        case .workspaceWrite: return .workspaceWrite
        case .dangerFullAccess: return .dangerFullAccess
        }
    }
}
```

A few subtleties to note:

- `writableRoots` defaults to `[config.cwd]` when the session passes no
  explicit roots. This keeps the workspace bounded to the directory the user
  launched the session in.
- `networkAccess || mode == .dangerFullAccess`: full-access mode always allows
  network even when the session's `networkAccess` flag is false.
- Domain allow/deny lists come from `ExecPolicy.compiledNetworkDomains()` — i.e.
  they are sourced from the on-disk `.rules` files, not from the session
  config. This is intentional: domains are an operator-controlled policy that
  the model cannot override per-turn.

The disambiguation alias `RuntimeSandboxPolicy` exists because both the
`Sandbox` runtime module and `ProtocolModel` define a type named
`SandboxPolicy`; importers of both modules use `RuntimeSandboxPolicy` to refer
unambiguously to the runtime struct.

## Seatbelt profile (macOS)

On macOS, every sandboxed exec is wrapped with `/usr/bin/sandbox-exec -p
<profile> <argv>`. The profile is regenerated per-launch by
`WorkspaceSandbox.buildSeatbeltProfile(policy:cwd:)`. Source-of-truth file:
`Sources/Sandbox/Sandbox.swift`.

The base profile is:

```scheme
(version 1)
(deny default)
(allow process-fork)
(allow process-exec)
(allow file-read*)
```

The deny-default stance means anything not explicitly allowed — including
network sockets, IPC, signals to non-self processes — is denied by the kernel.
File reads are allowed across the entire filesystem; writes are added with a
single `(allow file-write* (subpath "..."))` clause per `writableRoot` and a
second clause for the cwd. Network access is added with `(allow network*)`
only when the policy's `networkAllowed` is true.

### SBPL string and regex escaping

Hostile or quirky filesystem paths can break the SBPL parser if they contain
control characters or double-quotes. `Sources/Sandbox/Sandbox.swift` defines
two escapers used everywhere a runtime string lands inside an SBPL literal:

- `sbplStringLiteral(_:)` — wraps the input in `"..."`, replaces `\` with
  `\\`, replaces `"` with a hex escape `\x22` (because SBPL plain-string
  literals do not honor `\"` as an escape — a bare `"` after `\` closes the
  literal and the remainder becomes raw SBPL, which is both a parse error and
  an injection vector), and emits `\xNN` for any control byte.
- `sbplRegexLiteral(_:)` — produces the payload for use inside `(regex
  #"..."#)` deny clauses. The `#"..."` form is a *raw* literal: backslashes
  pass through to the regex engine untouched. Quotes inside the literal are
  emitted as the regex engine's own `\x22` byte-escape so the SBPL lexer
  never sees a bare `"`.

The corresponding `canonicalPath(_:)` helper resolves symlinks via
`realpath(3)` (falling back to `URL.resolvingSymlinksInPath()`) before any
path lands in a profile. This is what guarantees that a tool cannot bypass
the writable-root check by writing to a symlink that points into the
workspace from outside.

### Protected metadata directories

Even inside a writable root, the top-level `.git`, `.codex`, and `.agents`
directories must remain unwritable. Without this carve-out a `workspaceWrite`
sandbox could install a `.git/hooks/pre-commit` shim and escalate the next
time the user (or another sandboxed process) runs `git commit`, or rewrite
`.codex/config.toml` to disable the sandbox for future invocations. The
escalation is documented as parity item H-23.

`Sources/Sandbox/Sandbox.swift` defines the basenames and the regex helper:

```swift
static let protectedMetadataNames: [String] = [".git", ".agents", ".codex"]

static func protectedMetadataRegex(root: String, name: String) -> String {
    // Emits `^<escaped-root>/<escaped-name>(/.*)?$`
}
```

For each writable root the profile emits one `(deny file-write* (regex
#"..."))` per protected name. SBPL's deny-wins-on-conflict semantics make the
effective policy identical to upstream's `(require-not (regex …))` form
attached to each writable allow clause.

### Writable-root deduplication

`buildSeatbeltProfile` canonicalises every writable root via `realpath(3)`
and deduplicates the set before emitting allow clauses. The cwd is added
last and is itself canonicalised. The deny clauses for protected metadata
are emitted per deduplicated root.

## Network policy

Sandboxed processes have **no** outbound network access by default. The
kernel sandbox emits `(allow network*)` only when the runtime policy's
`networkAllowed` is true; bwrap launches the child in a fresh net namespace
via `--unshare-net` unless `networkAllowed` is true.

When the session is `workspaceWrite` and a tool needs an explicit per-host
allowlist, the operator writes `network_rule(...)` entries in
`$CODEX_HOME/rules/default.rules`. These are compiled by `ExecPolicy` into
`(allowed, denied)` host lists at startup. `WorkspaceSandbox.evaluateNetwork`
is the single decision point — it consults `evaluateNetworkDomainRule` first
(returning explicit allow/deny per matching rule) and only then falls back to
the global `networkAllowed` flag.

### Hostname normalisation

`WorkspaceSandbox.normalizedNetworkHost(_:)` lower-cases, strips a trailing
dot, unwraps bracketed IPv6 literals (`[::1]` → `::1`), and strips a `:port`
suffix when the left side contains a dot and the right side is all digits.
This mirrors the normalisation used in `RulesStore.normalizeNetworkHost` and
upstream's `normalize_network_rule_host` so the two stores see the same host
identity.

The match function `networkHost(_:matches:)` supports `*.example.com`
patterns — the leading `*.` matches the empty string (so `*.example.com` also
matches `example.com`) plus any single-segment-or-more left-extension.

### Web-search provider gating

The `web_search` tool family (`Sources/Tools/WebSearch.swift`) is the one
provider-mediated network path that does *not* go through the sandbox's
allowlist. It calls a remote search provider (OpenAI's `web_search` tool, or
Perplexity's `sonar-reasoning-pro` model) via the model client, which is
itself sandbox-aware. Provider model identifiers come from
`CODEXKIT_PERPLEXITY_MODEL`, `CODEXKIT_WEBSEARCH_MODEL`, and
`CODEXKIT_OPENAI_WEBSEARCH_TYPE` env vars.

### Live regression coverage

The network-deny path is exercised by live tests that actually attempt a TCP
connect inside a sandboxed exec and assert it fails. The intent is to catch
configuration drift where the kernel sandbox would silently allow network on
some OS update.

## Linux bwrap

On Linux, sandboxed launches go through `/usr/bin/bwrap` (or
`/usr/local/bin/bwrap`). `Sources/Sandbox/Sandbox.swift`'s
`buildBwrapArgv(bwrap:policy:argv:cwd:)` assembles the argv:

```
bwrap --die-with-parent --unshare-pid
      --ro-bind / /
      --dev /dev --proc /proc
      [--tmpfs /tmp]                            (workspace-write only)
      [--bind <root> <root> …]                  (one per writable root + cwd)
      [--perms 555 --tmpfs <root>/<name> --remount-ro <root>/<name>]
                                                (one per protected metadata path)
      [--unshare-net]                           (when networkAllowed=false)
      --chdir <cwd> -- <argv...>
```

A few important properties:

- **Read-only mode has no `--tmpfs /tmp`.** Previously `--tmpfs /tmp` was
  emitted unconditionally, which provided a writable mount even when the
  policy was `readOnly` — a sandbox-escape path. In read-only mode `/tmp` is
  covered by the read-only `--ro-bind / /` mount instead.
- **Protected metadata is layered as a read-only tmpfs.** For each writable
  root the loop emits `--perms 555 --tmpfs <path> --remount-ro <path>` for
  each of `.git`, `.codex`, `.agents`. Without the `--perms 555
  --remount-ro` flags the tmpfs defaults to mode 0755 and allows intra-session
  hook injection (e.g. writing `<cwd>/.git/hooks/pre-commit` and triggering
  it later in the same session).

The macOS-completion markers in `SandboxBackendResolver.resolve()` make the
intent explicit: on macOS, when `sandbox-exec` is not present, the resolver
returns `.unavailable(...)` with a message explaining why we refuse to run
unsandboxed — `sandbox_init` is process-wide and is not a child-only
replacement.

## Workspace policy enforcement

In-process tools that don't fork (e.g. `apply_patch`, `view_image`) consult
the workspace policy directly via `WorkspaceSandbox.evaluateWrite(path:)`.
File-touching tools also use `FileTools.assertContained(...)` to verify that
the realpath of a target stays inside the writable roots, even if the path
was given via an embedded symlink.

### Symlink realpath checks

`FileTools.assertContained` (in `Sources/Tools/FileTools.swift`) calls
`realpath(3)` and compares the canonical result against each writable root.
This is what prevents the classic "symlink in workspace pointing to
`/etc/shadow`" escape: the realpath of the link target is outside the root,
so the write is rejected before the file descriptor opens.

### `/var/folders` ↔ `/private/var/folders` normalisation

On macOS, `/var/folders` is a symlink to `/private/var/folders`. The
canonicalisation step folds them into the same path so that a writable root
specified as `/var/folders/...` accepts a write to
`/private/var/folders/...` and vice versa. The fold happens in
`WorkspaceSandbox.canonicalPath(_:)` (via `realpath`).

## Process group containment

Every sandboxed child is launched into its own POSIX process group via
`setpgid(pid, pid)` immediately after `Process.run()`. This is what lets the
session terminate a misbehaving child *and any grandchildren it spawned*
with a single `kill(-pid, SIGTERM)`. The MCP client
(`Sources/MCP/McpClient.swift`) is the canonical implementation; spawned
workers use the same pattern.

There is a known race: a child can `execve` before the parent's `setpgid`
runs. We additionally call `setpgid` in the parent right after `Process.run`
— both sides may call `setpgid`, and the second one is a no-op once the
first wins.

### `terminateProcessGroupGracefully`

`McpClient.terminateProcessGroupGracefully(pid:)` is the canonical termination
path. Behaviour:

1. Read the child's pgid with `getpgid(pid)`.
2. If `pgid == pid` (child is in its own group), `kill(-pid, SIGTERM)` to
   signal the entire group.
3. If `pgid != pid` (the `setpgid` race lost; the child is still in the
   parent's group), fall back to single-PID SIGTERM. We must *not* `kill(-pid)`
   in this case — that would target the parent's group.
4. Wait up to 2 seconds for the child to exit, polling with `kill(pid, 0)`
   every 50ms.
5. If the deadline passes, `SIGKILL` the group (or PID, per the same logic).

Crucially the wait is **non-blocking with respect to the actor**: the SIGTERM
is issued synchronously so the caller observes the immediate effect; the
2-second poll and the eventual SIGKILL run on `DispatchQueue.global()` and
the caller `await`s a continuation. The actor's executor thread is free to
service other messages during the wait. This mirrors upstream's `spawn(move
|| { sleep(...); ... })` pattern in
`rmcp-client/src/stdio_server_launcher.rs::terminate`.

## ExecPolicy and RulesStore

The execpolicy classifier (`Sources/Tools/ExecPolicy.swift`) maps an argv
into `ExecDecision = safe | needsApproval | forbidden`. It is consulted by
the `decideCommand` path in the approval engine before any sandboxed launch.

### Rule files

`ExecPolicy.load(codexHome:)` reads:

- `$CODEX_HOME/exec_policy.json` — legacy JSON shim (`{forbidden: [[..]],
  allow: [[..]]}`), retained for back-compat.
- `$CODEX_HOME/exec_policy.rules` / `exec_policy.codexpolicy` — top-level rule
  files.
- `$CODEX_HOME/rules/*.rules` and `$CODEX_HOME/rules/*.codexpolicy` —
  per-source rule files; sorted lexically for determinism.

All files are parsed and merged. **Invalid policy files fail closed**: a
`loadError` is recorded on the resulting `ExecPolicy`, and `classify(argv:)`
returns `.forbidden` for every command. This is the safer behaviour — a
typo in a rule file does not silently widen the allowlist.

### Rule syntax

The `.rules` format is line-oriented, comment-stripped (the parser is in
`ExecPolicy.parseRules`). Three function calls are recognised:

```text
# allow `git status` and `git diff` without prompting
prefix_rule(pattern=["git", ["status","diff"]], decision="allow")

# `rm -rf` always requires explicit user consent
prefix_rule(pattern=["rm", "-rf"], decision="prompt")

# absolute-path forms get classified via the basename
host_executable(name="git", paths=["/usr/bin/git", "/opt/homebrew/bin/git"])

# allow https to api.github.com
network_rule(host="api.github.com", protocol="https", decision="allow",
             justification="GitHub API for issue automation")
```

A pattern token is either a string (exact match) or an array of alternatives
(`["status","diff"]` matches either). The first token of a pattern is the
command basename or absolute path; subsequent tokens are matched positionally
against argv. `decision` is one of `"allow"`, `"prompt"`, `"forbidden"`
(network decisions also accept `"deny"`).

`host_executable` lets a rule written against the bare name (`git`) also
match an absolute-path invocation (`/usr/bin/git`). At classify time, if the
first argv token is an absolute path whose basename is registered, the
classifier rewrites it to the bare name before matching against
`prefix_rule`s.

### `default.rules` and durable approvals

When the user approves "always allow" for a command prefix, two stores are
updated:

1. Legacy `$CODEX_HOME/approved_commands.json` (string-keyed; retained for
   existing Swift state).
2. Canonical `$CODEX_HOME/rules/default.rules`, with one appended
   `prefix_rule(pattern=["git","status"], decision="allow")` line.

The canonical file is also the file the Rust codex CLI reads/writes
(`codex_execpolicy::blocking_append_allow_prefix_rule`). The two stores are
populated independently so a transient failure in one cannot lose the approval.

`RulesStore` (`Sources/Tools/RulesStore.swift`) handles the append. Tokens
are JSON-encoded via `JSONSerialization` so embedded quotes or backslashes
round-trip safely; hosts are normalised before being serialised; duplicate
lines are deduplicated on append.

### File locking (P4.2)

`Sources/Tools/FileLock.swift` provides `withExclusiveLock` (LOCK_EX) and
`withSharedLock` (LOCK_SH). `RulesStore.appendLine` uses `LOCK_EX` for the
read-then-write append, and `RulesStore.readLocked` uses `LOCK_SH` on read.

This is the TOCTOU fix documented as P4.2 / parity item. Previously the
Swift implementation only used `atomic: true` (rename), which still let
readers race the rename or another writer lose a concurrent append. With
LOCK_EX held for the duration of the read-then-write, multiple processes
(codexd, the Rust codex CLI, parity tests) all serialise cleanly:

```swift
return try FileLock.withExclusiveLock(path: path) { fd in
    try seekToStart(fd, path: path)
    let existing = try readAll(fd, path: path)
    // dedupe check
    if existing.split(...).contains(where: { $0 == Substring(line) }) {
        return false
    }
    try seekToEnd(fd, path: path)
    if !existing.isEmpty, !existing.hasSuffix("\n") {
        try writeBytes(fd, bytes: Array("\n".utf8), path: path)
    }
    var bytes = Array(line.utf8); bytes.append(0x0A)
    try writeBytes(fd, bytes: bytes, path: path)
    return true
}
```

The `EINTR` retry loop on `flock` and on `read`/`write` is faithful to the
upstream Rust implementation — slow disks and signals can briefly interrupt
either syscall.

### Classification flow

`ExecPolicy.classify(argv:resolveHostExecutables:)`:

1. If `loadError != nil`, return `.forbidden`.
2. If `argv.isEmpty`, return `.needsApproval`.
3. Check the legacy JSON `forbidden` list (prefix match). Any match →
   `.forbidden`.
4. Check the legacy JSON `allow` list. Any match → `.safe`.
5. Check `prefix_rule` matches against argv. If `resolveHostExecutables` and
   the first argv token is an absolute path, also rewrite to the basename
   and re-match. The strictest matching decision wins (max of `.safe <
   .needsApproval < .forbidden`).
6. Fall back to `CommandSafety.classify(argv:)` — the upstream-default
   read-only-ish safe list (`ls`, `cat`, `grep`, …).

## ApprovalPolicyEngine

`Sources/HarnessCore/Approvals.swift` is the pure policy-decision engine. It
takes the user's selected `ApprovalPolicy` (from `ProtocolModel.Approvals`)
plus the situational inputs and returns one of:

```swift
public enum ApprovalDecisionKind {
    case proceedSandboxed     // run inside the sandbox, no consent needed
    case proceedEscalated     // run unsandboxed (consent implied by policy)
    case requestThenEscalate  // ask client; on accept, run unsandboxed
    case requestThenProceed   // ask client; on accept, run sandboxed (patch path)
    case rejectNoEscalation   // hard reject — policy forbids escalation
}
```

The five `ApprovalPolicy` cases (`ProtocolModel.ApprovalPolicy`):

- `.never` — never prompt; commands run only in the sandbox.
- `.unlessTrusted` — wire string `"untrusted"` (upstream's `UnlessTrusted`).
  Prompt for everything except a small allowlist of safe-read commands.
- `.onFailure` — run sandboxed; if the sandbox blocks the action, ask to re-run
  unsandboxed.
- `.onRequest` — default. Prompt when the model requests escalation, when the
  command isn't classified `.safe`, or when a patch targets outside the
  writable roots.
- `.granular(GranularApprovalConfig)` — fine-grained per-category gating.

### `.granular` per-axis behaviour

The granular config carries five booleans (snake_case on the wire):

```swift
public struct GranularApprovalConfig {
    public var sandboxApproval: Bool        // "sandbox_approval"
    public var rules: Bool                  // "rules"
    public var skillApproval: Bool          // "skill_approval"
    public var requestPermissions: Bool     // "request_permissions"
    public var mcpElicitations: Bool        // "mcp_elicitations"
}
```

Each axis independently gates a category of prompts: `true` means prompts of
that category may fire; `false` means they are auto-rejected instead of
surfaced to the user.

Only `sandbox_approval` actively branches the command/patch decision in
`ApprovalPolicyEngine`. The other four axes feed the
`PermissionsInstructions` block of the prompt assembly — i.e. they shape what
the model is told about what it can ask for, but they do not change the
runtime decision tree for command/patch ops. This is the P4.1 follow-up
documented in `/tmp/parity-fixes/FOLLOWUPS.md`.

When `sandbox_approval == false` under granular:

- For commands: the sandbox-approval prompt is suppressed. The engine falls
  back to never-equivalent behaviour — run sandboxed; let it fail rather than
  prompt.
- For patches outside writable roots: the request prompt is suppressed and
  the engine *rejects* (matching upstream's "reject instead of prompt"
  semantics). Patches *inside* writable roots still proceed sandboxed.

When `sandbox_approval == true` under granular the engine behaves like
`.onRequest`.

## Decision flow

### `decideCommand(policy:safety:modelRequestedEscalation:)`

| policy           | safety            | modelEsc | decision                |
|------------------|-------------------|----------|-------------------------|
| `.never`         | any               | any      | `proceedSandboxed`      |
| `.unlessTrusted` | `.safe`           | any      | `proceedSandboxed`      |
| `.unlessTrusted` | `.needsApproval+` | any      | `requestThenEscalate`   |
| `.onFailure`     | any               | any      | `proceedSandboxed`      |
| `.onRequest`     | any               | true     | `requestThenEscalate`   |
| `.onRequest`     | `.safe`           | false    | `proceedSandboxed`      |
| `.onRequest`     | `.needsApproval+` | false    | `requestThenEscalate`   |
| `.granular` sa=t | (same as onReq.)  | —        | (same as onRequest)     |
| `.granular` sa=f | any               | any      | `proceedSandboxed`      |

### `decidePatch(policy:withinWritableRoots:)`

| policy           | withinRoots | decision                |
|------------------|-------------|-------------------------|
| `.never`         | true        | `proceedSandboxed`      |
| `.never`         | false       | `rejectNoEscalation`    |
| `.unlessTrusted` | any         | `requestThenProceed`    |
| `.onFailure`     | any         | `proceedSandboxed`      |
| `.onRequest`     | true        | `proceedSandboxed`      |
| `.onRequest`     | false       | `requestThenProceed`    |
| `.granular` sa=t | true        | `proceedSandboxed`      |
| `.granular` sa=t | false       | `requestThenProceed`    |
| `.granular` sa=f | true        | `proceedSandboxed`      |
| `.granular` sa=f | false       | `rejectNoEscalation`    |

### `decideSkill` and `decidePermissions`

Skill execution (`skill_approval`) and the `request_permissions` tool path
(`request_permissions`) are gated independently by the corresponding
granular axes. Under `.granular(cfg)`:

- Skill scripts that would prompt are auto-rejected when `cfg.skillApproval`
  is false; otherwise the prompt proceeds as under `.onRequest`.
- `request_permissions` calls with no current grant are auto-rejected when
  `cfg.requestPermissions` is false.

Under non-granular policies the skill/permissions paths use the same
behaviour as `.onRequest`.

### `prefixKey` for durable approval

`ApprovalPolicyEngine.prefixKey(command argv:)` returns the first two argv
tokens joined by space. This is the key used for both the in-memory
`acceptForSession` set and the durable `approved_commands.json` /
`default.rules` stores. So an approval for `git status` covers `git status`
but not `git push`, and a single approval covers all subsequent invocations
of the same prefix.

## Resource governance

Per-worker resource governance is applied at worker startup
(`Sources/SessionWorkerCore/WorkerRuntime.swift::ProcessResourceControl`).
Two limits:

### Physical-footprint cap

`task_set_phys_footprint_limit(mach_task_self_, mebibytes, &oldLimit)` caps
the Mach task's physical memory footprint. The limit is configured per
worker via `WorkerResourceControl.physicalMemoryLimitBytes` and rounded up to
the nearest MiB. Hitting the cap triggers a Jetsam-style kill — preferable
to ballooning swap when the model emits an unbounded tool output.

### QoS throttling

`task_policy_set(mach_task_self_, TASK_BASE_QOS_POLICY, ...)` sets the
task-wide latency and throughput QoS tiers. Two presets:

- `.normal` — `LATENCY_QOS_TIER_3` + `THROUGHPUT_QOS_TIER_3`.
- `.throttled` — `LATENCY_QOS_TIER_5` + `THROUGHPUT_QOS_TIER_5`. Used when
  the worker is in a backgrounded session so foreground UI responsiveness
  stays clean.

When the worker comes back to the foreground the QoS is restored to
`.normal`. Both transitions are best-effort — `task_policy_set` failures are
logged via `failures.append("…")` but do not abort the worker.

On Linux these calls are no-ops; the worker still runs but without QoS
shaping. cgroup-based equivalents are left to the operator's systemd unit
(if any).
