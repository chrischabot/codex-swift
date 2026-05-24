import Foundation
import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SandboxPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable, Codable { case readOnly, workspaceWrite, dangerFullAccess }
    public var mode: Mode
    public var writableRoots: [String]
    public var networkAllowed: Bool
    public var networkAllowedDomains: [String]
    public var networkDeniedDomains: [String]
    public init(mode: Mode = .workspaceWrite,
                writableRoots: [String] = [],
                networkAllowed: Bool = false,
                networkAllowedDomains: [String] = [],
                networkDeniedDomains: [String] = []) {
        self.mode = mode
        self.writableRoots = writableRoots
        self.networkAllowed = networkAllowed
        self.networkAllowedDomains = networkAllowedDomains
        self.networkDeniedDomains = networkDeniedDomains
    }
}

/// Unambiguous alias for the runtime sandbox policy struct, exported so
/// callers that also import `ProtocolModel` (which now defines a wire-format
/// `SandboxPolicy`) can refer to this type without name-collision errors.
public typealias RuntimeSandboxPolicy = SandboxPolicy

public struct SandboxDecision: Sendable, Equatable {
    public enum Outcome: String, Sendable { case allow, deny }
    public var outcome: Outcome
    public var reason: String
}

/// The launch decision for a sandboxed child process. `.run` carries the
/// final argv (possibly wrapped by `sandbox-exec`/`bwrap`); `.deny` means a
/// sandbox was required but cannot be enforced on this platform, so the
/// command must NOT run.
public enum SandboxInvocation: Sendable, Equatable {
    case run([String])
    case deny(String)
}

public enum SandboxBackend: Sendable, Equatable {
    case sandboxExec(String)
    case bubblewrap(String)
    case unavailable(String)
}

public struct SandboxBackendResolver: Sendable {
    public var sandboxExecPaths: [String]
    public var bubblewrapPaths: [String]

    public init(sandboxExecPaths: [String] = ["/usr/bin/sandbox-exec"],
                bubblewrapPaths: [String] = ["/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap"]) {
        self.sandboxExecPaths = sandboxExecPaths
        self.bubblewrapPaths = bubblewrapPaths
    }

    public func resolve() -> SandboxBackend {
        #if os(macOS)
        if let sandboxExec = sandboxExecPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return .sandboxExec(sandboxExec)
        }
        return .unavailable("macOS Seatbelt sandbox-exec unavailable; sandbox_init is process-wide and not a child-only replacement for tool launches, so refusing to run unsandboxed")
        #elseif os(Linux)
        if let bwrap = bubblewrapPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return .bubblewrap(bwrap)
        }
        return .unavailable("Linux kernel sandbox bubblewrap unavailable; refusing to run unsandboxed")
        #else
        return .unavailable("no supported kernel sandbox backend for this platform; refusing to run unsandboxed")
        #endif
    }
}

/// A sandbox policy-evaluates a filesystem/network operation. Tool child
/// processes (rework §7.9) run under the platform implementation; the policy
/// decision is portable and unit-tested.
public protocol Sandbox: Sendable {
    func evaluateWrite(path: String) -> SandboxDecision
    func evaluateNetwork(host: String) -> SandboxDecision
    /// Returns only an explicit domain rule decision. `nil` means this
    /// sandbox has no matching domain override for the host.
    func evaluateNetworkDomainRule(host: String) -> SandboxDecision?
    /// Generate the platform confinement spec for a child exec (Seatbelt
    /// profile on macOS). Returns nil where the platform applies confinement
    /// out-of-band (e.g. process group + rlimits only).
    func confinementProfile(cwd: String) -> String?
    /// Build the actual sandboxed launch for `argv` in `cwd`. Wraps with the
    /// kernel sandbox where available, or denies when confinement cannot be
    /// enforced for a non-full-access policy.
    func sandboxedInvocation(argv: [String], cwd: String) -> SandboxInvocation
}

public extension Sandbox {
    func sandboxedInvocation(argv: [String], cwd: String) -> SandboxInvocation {
        .run(argv)
    }
    func evaluateNetworkDomainRule(host: String) -> SandboxDecision? {
        nil
    }
}

/// Portable, workspace-confined policy. This is the *decision* engine and is
/// fully tested; on macOS the Seatbelt profile (`confinementProfile`) is
/// applied through a child-scoped backend such as `sandbox-exec`. Direct
/// `sandbox_init` is process-wide and is not used as a child-launch wrapper.
/// The allow/deny outcomes here already match Codex's policy classes.
public struct WorkspaceSandbox: Sandbox {
    public let policy: SandboxPolicy
    private let backendResolver: SandboxBackendResolver
    public init(_ policy: SandboxPolicy) {
        self.init(policy, backendResolver: SandboxBackendResolver())
    }
    public init(_ policy: SandboxPolicy,
                backendResolver: SandboxBackendResolver) {
        self.policy = policy
        self.backendResolver = backendResolver
    }

    static func canonicalPath(_ path: String) -> String {
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func sbplStringLiteral(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "\"":
                // SBPL plain `"..."` string literals do NOT recognize `\"` as
                // an escape — the `"` after `\` closes the string and the
                // remainder becomes raw SBPL, which is both a parse error and
                // a potential injection vector. Use a hex escape so the SBPL
                // lexer never sees a bare `"` inside the literal. This mirrors
                // the same defence used in `sbplRegexLiteral` for `#"..."#`.
                out += "\\x22"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    static func normalizedNetworkHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if let url = URL(string: host), let parsedHost = url.host,
           host.contains("://") {
            host = parsedHost.lowercased()
        }
        if host.hasPrefix("[") && host.contains("]"),
           let end = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<end])
        }
        if let colon = host.lastIndex(of: ":"),
           host[..<colon].contains("."),
           host[host.index(after: colon)...].allSatisfy({ $0.isNumber }) {
            host = String(host[..<colon])
        }
        return host
    }

    static func networkHost(_ host: String, matches pattern: String) -> Bool {
        let h = normalizedNetworkHost(host)
        let p = normalizedNetworkHost(pattern)
        if p.hasPrefix("*.") {
            let suffix = String(p.dropFirst(2))
            return h == suffix || h.hasSuffix("." + suffix)
        }
        return h == p
    }

    private func isUnder(_ path: String, _ root: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    public func evaluateWrite(path: String) -> SandboxDecision {
        switch policy.mode {
        case .dangerFullAccess:
            return .init(outcome: .allow, reason: "full access")
        case .readOnly:
            return .init(outcome: .deny, reason: "read-only sandbox")
        case .workspaceWrite:
            if policy.writableRoots.contains(where: { isUnder(path, $0) }) {
                return .init(outcome: .allow, reason: "within writable root")
            }
            return .init(outcome: .deny, reason: "outside workspace writable roots")
        }
    }

    public func evaluateNetwork(host: String) -> SandboxDecision {
        if let domain = evaluateNetworkDomainRule(host: host) {
            return domain
        }
        if policy.networkAllowed {
            return SandboxDecision(outcome: .allow, reason: "network allowed")
        }
        return SandboxDecision(outcome: .deny, reason: "network disabled by policy")
    }

    public func evaluateNetworkDomainRule(host: String) -> SandboxDecision? {
        if policy.networkDeniedDomains.contains(where: { Self.networkHost(host, matches: $0) }) {
            return .init(outcome: .deny, reason: "network denied by domain policy")
        }
        if policy.networkAllowedDomains.contains(where: { Self.networkHost(host, matches: $0) }) {
            return .init(outcome: .allow, reason: "network allowed by domain policy")
        }
        return nil
    }

    /// Top-level workspace metadata path basenames that must remain unwritable
    /// even when located inside a writable root. Mirrors upstream's
    /// `PROTECTED_METADATA_PATH_NAMES` (`codex_protocol::permissions`) and
    /// closes the hook-injection escalation vector documented as parity H-23.
    static let protectedMetadataNames: [String] = [".git", ".agents", ".codex"]

    /// Returns the regex (without anchors-escaping for SBPL transport) that
    /// matches `<root>/<name>` and anything beneath it. Mirrors upstream
    /// `seatbelt_protected_metadata_name_regex`.
    static func protectedMetadataRegex(root: String, name: String) -> String {
        // Strip trailing slashes (preserve the leading "/" for filesystem
        // root). Matches upstream behaviour.
        var trimmedRoot = root
        while trimmedRoot.count > 1 && trimmedRoot.hasSuffix("/") {
            trimmedRoot.removeLast()
        }
        let escapedRoot = regexEscape(trimmedRoot)
        let escapedName = regexEscape(name)
        if trimmedRoot == "/" {
            return "^/\(escapedName)(/.*)?$"
        }
        return "^\(escapedRoot)/\(escapedName)(/.*)?$"
    }

    /// Minimal regex meta-character escape sufficient for the subset of
    /// characters that can appear in absolute filesystem paths and the
    /// protected metadata basenames (`.`).
    static func regexEscape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case ".", "\\", "+", "*", "?", "(", ")", "[", "]", "{", "}", "^", "$", "|", "/":
                out += "\\"
                out.unicodeScalars.append(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Renders a regex pattern as an SBPL extended-string literal payload for
    /// use inside `(regex #"...")` deny clauses. The `#"..."#` literal is
    /// *raw*: backslashes are preserved as-is (no `\"` escape exists, so a
    /// literal `"` would terminate the literal). We rely on the regex
    /// engine's own `\xNN` byte-escape for `"` and any control character,
    /// so the SBPL lexer only ever sees printable ASCII other than `"`.
    /// (We never need to encode `\` itself — `\` is already a regex
    /// metachar, and the SBPL lexer passes it through untouched.)
    static func sbplRegexLiteral(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"":
                // `\"` is not a valid escape inside `#"..."#`. Use the
                // regex byte-escape so the engine still matches the literal
                // quote while the SBPL lexer sees printable ASCII.
                out += "\\x22"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Build the Seatbelt (SBPL) profile text for a given policy + cwd. Static
    /// so the profile-generation logic is testable cross-platform; the
    /// `confinementProfile` instance method gates this to macOS at runtime.
    /// Mirrors upstream `codex_rs/sandboxing/src/seatbelt.rs` in spirit.
    static func buildSeatbeltProfile(policy: SandboxPolicy, cwd: String) -> String {
        var lines = ["(version 1)", "(deny default)",
                     "(allow process-fork)", "(allow process-exec)",
                     "(allow file-read*)"]
        if policy.mode == .workspaceWrite || policy.mode == .dangerFullAccess {
            // Deduplicate writable roots after canonicalisation so we don't
            // emit redundant deny clauses for cwd ⊆ writableRoots.
            var seenRoots = Set<String>()
            var orderedRoots: [String] = []
            for r in policy.writableRoots {
                let canonical = canonicalPath(r)
                if seenRoots.insert(canonical).inserted {
                    orderedRoots.append(canonical)
                }
                lines.append("(allow file-write* (subpath \(sbplStringLiteral(canonical))))")
            }
            let canonicalCwd = canonicalPath(cwd)
            if seenRoots.insert(canonicalCwd).inserted {
                orderedRoots.append(canonicalCwd)
            }
            lines.append("(allow file-write* (subpath \(sbplStringLiteral(canonicalCwd))))")

            // Parity H-23: even inside a writable root, the top-level
            // `.git`, `.codex`, and `.agents` directories must remain
            // unwritable. Upstream encodes this via `(require-not (regex …))`
            // attached to each writable allow clause. We emit equivalent
            // explicit `(deny file-write* (regex …))` rules — Seatbelt's deny
            // wins on conflict so the effective policy is identical.
            //
            // Without these rules a workspace-write sandbox could be used to
            // install a `.git/hooks/pre-commit` shim and escalate the next
            // time the user (or another sandboxed process) runs `git commit`,
            // or to rewrite `.codex/config.toml` to disable the sandbox for
            // future invocations.
            if policy.mode == .workspaceWrite {
                for root in orderedRoots {
                    for name in protectedMetadataNames {
                        let regex = protectedMetadataRegex(root: root, name: name)
                        let payload = sbplRegexLiteral(regex)
                        // Use SBPL's "sharp string" literal — opener `#"`,
                        // close with a plain `"`. Backslashes inside are
                        // passed to the regex engine unmodified. (Closing
                        // with `"#` is rejected by sandbox-exec as an
                        // "undefined sharp expression".) Matches upstream
                        // `codex_rs/sandboxing/src/seatbelt.rs`:
                        // `format!(r#"(require-not (regex #"{regex}"))"#)`
                        // which interpolates inside `#"..."` (single `"`
                        // close); the outer `r#"..."#` is just Rust raw
                        // string syntax.
                        lines.append("(deny file-write* (regex #\"\(payload)\"))")
                    }
                }
            }
        }
        if policy.networkAllowed { lines.append("(allow network*)") }
        return lines.joined(separator: "\n")
    }

    /// macOS Seatbelt profile (SBPL). This is the real profile text Codex's
    /// `sandboxing/seatbelt.rs` emits in spirit; applying it to the child is
    /// the platform-completion step.
    public func confinementProfile(cwd: String) -> String? {
        #if os(macOS)
        return Self.buildSeatbeltProfile(policy: policy, cwd: cwd)
        #else
        return nil
        #endif
    }

    /// Build the bwrap argv for a given policy. Exposed as a static helper so
    /// the Linux-only sandbox wrapping can be unit-tested cross-platform.
    /// Mirrors upstream's bwrap argument construction in
    /// `codex_rs/linux-sandbox/src/bwrap.rs`.
    static func buildBwrapArgv(bwrap: String,
                               policy: SandboxPolicy,
                               argv: [String],
                               cwd: String) -> [String] {
        // Parity H-23 (audit F-3): `/tmp` must NOT be writable in read-only
        // mode. Previously `--tmpfs /tmp` was emitted unconditionally, which
        // provided a writable mount even when the policy was `readOnly` — a
        // sandbox-escape path. In `readOnly` mode we deliberately omit the
        // tmpfs and let `/tmp` be covered by the read-only `--ro-bind / /`
        // mount above.
        var a = [bwrap, "--die-with-parent", "--unshare-pid",
                 "--ro-bind", "/", "/",
                 "--dev", "/dev", "--proc", "/proc"]
        if policy.mode == .workspaceWrite {
            a += ["--tmpfs", "/tmp"]
            for r in policy.writableRoots { a += ["--bind", r, r] }
            a += ["--bind", cwd, cwd]

            // Parity H-23: even inside the writable bind, the top-level
            // `.git`, `.codex`, and `.agents` directories must remain
            // unwritable. Layering an empty, read-only tmpfs over each
            // protected subtree makes the path appear as an empty in-memory
            // mount that the sandboxed process cannot write to even
            // ephemerally — without the `--perms 555 --remount-ro` flags the
            // tmpfs defaults to 0755 and allows intra-session hook injection
            // (e.g. writing `<cwd>/.git/hooks/pre-commit` and triggering it
            // via `git commit` later in the same sandbox session). Mirrors
            // upstream's `append_empty_directory_args` in
            // `codex_rs/linux-sandbox/src/bwrap.rs`, which emits exactly:
            //   --perms 555 --tmpfs <path> --remount-ro <path>
            var seen = Set<String>()
            for root in policy.writableRoots + [cwd] {
                if !seen.insert(root).inserted { continue }
                for name in protectedMetadataNames {
                    let path = root.hasSuffix("/") ? root + name : root + "/" + name
                    a += ["--perms", "555", "--tmpfs", path, "--remount-ro", path]
                }
            }
        }
        if !policy.networkAllowed { a += ["--unshare-net"] }
        a += ["--chdir", cwd, "--"]
        a += argv
        return a
    }

    public func sandboxedInvocation(argv: [String], cwd: String) -> SandboxInvocation {
        guard !argv.isEmpty else { return .deny("empty command") }
        if policy.mode == .dangerFullAccess { return .run(argv) }

        let backend = backendResolver.resolve()
        #if os(macOS)
        switch backend {
        case .sandboxExec(let sandboxExec):
            guard let profile = confinementProfile(cwd: cwd) else {
                return .deny("macOS Seatbelt profile unavailable; refusing to run unsandboxed under \(policy.mode.rawValue) policy")
            }
            return .run([sandboxExec, "-p", profile] + argv)
        case .unavailable(let reason):
            return .deny(reason + " under \(policy.mode.rawValue) policy")
        case .bubblewrap:
            return .deny("Linux bubblewrap backend is not valid on macOS; refusing to run unsandboxed under \(policy.mode.rawValue) policy")
        }
        #else
        switch backend {
        case .bubblewrap(let bwrap):
            return .run(Self.buildBwrapArgv(bwrap: bwrap, policy: policy, argv: argv, cwd: cwd))
        case .unavailable(let reason):
            return .deny(reason + " under \(policy.mode.rawValue) policy")
        case .sandboxExec:
            return .deny("macOS sandbox-exec backend is not valid on this platform; refusing to run unsandboxed under \(policy.mode.rawValue) policy")
        }
        #endif
    }
}
