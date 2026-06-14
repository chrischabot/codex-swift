import Foundation

/// Caps that bound a single fetch (defeating slowloris / response bombs / runaway
/// redirects). `downloadCeiling` matches the collect/media path's larger budget.
public struct FetchCaps: Sendable, Equatable {
    public var maxBytes: Int
    public var maxRedirects: Int
    public var connectTimeoutMS: Int
    public var totalTimeoutMS: Int
    /// nil = accept any content type; readable mode defaults to text/* shapes.
    public var allowedContentTypes: Set<String>?

    public init(maxBytes: Int = 16 << 20, maxRedirects: Int = 5,
                connectTimeoutMS: Int = 10_000, totalTimeoutMS: Int = 30_000,
                allowedContentTypes: Set<String>? = nil) {
        self.maxBytes = maxBytes; self.maxRedirects = maxRedirects
        self.connectTimeoutMS = connectTimeoutMS; self.totalTimeoutMS = totalTimeoutMS
        self.allowedContentTypes = allowedContentTypes
    }

    public static let downloadCeiling = FetchCaps(maxBytes: 512 << 20)
    /// Readable defaults: only text/html-ish bodies.
    public static let readable = FetchCaps(
        allowedContentTypes: ["text/html", "application/xhtml+xml", "text/plain", "application/xml", "text/xml"])
}

/// Raw final response after following (re-vetted) redirects.
public struct RawResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]   // lowercased keys
    public var body: Data                  // ≤ caps.maxBytes
    public var finalURL: URL
    public var peerIP: String
    public var truncated: Bool
    public init(status: Int, headers: [String: String], body: Data,
                finalURL: URL, peerIP: String, truncated: Bool) {
        self.status = status; self.headers = headers; self.body = body
        self.finalURL = finalURL; self.peerIP = peerIP; self.truncated = truncated
    }
}

/// HTML fetched + extracted to Markdown (in-process; no codec, no sandbox).
public struct ReadableDoc: Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var markdown: String
    public var byteCount: Int
    public init(url: URL, title: String?, markdown: String, byteCount: Int) {
        self.url = url; self.title = title; self.markdown = markdown; self.byteCount = byteCount
    }
}

/// A bounded binary download staged to a temp file (the collect-media path).
public struct DownloadedBlob: Sendable, Equatable {
    public var path: String
    public var byteSize: Int
    public var sha256: String
    public var sniffedMIME: String   // magic-byte sniff, NOT the server header
    public var truncated: Bool
    public var peerIP: String
    public init(path: String, byteSize: Int, sha256: String, sniffedMIME: String,
                truncated: Bool, peerIP: String) {
        self.path = path; self.byteSize = byteSize; self.sha256 = sha256
        self.sniffedMIME = sniffedMIME; self.truncated = truncated; self.peerIP = peerIP
    }
}

public enum FetchError: Error, Sendable, Equatable {
    case egressDenied(reason: String)   // vet() denied (SSRF / scheme / blocked IP)
    case peerMismatch                   // connected peer not in the vetted pin set
    case tooManyRedirects
    case redirectDenied(reason: String) // a 3xx Location re-vetted and denied
    case statusError(Int)
    case oversize                       // readable body exceeded maxBytes (hard fail)
    case contentTypeRejected(String)
    case timedOut
    case transport(String)
    case malformedResponse
    case notReadable
    case io(String)
}

// MARK: - transport seam (so the SSRF/redirect/peer logic is testable w/o a server)

/// A connect-bound request: the transport MUST connect to one of `pinnedIPs`
/// (never re-resolving `host`), send `requestBytes`, and report the actual peer.
public struct TransportRequest: Sendable {
    public var host: String
    public var pinnedIPs: [String]
    public var port: Int
    public var useTLS: Bool
    public var requestBytes: Data
    public var caps: FetchCaps
    public init(host: String, pinnedIPs: [String], port: Int, useTLS: Bool,
                requestBytes: Data, caps: FetchCaps) {
        self.host = host; self.pinnedIPs = pinnedIPs; self.port = port
        self.useTLS = useTLS; self.requestBytes = requestBytes; self.caps = caps
    }
}

public struct TransportResponse: Sendable {
    public var peerIP: String   // the address actually connected to
    public var bytes: Data      // raw response bytes, capped at caps.maxBytes
    public var truncated: Bool  // more bytes were available than the cap allowed
    public init(peerIP: String, bytes: Data, truncated: Bool) {
        self.peerIP = peerIP; self.bytes = bytes; self.truncated = truncated
    }
}

/// The byte transport. The real impl pins a TLS socket to a vetted IP with
/// SNI=host (`NWPinnedTransport`); tests inject a mock to exercise the vet /
/// redirect / peer-check / cap logic deterministically.
public protocol PinnedTransport: Sendable {
    func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError>
}
