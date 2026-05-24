import Foundation

/// Canonical Codex execpolicy rules file persistence (`$CODEX_HOME/rules/default.rules`).
///
/// Upstream (`codex_execpolicy::blocking_append_allow_prefix_rule` /
/// `blocking_append_network_rule`) writes new `prefix_rule` and `network_rule`
/// lines to this file when the user opts to permanently allow a command prefix
/// or a per-host network access. The Swift implementation must emit the same
/// textual format so approvals made by codex-swift are visible to the Rust
/// codex CLI (and vice versa).
///
/// File format (line-oriented, comment-stripped — see `ExecPolicy.parseRules`):
///
/// ```
/// prefix_rule(pattern=["git", "status"], decision="allow")
/// network_rule(host="api.github.com", protocol="https", decision="allow", justification="…")
/// ```
///
/// Each token of the prefix array is JSON-encoded (so embedded quotes/backslashes
/// round-trip safely). Hosts are normalised (lower-case, no scheme, no path,
/// no wildcards) before being serialised. Duplicate lines are deduplicated.
public enum RulesStore {
    public static let defaultFileName = "default.rules"
    public static let defaultDirName = "rules"

    /// Canonical path for the per-user rules file. Mirrors upstream's
    /// `~/.codex/rules/default.rules`.
    public static func defaultPath(codexHome: String) -> String {
        codexHome + "/" + defaultDirName + "/" + defaultFileName
    }

    /// Append a `prefix_rule(pattern=[...], decision="allow")` line if one
    /// matching this prefix is not already present.
    /// Equivalent to upstream `blocking_append_allow_prefix_rule`.
    @discardableResult
    public static func appendAllowPrefixRule(
        codexHome: String, prefix: [String]
    ) throws -> Bool {
        guard !prefix.isEmpty else { throw RulesStoreError.emptyPrefix }
        let tokens = try prefix.map(jsonEncodeString)
        let pattern = "[" + tokens.joined(separator: ", ") + "]"
        let line = "prefix_rule(pattern=\(pattern), decision=\"allow\")"
        return try appendLine(line, to: defaultPath(codexHome: codexHome))
    }

    /// Append a `network_rule(host=…, protocol=…, decision=…[, justification=…])`
    /// line. Equivalent to upstream `blocking_append_network_rule`.
    @discardableResult
    public static func appendNetworkRule(
        codexHome: String,
        host rawHost: String,
        proto: ExecPolicy.NetworkProtocol,
        decision: ExecDecision,
        justification: String? = nil
    ) throws -> Bool {
        let host = try normalizeNetworkHost(rawHost)
        if let j = justification,
           j.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RulesStoreError.invalidNetworkRule(
                "justification cannot be empty")
        }
        let decisionString: String
        switch decision {
        case .safe: decisionString = "allow"
        case .needsApproval: decisionString = "prompt"
        case .forbidden: decisionString = "deny"
        }
        let protoString = policyProtocolString(proto)
        var parts = [
            "host=" + (try jsonEncodeString(host)),
            "protocol=" + (try jsonEncodeString(protoString)),
            "decision=" + (try jsonEncodeString(decisionString)),
        ]
        if let j = justification {
            parts.append("justification=" + (try jsonEncodeString(j)))
        }
        let line = "network_rule(\(parts.joined(separator: ", ")))"
        return try appendLine(line, to: defaultPath(codexHome: codexHome))
    }

    // MARK: - Internals

    private static func policyProtocolString(_ p: ExecPolicy.NetworkProtocol) -> String {
        switch p {
        case .http: return "http"
        case .https: return "https"
        case .socks5Tcp: return "socks5_tcp"
        case .socks5Udp: return "socks5_udp"
        }
    }

    /// Append `line` to `path`, creating the parent directory and the file if
    /// needed. Returns `true` if a new line was appended, `false` if the exact
    /// same line was already present (idempotent — matches upstream behaviour).
    ///
    /// P4.2 / TOCTOU parity: takes an exclusive advisory file lock
    /// (`flock(LOCK_EX)`) for the duration of the read-then-write. Matches
    /// upstream `append_locked_line` in
    /// `codex-rs/execpolicy/src/amend.rs::append_locked_line` (which calls
    /// `file.lock()` — Rust's `LOCK_EX`). Without the lock a concurrent
    /// writer or reader could observe a partially-updated file even though
    /// the previous Swift implementation used `atomic: true` (rename), because
    /// readers can still race the rename and another writer could lose a
    /// concurrent append.
    @discardableResult
    static func appendLine(_ line: String, to path: String) throws -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        return try FileLock.withExclusiveLock(path: path) { fd in
            // Read existing contents under the lock (read-then-write must be
            // atomic w.r.t. other appenders).
            try seekToStart(fd, path: path)
            let existing = try readAll(fd, path: path)

            if existing.split(omittingEmptySubsequences: false, whereSeparator: {
                $0 == "\n"
            }).contains(where: { $0 == Substring(line) }) {
                return false
            }
            // Position at end-of-file before appending. We can't trust the
            // descriptor's current offset (we just seek'd to 0 to read).
            try seekToEnd(fd, path: path)
            if !existing.isEmpty, !existing.hasSuffix("\n") {
                try writeBytes(fd, bytes: Array("\n".utf8), path: path)
            }
            var bytes = Array(line.utf8)
            bytes.append(0x0A) // '\n'
            try writeBytes(fd, bytes: bytes, path: path)
            return true
        }
    }

    /// Read the rules file under a shared advisory lock (`flock(LOCK_SH)`).
    /// Mirrors upstream's reader-side use of `file.lock()` so a concurrent
    /// writer cannot race a reader between open and read-to-end. Returns the
    /// empty string when the file does not exist (matching the previous
    /// `String(contentsOfFile:)` fall-back semantics).
    public static func readLocked(path: String) throws -> String {
        if !FileManager.default.fileExists(atPath: path) {
            return ""
        }
        return try FileLock.withSharedLock(path: path) { fd in
            try seekToStart(fd, path: path)
            return try readAll(fd, path: path)
        }
    }

    // MARK: - File descriptor helpers (POSIX wrappers used under flock)

    private static func seekToStart(_ fd: Int32, path: String) throws {
        if lseek(fd, 0, SEEK_SET) < 0 {
            throw RulesStoreError.invalidNetworkRule(
                "failed to seek \(path): \(String(cString: strerror(errno)))")
        }
    }

    private static func seekToEnd(_ fd: Int32, path: String) throws {
        if lseek(fd, 0, SEEK_END) < 0 {
            throw RulesStoreError.invalidNetworkRule(
                "failed to seek-end \(path): \(String(cString: strerror(errno)))")
        }
    }

    private static func readAll(_ fd: Int32, path: String) throws -> String {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw RulesStoreError.invalidNetworkRule(
                    "failed to read \(path): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            out.append(contentsOf: buf.prefix(n))
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    private static func writeBytes(_ fd: Int32, bytes: [UInt8], path: String) throws {
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBufferPointer { ptr -> Int in
                write(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw RulesStoreError.invalidNetworkRule(
                    "failed to write \(path): \(String(cString: strerror(errno)))")
            }
            remaining = remaining.dropFirst(n)
        }
    }

    /// JSON-encode a string the way upstream `serde_json::to_string(&str)` does
    /// (so the rules file round-trips byte-for-byte with the Rust writer).
    private static func jsonEncodeString(_ s: String) throws -> String {
        // `JSONSerialization` requires a top-level container; serialise a
        // one-element array and slice off the brackets so we keep the standard
        // double-quoted form with full escaping.
        let data = try JSONSerialization.data(
            withJSONObject: [s], options: [.withoutEscapingSlashes])
        guard let raw = String(data: data, encoding: .utf8),
              raw.hasPrefix("["), raw.hasSuffix("]") else {
            throw RulesStoreError.serializationFailed
        }
        // Drop the surrounding brackets to recover the encoded scalar.
        return String(raw.dropFirst().dropLast())
    }

    /// Normalise a host the way upstream `normalize_network_rule_host` does:
    /// lower-case, strip surrounding whitespace and trailing dots, reject
    /// wildcards / schemes / paths. Shares semantics with
    /// `ExecPolicy.normalizeNetworkHost` (kept local so the storage layer does
    /// not depend on `ExecPolicy` internals).
    private static func normalizeNetworkHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw RulesStoreError.invalidNetworkRule("host cannot be empty")
        }
        guard !host.contains("://"), !host.contains("/"),
              !host.contains("?"), !host.contains("#") else {
            throw RulesStoreError.invalidNetworkRule(
                "host must be a hostname or IP literal (no scheme or path)")
        }
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else {
                throw RulesStoreError.invalidNetworkRule(
                    "invalid bracketed IPv6 literal")
            }
            let inside = String(host[host.index(after: host.startIndex)..<end])
            let rest = String(host[host.index(after: end)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":"),
                      rest.dropFirst().allSatisfy(\.isNumber),
                      !rest.dropFirst().isEmpty else {
                    throw RulesStoreError.invalidNetworkRule(
                        "unsupported suffix on bracketed IPv6 literal: \(raw)")
                }
            }
            host = inside
        } else if host.filter({ $0 == ":" }).count == 1,
                  let split = host.lastIndex(of: ":") {
            let candidate = String(host[..<split])
            let port = host[host.index(after: split)...]
            if !candidate.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) {
                host = candidate
            }
        }
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw RulesStoreError.invalidNetworkRule("host cannot be empty")
        }
        guard !normalized.contains("*") else {
            throw RulesStoreError.invalidNetworkRule(
                "host must be a specific host; wildcards are not allowed")
        }
        guard !normalized.contains(where: \.isWhitespace) else {
            throw RulesStoreError.invalidNetworkRule(
                "host cannot contain whitespace")
        }
        return normalized
    }
}

/// Errors raised while amending `default.rules`. Mirrors the upstream
/// `AmendError` variants in `codex_execpolicy::amend`.
public enum RulesStoreError: Error, LocalizedError, Equatable {
    case emptyPrefix
    case invalidNetworkRule(String)
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPrefix:
            return "prefix rule requires at least one token"
        case .invalidNetworkRule(let why):
            return "invalid network rule: \(why)"
        case .serializationFailed:
            return "failed to serialise rule literal"
        }
    }
}
