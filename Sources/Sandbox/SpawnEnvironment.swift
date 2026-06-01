import Foundation

/// Policy that decides which environment variables propagate to a sandboxed
/// child process. The default policy is restrictive: only an explicit
/// allowlist of locale / shell / project variables passes through, and a
/// secret-name blocklist (`*_TOKEN`, `*_KEY`, `*_SECRET`, `OPENAI_*`,
/// `ANTHROPIC_*`, `AWS_*`, `GITHUB_*`, `GCP_*`, `AZURE_*`, `SSH_AUTH_SOCK`,
/// `GNUPGHOME`) prunes anything that snuck onto the allowlist via a prefix
/// (e.g. a hypothetical future `TERM_KEY`).
///
/// Background: before this policy was added, both `ShellTool` and
/// `UnifiedExec` passed `ProcessInfo.processInfo.environment` to children
/// verbatim. Any API key in the harness's own environment (`OPENAI_API_KEY`,
/// `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`,
/// `SSH_AUTH_SOCK`, etc.) was reachable from inside the sandboxed child via
/// `env` / `printenv` / `ps -E -p $$`. The kernel sandbox profile cannot help
/// here — the secrets are inherited through the spawn, not through a syscall
/// the profile gates.
///
/// Allowlist wins over the blocklist when a name is on both — that's how we
/// admit `CODEX_*` exec-policy passthroughs without granting the model a
/// generic `*_KEY` allowance. Callers can extend either side via
/// `SandboxPolicy.environmentPolicy`.
public struct SandboxEnvironmentPolicy: Sendable, Equatable {
    /// Exact variable names (case-sensitive) that always propagate.
    public var allowExact: Set<String>
    /// Prefixes (case-sensitive). A variable propagates if its name starts
    /// with one of these. Designed for project namespaces like `CODEX_*`.
    public var allowPrefixes: [String]
    /// Suffix-based denial. Anything ending in one of these is stripped even
    /// if its name is on the allowlist (defence-in-depth against a sloppy
    /// future allowlist entry).
    public var denySuffixes: [String]
    /// Prefix-based denial. Same precedence rules.
    public var denyPrefixes: [String]
    /// Exact denials. Useful for unstructured names like `SSH_AUTH_SOCK`.
    public var denyExact: Set<String>
    /// Extra variables that are always set on the child even if the parent
    /// doesn't define them (e.g. `NSUnbufferedIO=YES` to make stdout flush
    /// promptly on macOS). The child sees these even if the same name is on
    /// `denyPrefixes/denySuffixes/denyExact` — they're injected post-scrub.
    public var extras: [String: String]
    /// When non-nil, inject `CODEX_SANDBOX=<value>` into the child env
    /// post-scrub. Upstream sets `CODEX_SANDBOX="seatbelt"` for every command
    /// run under the macOS Seatbelt sandbox (`core/src/sandboxing/mod.rs:139-142`
    /// / `core/src/spawn.rs:22-25`). The value is parameterised (rather than
    /// hardcoded) so other backends can extend it without changing `scrub()`.
    public var injectedSandboxType: String?
    /// When true, inject `CODEX_SANDBOX_NETWORK_DISABLED="1"` into the child env
    /// post-scrub. Upstream sets this whenever the network sandbox policy is not
    /// enabled (`core/src/spawn.rs:78-80` and `core/src/sandboxing/mod.rs:133-138`)
    /// so spawned commands can detect that network access is unavailable.
    public var networkDisabled: Bool

    public init(allowExact: Set<String>,
                allowPrefixes: [String],
                denySuffixes: [String],
                denyPrefixes: [String],
                denyExact: Set<String>,
                extras: [String: String],
                injectedSandboxType: String? = nil,
                networkDisabled: Bool = false) {
        self.allowExact = allowExact
        self.allowPrefixes = allowPrefixes
        self.denySuffixes = denySuffixes
        self.denyPrefixes = denyPrefixes
        self.denyExact = denyExact
        self.extras = extras
        self.injectedSandboxType = injectedSandboxType
        self.networkDisabled = networkDisabled
    }

    /// Restrictive default policy. Allows the variables a typical UNIX child
    /// needs to find its tools (`PATH`), locate the user's home/locale, and
    /// any `CODEX_*` project variables (the exec-policy contract sets a few
    /// of these to pass intent through to children). Strips every common
    /// secret prefix/suffix.
    public static let `default` = SandboxEnvironmentPolicy(
        allowExact: [
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LC_MESSAGES",
            "LC_COLLATE",
            "LC_MONETARY",
            "LC_NUMERIC",
            "LC_TIME",
            "TERM",
            "TMPDIR",
            "SHELL",
            "PWD",
            "TZ",
            // macOS-specific helpers used by interactive children. None of
            // them carry secrets in a properly-configured environment.
            "__CF_USER_TEXT_ENCODING",
        ],
        allowPrefixes: [
            "CODEX_",   // exec-policy passthroughs (see exec-policy contract)
        ],
        denySuffixes: [
            "_TOKEN",
            "_KEY",
            "_SECRET",
            "_PASSWORD",
            "_PASSWD",
            "_API_KEY",
            "_PRIVATE_KEY",
            "_ACCESS_TOKEN",
            "_REFRESH_TOKEN",
        ],
        denyPrefixes: [
            "OPENAI_",
            "ANTHROPIC_",
            "AWS_",
            "GITHUB_",
            "GH_",
            "GCP_",
            "GOOGLE_",
            "AZURE_",
            "ANTHROPIC_",
            "HF_",
            "HUGGINGFACE_",
            "STRIPE_",
            "TWILIO_",
            "DATABASE_",
            "DB_",
            "MYSQL_",
            "POSTGRES_",
            "REDIS_",
            "MONGO_",
            "SENTRY_",
            "DATADOG_",
            "DD_",
            "NEW_RELIC_",
            "NPM_",
            "PYPI_",
            "CARGO_REGISTRY_",
            "DOCKERHUB_",
        ],
        denyExact: [
            "SSH_AUTH_SOCK",
            "GNUPGHOME",
            "GPG_AGENT_INFO",
            "AWS_SESSION_TOKEN",
            "KUBECONFIG",
            "DOCKER_AUTH_CONFIG",
        ],
        extras: [
            "NSUnbufferedIO": "YES",
        ]
    )

    /// Returns true if `name` is permitted to propagate. Allowlist + deny rules
    /// combine as: allowed if (in `allowExact` or matches an `allowPrefix`)
    /// AND not blocked by any deny rule.
    public func allows(_ name: String) -> Bool {
        if denyExact.contains(name) { return false }
        for p in denyPrefixes where name.hasPrefix(p) { return false }
        for s in denySuffixes where name.hasSuffix(s) { return false }
        if allowExact.contains(name) { return true }
        for p in allowPrefixes where name.hasPrefix(p) { return true }
        return false
    }

    /// Scrub a parent environment and apply `extras`. Result is the env that
    /// should be handed to `posix_spawn` for a sandboxed child.
    public func scrub(_ parent: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(parent.count)
        for (k, v) in parent where allows(k) {
            out[k] = v
        }
        for (k, v) in extras {
            out[k] = v
        }
        // Upstream `populate_env` (protocol/src/shell_environment.rs:106) always
        // injects `CODEX_THREAD_ID` last when the thread id is known. The harness
        // sets it in its own process environment, so a present value is
        // propagated to the child even under the restrictive allowlist (it is
        // read-only run metadata, not a secret). Injected post-scrub so the
        // deny rules cannot strip it.
        if let threadId = parent[Self.codexThreadIdEnvVar] {
            out[Self.codexThreadIdEnvVar] = threadId
        }
        // Sandboxing telemetry/behaviour env vars (upstream
        // `core/src/spawn.rs:78-80` + `core/src/sandboxing/mod.rs:133-142`).
        // Both are injected POST-scrub so the deny rules (`CODEX_*` is on the
        // allow-prefix list but a future deny rule must not be able to strip
        // these) cannot remove them, exactly as upstream sets them on the
        // `Command`/exec env after assembling the rest of the environment.
        if networkDisabled {
            out[Self.codexSandboxNetworkDisabledEnvVar] = "1"
        }
        if let sandboxType = injectedSandboxType {
            out[Self.codexSandboxEnvVar] = sandboxType
        }
        return out
    }
}

public extension SandboxEnvironmentPolicy {
    /// Upstream `shell_environment.rs::CODEX_THREAD_ID_ENV_VAR`.
    static let codexThreadIdEnvVar = "CODEX_THREAD_ID"
    /// Upstream `core/src/spawn.rs:25` `CODEX_SANDBOX_ENV_VAR`.
    static let codexSandboxEnvVar = "CODEX_SANDBOX"
    /// Upstream `core/src/spawn.rs:20` `CODEX_SANDBOX_NETWORK_DISABLED_ENV_VAR`.
    static let codexSandboxNetworkDisabledEnvVar = "CODEX_SANDBOX_NETWORK_DISABLED"
    /// Upstream value for `SandboxType::MacosSeatbelt` (`sandboxing/mod.rs:141`).
    static let macosSeatbeltSandboxTag = "seatbelt"

    /// Convenience: scrub the current process's environment. Centralised here
    /// so the two spawn sites (ShellTool, UnifiedExec) cannot drift.
    static func scrubbed(parent: [String: String] =
                         ProcessInfo.processInfo.environment,
                         policy: SandboxEnvironmentPolicy = .default,
                         additionalExtras: [String: String] = [:])
        -> [String: String] {
        var env = policy.scrub(parent)
        for (k, v) in additionalExtras { env[k] = v }
        return env
    }
}

/// Faithful port of upstream `ShellEnvironmentPolicy` + `populate_env`
/// (`protocol/src/config_types.rs` and `protocol/src/shell_environment.rs`).
///
/// The codex-swift sandbox uses the restrictive allowlist
/// (`SandboxEnvironmentPolicy.default`) as its silent default — a deliberate
/// security hardening (children cannot read the harness's API keys via `env`).
/// Upstream's documented algorithm is instead inherit-all-by-default with a
/// case-insensitive `*KEY*`/`*SECRET*`/`*TOKEN*` substring scrub gated on
/// `ignoreDefaultExcludes`. This type makes the upstream algorithm available as
/// an explicit, opt-in policy (e.g. for hosts that mirror upstream's
/// configuration surface) and computes the child env exactly as `populate_env`
/// does, including the trailing `CODEX_THREAD_ID` injection.
public struct ShellEnvironmentPolicyConfig: Sendable, Equatable {
    /// Upstream `ShellEnvironmentPolicyInherit`.
    public enum Inherit: Sendable, Equatable { case all, none, core }

    public var inherit: Inherit
    /// When false, the default `*KEY*`/`*SECRET*`/`*TOKEN*` excludes apply.
    public var ignoreDefaultExcludes: Bool
    /// Custom exclude glob patterns (`*`/`?`), case-insensitive — upstream
    /// `WildMatchPattern<'*','?'>`.
    public var exclude: [String]
    /// Upstream `set`: forced overrides, applied after excludes.
    public var set: [String: String]
    /// Upstream `include_only`: when non-empty, keep only matching vars.
    public var includeOnly: [String]

    /// Upstream `ShellEnvironmentPolicy::default` (config_types.rs:218-223):
    /// `inherit: All`, `ignore_default_excludes: true` — full inherit, no scrub.
    public static let `default` = ShellEnvironmentPolicyConfig(
        inherit: .all, ignoreDefaultExcludes: true,
        exclude: [], set: [:], includeOnly: [])

    public init(inherit: Inherit,
                ignoreDefaultExcludes: Bool,
                exclude: [String],
                set: [String: String],
                includeOnly: [String]) {
        self.inherit = inherit
        self.ignoreDefaultExcludes = ignoreDefaultExcludes
        self.exclude = exclude
        self.set = set
        self.includeOnly = includeOnly
    }

    /// Upstream `UNIX_CORE_ENV_VARS` (shell_environment.rs:113-116).
    static let unixCoreEnvVars: [String] = [
        "PATH", "SHELL", "TMPDIR", "TEMP", "TMP", "HOME",
        "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "USER",
    ]

    /// Verbatim port of `populate_env` (shell_environment.rs:46-108): inherit,
    /// default-excludes, custom excludes, `set` overrides, `include_only`, then
    /// the `CODEX_THREAD_ID` injection.
    public func populateEnv(_ vars: [String: String],
                            threadId: String?) -> [String: String] {
        // Step 1 — inherit strategy.
        var env: [String: String]
        switch inherit {
        case .all:
            env = vars
        case .none:
            env = [:]
        case .core:
            env = vars.filter { (k, _) in
                Self.unixCoreEnvVars.contains { $0.caseInsensitiveCompare(k) == .orderedSame }
            }
        }

        func matchesAny(_ name: String, _ patterns: [String]) -> Bool {
            patterns.contains { EnvPattern.matches(pattern: $0, name: name) }
        }

        // Step 2 — default excludes (case-insensitive substring), gated.
        if !ignoreDefaultExcludes {
            let defaultExcludes = ["*KEY*", "*SECRET*", "*TOKEN*"]
            env = env.filter { (k, _) in !matchesAny(k, defaultExcludes) }
        }
        // Step 3 — custom excludes.
        if !exclude.isEmpty {
            env = env.filter { (k, _) in !matchesAny(k, exclude) }
        }
        // Step 4 — user-provided overrides.
        for (k, v) in set { env[k] = v }
        // Step 5 — include_only retains only matches.
        if !includeOnly.isEmpty {
            env = env.filter { (k, _) in matchesAny(k, includeOnly) }
        }
        // Step 6 — thread id injection.
        if let threadId {
            env[SandboxEnvironmentPolicy.codexThreadIdEnvVar] = threadId
        }
        return env
    }
}

/// Minimal case-insensitive glob matcher for `*` / `?`, matching the semantics
/// of upstream's `WildMatchPattern<'*','?'>` (the `wildmatch` crate) as used by
/// `EnvironmentVariablePattern`. `*` matches any run (including empty), `?`
/// matches exactly one character.
enum EnvPattern {
    static func matches(pattern: String, name: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(name.lowercased())
        // Iterative wildcard match with backtracking on `*`.
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Policy for which executable paths a non-full-access spawn may exec
/// directly. Bare names (no leading slash) are NEVER honoured; the legacy
/// `/usr/bin/env <name>` wrapper has been removed (audit finding: PATH
/// search happened OUTSIDE the sandbox, defeating the kernel profile). If a
/// caller needs PATH search, they must invoke a shell explicitly via
/// `/bin/sh -c`.
public struct SandboxExecPolicy: Sendable, Equatable {
    /// Absolute paths to executables that are unconditionally allowed (in
    /// addition to the implicit rule "anything with an absolute path").
    /// Reserved for future expansion: an "allowlist-mode" sandbox could
    /// limit children to only these. Empty today means "any absolute path
    /// is fine; reject only bare names".
    public var allowlist: Set<String>
    public init(allowlist: Set<String> = []) { self.allowlist = allowlist }
    public static let `default` = SandboxExecPolicy()
}
