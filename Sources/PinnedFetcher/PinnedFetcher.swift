import Foundation
import EgressGuard
import InfraPrimitives

/// The SSRF chokepoint. Every fetch goes: `EgressGuard.vet` → connect to a vetted
/// IP (the transport pins the socket, SNI = original host) → re-check the actual
/// peer is in the vetted set → parse → if a 3xx, re-vet + re-pin the Location
/// (redirects are never auto-followed) → enforce caps. Fails closed: any vet deny,
/// peer mismatch, oversize, or transport error throws; no partial-but-"ok" body.
///
/// The byte transport is injectable so this security-critical control flow is
/// exercised deterministically by tests; production uses `NWPinnedTransport`.
public struct PinnedFetcher: Sendable {
    public let guard_: EgressGuard
    let transport: any PinnedTransport
    public let caps: FetchCaps

    public init(guard_: EgressGuard, transport: (any PinnedTransport)? = nil, caps: FetchCaps = FetchCaps()) {
        self.guard_ = guard_
        self.transport = transport ?? NWPinnedTransport()
        self.caps = caps
    }

    /// Low-level: fetch following (re-vetted) redirects, returning the final response.
    public func fetchRaw(_ url: URL, accept: String = "*/*", caps overrideCaps: FetchCaps? = nil)
        async -> Result<RawResponse, FetchError> {
        let c = overrideCaps ?? caps
        var current = url
        var hops = 0
        while true {
            switch guard_.vet(current) {
            case .deny(let r):
                return .failure(.egressDenied(reason: r))
            case .allow(let approval):
                let scheme = current.scheme?.lowercased() ?? "https"
                let useTLS = scheme == "https"
                let port = current.port ?? (useTLS ? 443 : 80)
                let reqBytes = Self.buildRequest(url: current, host: approval.host, accept: accept)
                let tReq = TransportRequest(host: approval.host, pinnedIPs: approval.pinnedIPs,
                                            port: port, useTLS: useTLS, requestBytes: reqBytes, caps: c)
                let tRes: TransportResponse
                switch await transport.roundTrip(tReq) {
                case .failure(let e): return .failure(e)
                case .success(let r): tRes = r
                }
                // Strong rebinding defense: the socket must have landed on a vetted pin.
                guard approval.allows(peerIP: tRes.peerIP) else { return .failure(.peerMismatch) }
                let parsed: HTTPResponse.Parsed
                do { parsed = try HTTPResponse.parse(tRes.bytes) }
                catch { return .failure(.malformedResponse) }

                if HTTPResponse.isRedirect(parsed.status) {
                    guard let loc = parsed.headers["location"], !loc.isEmpty else {
                        return .failure(.statusError(parsed.status))
                    }
                    hops += 1
                    if hops > c.maxRedirects { return .failure(.tooManyRedirects) }
                    switch guard_.vetRedirect(from: current, location: loc) {
                    case .deny(let r): return .failure(.redirectDenied(reason: r))
                    case .allow:
                        guard let next = URL(string: loc.trimmingCharacters(in: .whitespacesAndNewlines),
                                             relativeTo: current)?.absoluteURL else {
                            return .failure(.redirectDenied(reason: "malformed Location"))
                        }
                        current = next
                        continue
                    }
                }
                return .success(RawResponse(status: parsed.status, headers: parsed.headers,
                                            body: parsed.body, finalURL: current,
                                            peerIP: tRes.peerIP, truncated: tRes.truncated))
            }
        }
    }

    /// HTML → Markdown (in-process readability). Enforces 2xx + a text content type
    /// and, per the hard cap, refuses a truncated body (never a partial-but-"ok"
    /// page).
    public func fetchReadable(_ url: URL) async -> Result<ReadableDoc, FetchError> {
        var rc = FetchCaps.readable
        rc.maxBytes = caps.maxBytes; rc.maxRedirects = caps.maxRedirects
        rc.connectTimeoutMS = caps.connectTimeoutMS; rc.totalTimeoutMS = caps.totalTimeoutMS
        switch await fetchRaw(url, accept: "text/html,application/xhtml+xml,*/*;q=0.8", caps: rc) {
        case .failure(let e): return .failure(e)
        case .success(let r):
            guard (200..<300).contains(r.status) else { return .failure(.statusError(r.status)) }
            if let allowed = rc.allowedContentTypes {
                let ct = r.headers["content-type"]?.split(separator: ";").first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if !ct.isEmpty && !allowed.contains(ct) { return .failure(.contentTypeRejected(ct)) }
            }
            if r.truncated { return .failure(.oversize) }
            let html = String(decoding: r.body, as: UTF8.self)
            let (title, md) = Readability.toMarkdown(html: html)
            if md.isEmpty { return .failure(.notReadable) }
            return .success(ReadableDoc(url: r.finalURL, title: title, markdown: md, byteCount: md.utf8.count))
        }
    }

    /// Bounded binary download staged to a `0600` temp file (collect-media path).
    /// `truncated` is allowed here (the bytes that fit are kept) — unlike readable.
    public func download(_ url: URL, caps dlCaps: FetchCaps = .downloadCeiling)
        async -> Result<DownloadedBlob, FetchError> {
        switch await fetchRaw(url, accept: "*/*", caps: dlCaps) {
        case .failure(let e): return .failure(e)
        case .success(let r):
            guard (200..<300).contains(r.status) else { return .failure(.statusError(r.status)) }
            let path = NSTemporaryDirectory() + "pinned-dl-\(UUID().uuidString)"
            do {
                try r.body.write(to: URL(fileURLWithPath: path), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            } catch { return .failure(.io(String(describing: error))) }
            let sha = Hashing.sha256(Array(r.body)).map { String(format: "%02x", $0) }.joined()
            return .success(DownloadedBlob(path: path, byteSize: r.body.count, sha256: sha,
                                           sniffedMIME: MIMESniff.sniff(r.body), truncated: r.truncated,
                                           peerIP: r.peerIP))
        }
    }

    // MARK: request building

    static func buildRequest(url: URL, host: String, accept: String) -> Data {
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }
        let lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "User-Agent: codex-wiki-fetcher/1.0",
            "Accept: \(accept)",
            "Accept-Encoding: identity",   // avoid gzip so no decompression is needed
            "Connection: close",
            "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

/// Magic-byte MIME sniff (NOT the server header) for downloaded media.
enum MIMESniff {
    static func sniff(_ d: Data) -> String {
        let b = [UInt8](d.prefix(16))
        func has(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        if has([0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }            // %PDF
        if has([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }                  // .PNG
        if has([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if has([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }                  // GIF8
        if has([0x52, 0x49, 0x46, 0x46]) { return "image/webp" }                 // RIFF (webp/wav)
        if b.count >= 12, Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "video/mp4" }  // ftyp
        if has([0x1F, 0x8B]) { return "application/gzip" }
        if has([0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }
        return "application/octet-stream"
    }
}

