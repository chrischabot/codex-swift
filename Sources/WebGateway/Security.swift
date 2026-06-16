import Foundation
import Hummingbird
import HTTPTypes

/// Deny-default allowlist of the client→server JSON-RPC methods the web UI is
/// permitted to call. Everything else is rejected BEFORE dispatch.
///
/// This is defense-in-depth: it removes the privileged control-plane RPCs
/// (direct exec, process spawn, fs writes/removes, account login/logout,
/// remote-control enable, environment mutation, config writes, MCP/plugin
/// installs, feedback) from the gateway's reachable surface. Agent tool use
/// still happens inside worker processes under the sandbox + approvals; the
/// gate constrains what a browser can *ask the daemon* to do directly.
///
/// IMPORTANT: this is an explicit method-name allowlist. It is NOT derived from
/// `parallelSafe`/`isReadOnly` (those are not authorization boundaries — a
/// "read" RPC can still be effectful).
enum MethodGate {
    /// Methods the diminuendo UI (connector-codex.ts) needs. Keep in sync with
    /// the connector. Add new entries deliberately, never by relaxing to a
    /// prefix/wildcard.
    static let allowed: Set<String> = [
        "initialize",
        // thread lifecycle / read
        "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list",
        "thread/start", "thread/resume", "thread/fork",
        "thread/name/set", "thread/pin/set", "thread/archive", "thread/unarchive",
        "thread/unsubscribe", "thread/compact/start",
        // thread context / goals / memory
        "thread/rollback", "thread/inject_items", "thread/shellCommand",
        "thread/goal/get", "thread/goal/set", "thread/goal/clear",
        "thread/memoryMode/set", "memory/reset",
        // memory wiki — browse/search/graph + page edit/delete. upsert+delete are
        // the edit surface (the wiki UI is the management/edit environment); both
        // stay deny-default behind the CODEXKIT_MEMORY-gated WikiQueryHandle.
        "wiki/list", "wiki/page/get", "wiki/search", "wiki/graph", "wiki/backlinks", "wiki/entityBacklinks", "wiki/tags", "wiki/index",
        "wiki/page/upsert", "wiki/page/delete", "wiki/page/rename", "wiki/brief", "wiki/query", "wiki/status", "wiki/watch/list",
        // Trust reports — pure-local reads (Tier-1 staleness / Pass-2 drift), no spend/egress.
        "wiki/librarian/report", "wiki/audit/report",
        // Curation reads — compact-table projections (inventory/datasets/collect), no spend/egress.
        "wiki/inventory/list", "wiki/dataset/list", "wiki/collect/list",
        // Research-session history — read-only projection of research_session rows.
        "wiki/sessions/list",
        "wiki/research/start", "wiki/ingest/start",
        // turn lifecycle
        "turn/start", "turn/steer", "turn/interrupt", "review/start",
        // git diff-rail + automations
        "git/action", "automation/action",
        // realtime voice
        "thread/realtime/listVoices", "thread/realtime/start",
        "thread/realtime/appendText", "thread/realtime/appendAudio", "thread/realtime/stop",
        // catalogs / config / account (Settings + pickers)
        "model/list", "modelProvider/capabilities/read",
        "config/read", "config/value/write", "config/batchWrite", "config/mcpServer/reload",
        "account/read", "account/rateLimits/read",
        "experimentalFeature/list", "experimentalFeature/enablement/set",
        "configRequirements/read",
        // extensions surface (Plugins / MCP / Skills / Hooks / Apps / mentions)
        "skills/list", "mcpServerStatus/list", "hooks/list",
        "collaborationMode/list", "app/list",
        "plugin/list", "plugin/installed", "plugin/read", "plugin/install", "plugin/uninstall",
        "marketplace/add",
        "fuzzyFileSearch", "fuzzyFileSearch/sessionStart", "fuzzyFileSearch/sessionUpdate", "fuzzyFileSearch/sessionStop",
        // remote control + environments (Settings)
        "remoteControl/status/read", "remoteControl/enable", "remoteControl/disable",
        "environment/add",
    ]

    /// Tier-B: strongly-mutating / effectful RPCs that need MORE than the shared read
    /// bearer — an owner-identity credential. Every entry is ALSO in `allowed` (Tier-B is a
    /// strict gate layered on Tier-A); `requiresOwner` is consulted only AFTER `isAllowed`
    /// passes. wiki/research|ingest start a live PAID extraction lane; config writes mutate
    /// config.toml; remoteControl/environment/plugin reshape the control plane. Keep in
    /// sync deliberately — never relax to a prefix.
    static let ownerTier: Set<String> = [
        // Threads: create/resume/fork spawn paid turns; metadata mutations; compaction
        // spends; rollback/inject mutate history; shellCommand runs an UNSANDBOXED
        // full-access shell (RCE — the single most dangerous entry).
        "thread/start", "thread/resume", "thread/fork",
        "thread/name/set", "thread/pin/set", "thread/archive", "thread/unarchive",
        "thread/unsubscribe", "thread/compact/start",
        "thread/rollback", "thread/inject_items", "thread/shellCommand",
        "thread/goal/set", "thread/goal/clear", "thread/memoryMode/set", "memory/reset",
        // Turns: paid model turns + their control verbs; review/start spends too.
        "turn/start", "turn/steer", "turn/interrupt", "review/start",
        // git diff-rail (push/pr/revert = destructive) + scheduled automations (deferred spend).
        "git/action", "automation/action",
        // Realtime voice session (paid); listVoices is a read and stays Tier-A.
        "thread/realtime/start", "thread/realtime/appendText",
        "thread/realtime/appendAudio", "thread/realtime/stop",
        // Wiki write surface + PAID extraction lanes. wiki/query spends too: at
        // depth>=2 it drives MemoryRetriever.search → a billable embedding (and a
        // rerank at depth 3) for every distinct query when the store's embedder is
        // remote, so a read bearer could otherwise run up unbounded API cost.
        // (wiki/brief stays Tier-A: it is lexical-only/BM25 — "Local only; no cloud spend".)
        "wiki/page/upsert", "wiki/page/delete", "wiki/page/rename",
        "wiki/research/start", "wiki/ingest/start", "wiki/query",
        // Daemon config mutation + feature-flag flips.
        "config/value/write", "config/batchWrite", "config/mcpServer/reload",
        "experimentalFeature/enablement/set",
        // Control plane: remote control, environment enrollment, plugin/marketplace install.
        "remoteControl/enable", "remoteControl/disable",
        "environment/add", "plugin/install", "plugin/uninstall", "marketplace/add",
    ]
    static func requiresOwner(_ method: String) -> Bool { ownerTier.contains(method) }

    static func isAllowed(_ method: String) -> Bool { allowed.contains(method) }

    /// The pure-READ subset of `allowed` (list/get/read/search/status — no spend, no
    /// mutation, no control-plane change). The coverage test asserts every non-read
    /// allowed method is in `ownerTier`, so adding an effectful method to `allowed`
    /// without owner-gating it fails CI. Exposed for that test only.
    static let pureReads: Set<String> = [
        "initialize",
        "thread/list", "thread/loaded/list", "thread/read",
        "thread/turns/list", "thread/turns/items/list", "thread/goal/get",
        "wiki/list", "wiki/page/get", "wiki/search", "wiki/graph", "wiki/backlinks",
        "wiki/entityBacklinks", "wiki/tags", "wiki/index", "wiki/brief",
        "wiki/status", "wiki/watch/list", "wiki/librarian/report", "wiki/audit/report",
        "wiki/inventory/list", "wiki/dataset/list", "wiki/collect/list", "wiki/sessions/list",
        "thread/realtime/listVoices",
        "model/list", "modelProvider/capabilities/read", "config/read",
        "account/read", "account/rateLimits/read", "experimentalFeature/list",
        "configRequirements/read", "skills/list", "mcpServerStatus/list", "hooks/list",
        "collaborationMode/list", "app/list",
        "plugin/list", "plugin/installed", "plugin/read",
        "fuzzyFileSearch", "fuzzyFileSearch/sessionStart", "fuzzyFileSearch/sessionUpdate",
        "fuzzyFileSearch/sessionStop", "remoteControl/status/read",
    ]
}

/// Runtime security policy for a gateway listener, derived from config.
public struct SecurityPolicy: Sendable {
    /// Enforce the deny-default method allowlist on inbound requests.
    public var enforceMethodAllowlist: Bool
    /// Require a valid bearer token on WS upgrade + `/api`. Auto-true for any
    /// non-loopback bind.
    public var requireAuth: Bool
    /// Per-launch (or configured) bearer token.
    public var bearerToken: String?
    /// Exact-match allowed `Origin` values. Empty = loopback origins only.
    public var allowedOrigins: Set<String>
    /// Owner/write-tier credential — a SEPARATE secret from the read bearer. nil → the
    /// owner tier is unreachable (fail-closed). Set via property assignment after
    /// construction (no init param — ABI-safe under concurrent incremental builds).
    public var ownerToken: String? = nil
    /// When true (default), Tier-B (mutating/effectful) methods require `ownerAccepted`.
    public var enforceOwnerTier: Bool = true

    public init(enforceMethodAllowlist: Bool = true,
                requireAuth: Bool = false,
                bearerToken: String? = nil,
                allowedOrigins: Set<String> = []) {
        self.enforceMethodAllowlist = enforceMethodAllowlist
        self.requireAuth = requireAuth
        self.bearerToken = bearerToken
        self.allowedOrigins = allowedOrigins
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Parse an Origin/URL string's host, REJECTING any userinfo. `URL.host`
    /// (and `URLComponents.host`) return the host AFTER `user:pass@`, so
    /// `http://evil.com@127.0.0.1` would otherwise parse to host `127.0.0.1`
    /// and pass a loopback check — a full WS-hijack bypass. We reject userinfo
    /// outright and never trust a bare host parse for an authz decision.
    static func safeHost(_ value: String) -> String? {
        guard !value.contains("@") else { return nil }
        guard let c = URLComponents(string: value),
              c.user == nil, c.password == nil,
              let host = c.host, !host.isEmpty else { return nil }
        return host
    }

    /// Browsers ALWAYS send `Origin` on a WS handshake. Reject cross-origin.
    /// Empty allowlist = accept only loopback origins. A missing/empty Origin
    /// is accepted ONLY for loopback dev (`!requireAuth`); on an auth-required
    /// bind a missing Origin must fall through to the bearer gate, not auto-pass.
    public func originAllowed(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return !requireAuth }
        guard let host = Self.safeHost(origin) else { return false }
        if !allowedOrigins.isEmpty {
            if allowedOrigins.contains(origin) { return true }
            let allowedHosts = Set(allowedOrigins.compactMap { Self.safeHost($0) })
            return allowedHosts.contains(host)
        }
        return Self.loopbackHosts.contains(host)
    }

    /// Validate the `Host` header to defeat DNS-rebinding: an attacker domain
    /// that an operator added to `allowedOrigins` can be rebound to the victim
    /// IP — Origin matches but Host would not. Require Host's hostname to match
    /// the bind host, a loopback host, or an allowed-origin host.
    public func hostAllowed(_ hostHeader: String?, bindHost: String) -> Bool {
        guard let hostHeader, !hostHeader.isEmpty else { return !requireAuth }
        // Strip an optional :port (handle bracketed IPv6 too).
        let host: String
        if hostHeader.hasPrefix("[") {
            host = String(hostHeader.dropFirst().prefix(while: { $0 != "]" }))
        } else {
            host = String(hostHeader.split(separator: ":").first ?? "")
        }
        if host == bindHost || Self.loopbackHosts.contains(host) { return true }
        let allowedHosts = Set(allowedOrigins.compactMap { Self.safeHost($0) })
        return allowedHosts.contains(host)
    }

    /// Validate a bearer credential offered as a WS subprotocol
    /// (`bearer.<token>` — browsers can't set Authorization on WS) or as an
    /// `Authorization: Bearer <token>` header. Comparison is constant-time.
    public func bearerAccepted(subprotocols: [String], authorization: String?) -> Bool {
        guard requireAuth else { return true }
        guard let token = bearerToken, !token.isEmpty else { return false }
        if let authorization, Self.constantTimeEqual(authorization, "Bearer \(token)") { return true }
        for proto in subprotocols where Self.constantTimeEqual(proto, "bearer.\(token)") { return true }
        return false
    }

    /// Bearer gate for plain HTTP routes (e.g. POST /api/upload), which carry
    /// the token in `Authorization: Bearer <token>` (no WS subprotocol).
    public func httpBearerAccepted(_ authorization: String?) -> Bool {
        bearerAccepted(subprotocols: [], authorization: authorization)
    }

    /// Accept an OWNER credential offered as a WS subprotocol (`owner.<token>`) or an
    /// `X-Codex-Owner: Bearer <token>` header. Constant-time. Fail-CLOSED: with no
    /// configured `ownerToken` this returns false (the owner tier is unreachable).
    /// Independent of the read bearer — a leaked read bearer can NOT unlock the write tier.
    public func ownerAccepted(subprotocols: [String], authorization: String?) -> Bool {
        guard let token = ownerToken, !token.isEmpty else { return false }
        if let authorization, Self.constantTimeEqual(authorization, "Bearer \(token)") { return true }
        for proto in subprotocols where Self.constantTimeEqual(proto, "owner.\(token)") { return true }
        return false
    }

    /// Length-independent constant-time string compare over UTF-8 bytes. The
    /// length guard leaks only the length, not byte positions; for a fixed-size
    /// token that is acceptable.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

/// Adds the security response headers Chrome enforces. CSP is intentionally
/// scoped to what the shadcn bundle needs:
///   - `script-src 'self' 'wasm-unsafe-eval'` — shiki/onig + mermaid wasm
///   - `style-src 'self' 'unsafe-inline'` — runtime-injected styles
///   - `connect-src 'self'` — same-origin XHR + same-origin WebSocket
///   - `img/media 'self' data: blob:` — inline images + object URLs
/// HSTS is emitted only over TLS.
struct SecurityHeadersMiddleware<Context: RequestContext>: RouterMiddleware {
    let tls: Bool

    static var csp: String {
        [
            "default-src 'self'",
            "script-src 'self' 'wasm-unsafe-eval'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "font-src 'self' data:",
            "media-src 'self' blob:",
            "connect-src 'self'",
            "worker-src 'self' blob:",
            "frame-src 'self'",
            "frame-ancestors 'none'",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'self'",
        ].joined(separator: "; ")
    }

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        var h = response.headers
        func set(_ name: String, _ value: String) {
            if let n = HTTPField.Name(name) { h[n] = value }
        }
        set("Content-Security-Policy", Self.csp)
        set("X-Content-Type-Options", "nosniff")
        set("X-Frame-Options", "DENY")
        set("Referrer-Policy", "same-origin")
        set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        set("Cross-Origin-Opener-Policy", "same-origin")
        set("Cross-Origin-Resource-Policy", "same-origin")
        if tls {
            set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        }
        response.headers = h
        return response
    }
}
