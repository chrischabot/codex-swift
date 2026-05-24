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

    public init(allowExact: Set<String>,
                allowPrefixes: [String],
                denySuffixes: [String],
                denyPrefixes: [String],
                denyExact: Set<String>,
                extras: [String: String]) {
        self.allowExact = allowExact
        self.allowPrefixes = allowPrefixes
        self.denySuffixes = denySuffixes
        self.denyPrefixes = denyPrefixes
        self.denyExact = denyExact
        self.extras = extras
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
        return out
    }
}

public extension SandboxEnvironmentPolicy {
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
