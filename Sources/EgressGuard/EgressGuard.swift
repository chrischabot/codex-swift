import Foundation
#if canImport(Darwin)
import Darwin
#endif

// ADDONS.md Phase 0 #5: the egress chokepoint.
//
// The review of ADDONS.md flagged SSRF as the dominant outbound risk: a
// model-driven push / cron webhook / media fetch to an attacker-chosen URL can
// hit cloud metadata (169.254.169.254), localhost services, or RFC1918 hosts,
// and HMAC-signing the body is RECEIVER auth, not egress control. Every
// outbound HTTP target (push #7, cron webhook #6, media #8) is screened here
// BEFORE the request: HTTPS-only, an explicit host allowlist, and a check of
// the RESOLVED IPs (not just the hostname).
//
// IMPORTANT — DNS rebinding / TOCTOU: a pure name→IP screen cannot by itself
// defeat DNS rebinding, because the HTTP client RE-RESOLVES at connect time and
// an attacker DNS can answer differently the second time. So this module is
// connect-BOUND, not just a pre-flight: `vet(_:)` returns the VETTED IPs the
// caller MUST connect to (pin the IP, send the original Host/SNI), and
// `isPeerAllowed(_:)` / `EgressApproval.allows(peerIP:)` re-check the ACTUAL
// connected peer address. The caller's HTTP client (#7) is responsible for
// pinning / re-checking — this module supplies the verdict, the pinned IPs, and
// the peer check.
//
// REDIRECTS are equally the caller's duty: a vetted public host can 30x-redirect
// to an internal URL, so the HTTP client MUST disable automatic redirect
// following (or re-`vet` + re-pin + peer-check every hop). `vet` only judges the
// single URL it is given.

/// A parsed IP literal in normalized byte form.
public enum ParsedIP: Equatable, Sendable {
    case v4([UInt8])   // 4 bytes
    case v6([UInt8])   // 16 bytes

    /// Parse a textual IP. v4 is accepted ONLY in canonical dotted-decimal
    /// (no leading zeros, no hex, exactly four 0–255 fields) so the classifier
    /// can never disagree with an `inet_aton`-style connect path that reads a
    /// leading-zero field as octal. v6 via `inet_pton`.
    public static func parse(_ s: String) -> ParsedIP? {
        if s.contains(":") {   // v6
            var v6 = in6_addr()
            if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
                let t = v6.__u6_addr.__u6_addr8
                return .v6([t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
                            t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15])
            }
            return nil
        }
        return strictV4(s)
    }

    /// Strict canonical dotted-decimal v4 (rejects octal/hex/short forms).
    public static func strictV4(_ s: String) -> ParsedIP? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber) else { return nil }
            if p.count > 1 && p.first == "0" { return nil }   // leading zero → octal ambiguity
            guard let v = Int(p), v <= 255 else { return nil }
            bytes.append(UInt8(v))
        }
        return .v4(bytes)
    }

    /// True for any address that must never be the target of agent-driven
    /// outbound: loopback, unspecified, private (RFC1918 / ULA), link-local
    /// (incl. metadata 169.254.169.254), CGNAT, benchmarking, multicast/reserved,
    /// and IPv4 embedded in v6 (v4-mapped / v4-compatible / NAT64 / 6to4).
    public var isBlocked: Bool {
        switch self {
        case .v4(let b):
            guard b.count == 4 else { return true }                         // malformed → fail-closed
            if b[0] == 0 || b[0] == 127 || b[0] == 10 { return true }       // unspecified / loopback / 10/8
            if b[0] == 172 && (16...31).contains(b[1]) { return true }      // 172.16/12
            if b[0] == 192 && b[1] == 168 { return true }                   // 192.168/16
            if b[0] == 169 && b[1] == 254 { return true }                   // 169.254/16 link-local (+ metadata)
            if b[0] == 100 && (64...127).contains(b[1]) { return true }     // 100.64/10 CGNAT
            if b[0] == 198 && (b[1] == 18 || b[1] == 19) { return true }    // 198.18/15 benchmarking
            if b[0] >= 224 { return true }                                  // 224/4 multicast + 240/4 reserved
            return false
        case .v6(let b):
            guard b.count == 16 else { return true }                       // malformed → fail-closed
            if b == [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1] { return true }       // ::1 loopback
            if b.allSatisfy({ $0 == 0 }) { return true }                    // :: unspecified
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }        // fe80::/10 link-local
            if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return true }        // fec0::/10 deprecated site-local
            if (b[0] & 0xfe) == 0xfc { return true }                        // fc00::/7 ULA
            if b[0] == 0xff { return true }                                 // ff00::/8 multicast
            // NAT64 64:ff9b::/96 → embedded v4
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b,
               b[4..<12].allSatisfy({ $0 == 0 }) {
                return ParsedIP.v4(Array(b[12..<16])).isBlocked
            }
            // ::ffff:a.b.c.d v4-mapped → embedded v4
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return ParsedIP.v4(Array(b[12..<16])).isBlocked
            }
            // ::a.b.c.d v4-compatible (deprecated) → embedded v4 (::/::1 already handled)
            if b[0..<12].allSatisfy({ $0 == 0 }) {
                return ParsedIP.v4(Array(b[12..<16])).isBlocked
            }
            // 2002:V4ADDR::/16 6to4 → embedded v4
            if b[0] == 0x20, b[1] == 0x02 {
                return ParsedIP.v4(Array(b[2..<6])).isBlocked
            }
            return false
        }
    }

    /// Canonical form for equality: an ::ffff:a.b.c.d v4-mapped address folds to
    /// its .v4 so a pinned `1.2.3.4` matches a peer reported as `::ffff:1.2.3.4`.
    /// Other v6 textual variants (zero-compression, case) already normalize via
    /// `parse`'s inet_pton, so byte-equality suffices.
    public var canonical: ParsedIP {
        if case .v6(let b) = self, b.count == 16,
           b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            return .v4(Array(b[12..<16]))
        }
        return self
    }
}

/// Outcome of validating one outbound URL (simple form).
public enum EgressDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
    public var isAllowed: Bool { if case .allow = self { return true }; return false }
}

/// The vetted target — the caller MUST connect to one of `pinnedIPs` (sending
/// the original Host/SNI) to defeat DNS rebinding.
public struct EgressApproval: Equatable, Sendable {
    public let host: String
    public let pinnedIPs: [String]
    /// True iff `peerIP` is one of the vetted pins — the caller's connection
    /// delegate uses this to enforce the socket actually connected to a vetted
    /// address (the real rebinding defense, stronger than `isPeerAllowed`).
    /// Compares NORMALIZED addresses (parse → canonical), not raw strings, so an
    /// IPv6 peer rendered differently than the pin (zero-compression, case, or
    /// ::ffff: v4-mapped) still matches.
    public func allows(peerIP: String) -> Bool {
        guard let peer = ParsedIP.parse(peerIP)?.canonical else { return false }
        return pinnedIPs.contains { ParsedIP.parse($0)?.canonical == peer }
    }
}

/// Connect-bound vetting result.
public enum EgressResult: Equatable, Sendable {
    case allow(EgressApproval)
    case deny(reason: String)
}

/// Policy for the egress chokepoint.
public struct EgressPolicy: Sendable {
    /// Canonicalized exact host allowlist. When non-empty only these hosts may
    /// be targeted. Empty = any PUBLIC host (still subject to the IP block).
    public let allowedHosts: Set<String>
    /// Permit `http://` (default false — HTTPS only). The IP block still applies.
    public var allowHTTP: Bool
    /// Resolve a hostname to its IP literals (injectable for tests).
    public var resolve: @Sendable (String) -> [String]

    public init(allowedHosts: Set<String> = [],
                allowHTTP: Bool = false,
                resolve: @escaping @Sendable (String) -> [String] = EgressPolicy.systemResolve) {
        self.allowedHosts = Set(allowedHosts.map(EgressPolicy.canonicalHost))
        self.allowHTTP = allowHTTP
        self.resolve = resolve
    }

    /// Lowercase + strip a single trailing root dot (so `Foo.Internal.` and
    /// `foo.internal` canonicalize the same).
    public static func canonicalHost(_ raw: String) -> String {
        var h = raw.lowercased()
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        return h
    }

    /// Default resolver: every A/AAAA record for `host` via `getaddrinfo`.
    public static let systemResolve: @Sendable (String) -> [String] = { host in
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let cur = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = cur.pointee.ai_next
        }
        return out
    }
}

/// Validates outbound URLs against an `EgressPolicy`.
public struct EgressGuard: Sendable {
    public let policy: EgressPolicy
    public init(_ policy: EgressPolicy) { self.policy = policy }

    /// Full connect-bound vet: returns the vetted IPs to pin, or a deny reason.
    public func vet(_ url: URL) -> EgressResult {
        guard let scheme = url.scheme?.lowercased() else { return .deny(reason: "no scheme") }
        guard scheme == "https" || (scheme == "http" && policy.allowHTTP) else {
            return .deny(reason: "scheme '\(scheme)' not permitted (HTTPS required)")
        }
        if url.user != nil || url.password != nil {
            return .deny(reason: "credentials in URL are not permitted")
        }
        guard let rawHost = url.host, !rawHost.isEmpty else { return .deny(reason: "no host") }
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host = String(host.dropLast()) }   // strip FQDN root dot

        if !policy.allowedHosts.isEmpty && !policy.allowedHosts.contains(host) {
            return .deny(reason: "host '\(host)' not in the egress allowlist")
        }
        if host == "internal" || host.hasSuffix(".internal") {
            return .deny(reason: "host '\(host)' is an internal name")
        }
        let blockedIP = "target is loopback/private/link-local/reserved"

        // IPv6 literal.
        if host.contains(":") {
            guard let ip = ParsedIP.parse(host) else { return .deny(reason: "malformed IPv6 host '\(host)'") }
            return ip.isBlocked ? .deny(reason: blockedIP)
                                : .allow(EgressApproval(host: host, pinnedIPs: [host]))
        }
        // Ambiguous-numeric-IP candidate: EVERY dot-separated field starts with a
        // digit, so an inet_aton-style connect path would parse the host as a
        // number (hex 0x…, octal leading-zero, decimal-integer, short form). Such
        // a host must be canonical dotted-decimal or it is denied. A field that
        // starts with a LETTER (deadbeef, the "cab" in 0xcafe.cab, cdn) makes it
        // a hostname — resolved normally, not denied.
        let fields = host.split(separator: ".", omittingEmptySubsequences: false)
        let numericIPish = !fields.isEmpty && fields.allSatisfy { $0.first?.isNumber == true }
        if numericIPish {
            guard let ip = ParsedIP.strictV4(host) else {
                return .deny(reason: "ambiguous numeric host '\(host)'")
            }
            return ip.isBlocked ? .deny(reason: blockedIP)
                                : .allow(EgressApproval(host: host, pinnedIPs: [host]))
        }
        // Hostname: resolve, FAIL CLOSED on any IP we can't strictly classify,
        // reject if ANY resolved IP is blocked, and pin the rest.
        let ips = policy.resolve(host)
        if ips.isEmpty { return .deny(reason: "host '\(host)' did not resolve") }
        for ipStr in ips {
            guard let ip = ParsedIP.parse(ipStr) else {
                return .deny(reason: "resolver returned an unparseable IP '\(ipStr)' for '\(host)'")
            }
            if ip.isBlocked { return .deny(reason: "host '\(host)' resolves to blocked IP \(ipStr)") }
        }
        return .allow(EgressApproval(host: host, pinnedIPs: ips))
    }

    /// Simple screening verdict (no pinning info).
    public func validate(_ url: URL) -> EgressDecision {
        switch vet(url) {
        case .allow: return .allow
        case .deny(let r): return .deny(reason: r)
        }
    }

    public func validate(urlString: String) -> EgressDecision {
        guard let url = URL(string: urlString) else { return .deny(reason: "malformed URL") }
        return validate(url)
    }

    /// Connect-time BACKSTOP: is the connected peer a public address? This only
    /// checks the peer is not internal — NOT that it is one of the vetted pins.
    /// For full rebinding enforcement the caller should connect to a pinned IP
    /// and verify the peer with `EgressApproval.allows(peerIP:)`; this helper is
    /// the weaker public-only check for callers that can't pin.
    public func isPeerAllowed(_ ipString: String) -> Bool {
        guard let ip = ParsedIP.parse(ipString) else { return false }
        return !ip.isBlocked
    }
}
