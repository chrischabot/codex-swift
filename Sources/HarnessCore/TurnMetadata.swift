import Foundation
import ProtocolModel
import Sandbox
import Tools

/// Faithful port of upstream `core/src/turn_metadata.rs` + `core/src/sandbox_tags.rs`.
///
/// Builds the per-turn `x-codex-turn-metadata` request header value that every
/// Responses API request (REST + WebSocket + curl) carries. The header is a
/// JSON object holding the session id, thread id, optional thread source, turn
/// id, the permission-profile sandbox tag, and asynchronously-enriched git
/// workspace metadata (repo root → { associated_remote_urls, latest commit,
/// has_changes }). The JSON is ASCII-only (upstream `to_ascii_json_string`):
/// every non-ASCII scalar is emitted as a `\uXXXX` escape so the value is a
/// valid HTTP header.
///
/// Field ordering and `skip_serializing_if` semantics mirror the upstream serde
/// structs verbatim:
///   TurnMetadataBag = { session_id?, thread_id?, thread_source?, turn_id?,
///                       workspaces (omitted when empty), sandbox? }
///   TurnMetadataWorkspace = { associated_remote_urls?, latest_git_commit_hash?,
///                             has_changes? }
/// `workspaces` is a BTreeMap keyed by repo root → sorted by key.
/// `associated_remote_urls` is a BTreeMap keyed by remote name → raw fetch URL.

// MARK: - Sandbox tag (sandbox_tags.rs::permission_profile_sandbox_tag)

public enum TurnMetadataSandboxTag {
    /// Returns the platform metric tag for a backend that confines child
    /// processes on the current platform. Mirrors upstream
    /// `SandboxType::as_metric_tag` for the platform sandbox that
    /// `get_platform_sandbox` selects: "seatbelt" on macOS (sandbox-exec),
    /// "seccomp" on Linux (bubblewrap/landlock). Returns `nil` when no platform
    /// sandbox backend is available (→ "none").
    static func platformTag(resolver: SandboxBackendResolver) -> String? {
        switch resolver.resolve() {
        case .sandboxExec:
            return "seatbelt"
        case .bubblewrap:
            return "seccomp"
        case .unavailable:
            return nil
        }
    }

    /// Faithful port of `permission_profile_sandbox_tag`
    /// (`core/src/sandbox_tags.rs:8-38`).
    ///
    /// - `dangerFullAccess` (PermissionProfile::Disabled) → "none".
    /// - `readOnly` / `workspaceWrite` (Managed): if a platform sandbox is
    ///   required and available, the platform metric tag; otherwise "none".
    ///   The Swift port always requires a platform sandbox for non-full-access
    ///   modes (a non-full-access spawn that cannot be confined is denied), so
    ///   the tag is the platform tag when a backend exists, else "none".
    public static func tag(mode: SandboxModeKind,
                           resolver: SandboxBackendResolver = SandboxBackendResolver())
        -> String {
        switch mode {
        case .dangerFullAccess:
            return "none"
        case .readOnly, .workspaceWrite:
            return platformTag(resolver: resolver) ?? "none"
        }
    }
}

// MARK: - Workspace git metadata

struct WorkspaceGitMetadata: Sendable, Equatable {
    /// remote name → raw fetch URL (BTreeMap → sorted on serialization).
    var associatedRemoteURLs: [String: String]?
    var latestGitCommitHash: String?
    var hasChanges: Bool?

    var isEmpty: Bool {
        associatedRemoteURLs == nil && latestGitCommitHash == nil && hasChanges == nil
    }
}

// MARK: - ASCII JSON emission (utils/string::to_ascii_json_string)

enum TurnMetadataJSON {
    /// Append an ASCII-escaped JSON string literal (upstream
    /// `AsciiJsonFormatter`: every non-ASCII scalar becomes `\uXXXX`, with
    /// surrogate pairs for scalars above U+FFFF, matching serde_json).
    static func appendString(_ s: String, to out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                let v = scalar.value
                if v < 0x20 {
                    out.append(String(format: "\\u%04x", v))
                } else if v < 0x80 {
                    out.unicodeScalars.append(scalar)
                } else if v <= 0xFFFF {
                    out.append(String(format: "\\u%04x", v))
                } else {
                    // Surrogate pair for astral-plane scalars.
                    let c = v - 0x1_0000
                    let hi = 0xD800 + (c >> 10)
                    let lo = 0xDC00 + (c & 0x3FF)
                    out.append(String(format: "\\u%04x\\u%04x", hi, lo))
                }
            }
        }
        out.append("\"")
    }

    static func stringLiteral(_ s: String) -> String {
        var out = ""
        appendString(s, to: &out)
        return out
    }
}

// MARK: - TurnMetadataBag (turn_metadata.rs::TurnMetadataBag)

struct TurnMetadataBag: Sendable, Equatable {
    var sessionId: String?
    var threadId: String?
    var threadSource: String?
    var turnId: String?
    /// repo root → workspace git metadata (BTreeMap → sorted keys).
    var workspaces: [String: WorkspaceGitMetadata]
    var sandbox: String?

    /// Serialize to the ASCII JSON header value, honouring upstream serde field
    /// order and `skip_serializing_if`. Returns `nil` only on impossible
    /// encoding failure (matches `to_header_value` → `Option`).
    func toHeaderValue() -> String? {
        var parts: [String] = []
        func add(_ key: String, _ valueLiteral: String) {
            parts.append("\(TurnMetadataJSON.stringLiteral(key)):\(valueLiteral)")
        }
        if let v = sessionId { add("session_id", TurnMetadataJSON.stringLiteral(v)) }
        if let v = threadId { add("thread_id", TurnMetadataJSON.stringLiteral(v)) }
        if let v = threadSource { add("thread_source", TurnMetadataJSON.stringLiteral(v)) }
        if let v = turnId { add("turn_id", TurnMetadataJSON.stringLiteral(v)) }
        if !workspaces.isEmpty {
            var wsParts: [String] = []
            for root in workspaces.keys.sorted() {
                guard let ws = workspaces[root] else { continue }
                wsParts.append("\(TurnMetadataJSON.stringLiteral(root)):\(Self.encodeWorkspace(ws))")
            }
            add("workspaces", "{\(wsParts.joined(separator: ","))}")
        }
        if let v = sandbox { add("sandbox", TurnMetadataJSON.stringLiteral(v)) }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func encodeWorkspace(_ ws: WorkspaceGitMetadata) -> String {
        var parts: [String] = []
        if let urls = ws.associatedRemoteURLs {
            var urlParts: [String] = []
            for name in urls.keys.sorted() {
                guard let u = urls[name] else { continue }
                urlParts.append("\(TurnMetadataJSON.stringLiteral(name)):\(TurnMetadataJSON.stringLiteral(u))")
            }
            parts.append("\(TurnMetadataJSON.stringLiteral("associated_remote_urls")):{\(urlParts.joined(separator: ","))}")
        }
        if let h = ws.latestGitCommitHash {
            parts.append("\(TurnMetadataJSON.stringLiteral("latest_git_commit_hash")):\(TurnMetadataJSON.stringLiteral(h))")
        }
        if let c = ws.hasChanges {
            parts.append("\(TurnMetadataJSON.stringLiteral("has_changes")):\(c ? "true" : "false")")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}

func buildTurnMetadataBag(sessionId: String?,
                          threadId: String?,
                          threadSource: String?,
                          turnId: String?,
                          sandbox: String?,
                          repoRoot: String?,
                          workspaceGitMetadata: WorkspaceGitMetadata?) -> TurnMetadataBag {
    var workspaces: [String: WorkspaceGitMetadata] = [:]
    if let repoRoot, let ws = workspaceGitMetadata, !ws.isEmpty {
        workspaces[repoRoot] = ws
    }
    return TurnMetadataBag(sessionId: sessionId,
                           threadId: threadId,
                           threadSource: threadSource,
                           turnId: turnId,
                           workspaces: workspaces,
                           sandbox: sandbox)
}

// MARK: - Free-function header builder (turn_metadata.rs::build_turn_metadata_header)

/// Faithful port of `build_turn_metadata_header` (`turn_metadata.rs:147-181`):
/// build a header carrying only the (optional) sandbox tag plus async git
/// enrichment of the cwd's repo. Returns `nil` when there is no git metadata and
/// no sandbox tag (matches upstream's early-return).
public func buildTurnMetadataHeader(cwd: String, sandbox: String?) async -> String? {
    let git = GitUtils(cwd: cwd)
    let repoRoot = await git.repoRoot()
    async let head = git.headSha()
    async let remotes = git.rawRemoteURLMap()
    async let changes = git.hasChanges()
    let latestGitCommitHash = await head
    let associatedRemoteURLs = await remotes
    let hasChanges = await changes
    if latestGitCommitHash == nil
        && associatedRemoteURLs == nil
        && hasChanges == nil
        && sandbox == nil {
        return nil
    }
    return buildTurnMetadataBag(
        sessionId: nil,
        threadId: nil,
        threadSource: nil,
        turnId: nil,
        sandbox: sandbox,
        repoRoot: repoRoot,
        workspaceGitMetadata: WorkspaceGitMetadata(
            associatedRemoteURLs: associatedRemoteURLs,
            latestGitCommitHash: latestGitCommitHash,
            hasChanges: hasChanges)
    ).toHeaderValue()
}

// MARK: - TurnMetadataState (turn_metadata.rs::TurnMetadataState)

/// Per-turn metadata holder. Constructed once per turn with the session/thread/
/// turn ids and the sandbox tag (the base header), then optionally enriched with
/// git workspace metadata fetched off the hot path. `currentHeaderValue()`
/// returns the enriched header if enrichment has completed, otherwise the base
/// header — always a non-nil header (the base header always carries at least the
/// ids + sandbox tag).
public actor TurnMetadataState {
    private let cwd: String
    private let baseMetadata: TurnMetadataBag
    private let baseHeader: String
    private var enrichedHeader: String?
    private var enrichmentTask: Task<Void, Never>?

    public init(sessionId: String,
                threadId: String,
                threadSource: String?,
                turnId: String,
                cwd: String,
                sandboxMode: SandboxModeKind,
                resolver: SandboxBackendResolver = SandboxBackendResolver()) {
        self.cwd = cwd
        let sandbox = TurnMetadataSandboxTag.tag(mode: sandboxMode, resolver: resolver)
        let bag = buildTurnMetadataBag(
            sessionId: sessionId,
            threadId: threadId,
            threadSource: threadSource,
            turnId: turnId,
            sandbox: sandbox,
            repoRoot: nil,
            workspaceGitMetadata: nil)
        self.baseMetadata = bag
        self.baseHeader = bag.toHeaderValue() ?? "{}"
    }

    /// Returns the current header value: the enriched header once git
    /// enrichment has completed, else the base header. Never `nil`.
    public func currentHeaderValue() -> String? {
        enrichedHeader ?? baseHeader
    }

    /// Kick off the async git enrichment task (idempotent — second call is a
    /// no-op while a task is in flight). Mirrors upstream
    /// `spawn_git_enrichment_task`.
    public func spawnGitEnrichmentTask() {
        guard enrichmentTask == nil else { return }
        enrichmentTask = Task { [cwd, baseMetadata] in
            let git = GitUtils(cwd: cwd)
            guard let root = await git.repoRoot() else { return }
            async let head = git.headSha()
            async let remotes = git.rawRemoteURLMap()
            async let changes = git.hasChanges()
            let ws = WorkspaceGitMetadata(
                associatedRemoteURLs: await remotes,
                latestGitCommitHash: await head,
                hasChanges: await changes)
            let enriched = buildTurnMetadataBag(
                sessionId: baseMetadata.sessionId,
                threadId: baseMetadata.threadId,
                threadSource: baseMetadata.threadSource,
                turnId: baseMetadata.turnId,
                sandbox: baseMetadata.sandbox,
                repoRoot: root,
                workspaceGitMetadata: ws)
            if enriched.workspaces.isEmpty { return }
            if let header = enriched.toHeaderValue() {
                await self.setEnrichedHeader(header)
            }
        }
    }

    /// Cancel an in-flight enrichment task (mirrors `cancel_git_enrichment_task`).
    public func cancelGitEnrichmentTask() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
    }

    private func setEnrichedHeader(_ header: String) {
        enrichedHeader = header
    }
}
