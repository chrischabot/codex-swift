import Foundation

/// The HTTP seam for the media providers: a tiny POST surface the provider uses
/// instead of touching URLSession directly, so tests can stub the network with
/// no live key and no real socket. The default impl routes through URLSession.
///
/// `post` never throws into the caller's flow — it returns a `Result`, so a
/// transport error and a non-2xx status are both observable (and the provider
/// can decide retry vs. fail). Keeping the seam `Sendable` lets the provider be
/// used from an actor / async ledger without data-race warnings.
public protocol MediaHTTPPosting: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async
    -> Result<(status: Int, data: Data), any Error>
}

/// Transport-level errors surfaced by `URLSessionMediaHTTP` so the provider can
/// classify them WITHOUT interpolating a raw `URLError` (whose `userInfo` can
/// carry the failing `URLRequest`/headers) into a persisted, user-visible string.
public enum MediaHTTPError: Error, Sendable, Equatable {
    case responseTooLarge(limit: Int)
    case transport(code: Int)   // URLError.Code.rawValue, or 0 if unknown
}

/// Refuses ALL HTTP redirects. The request carries `Authorization: Bearer <key>`;
/// URLSession's default behavior re-sends request headers on a 3xx, so a
/// compromised/spoofed endpoint (or a network MITM) returning `302 Location:
/// https://evil/` would replay the bearer to an attacker host. Returning nil
/// from the redirect callback hard-stops the hop — the response is delivered as
/// the 3xx itself (a non-2xx the provider then fails closed on).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never follow — never leak the bearer cross-host
    }
}

/// Default transport: a single POST through a per-instance ephemeral URLSession.
/// Two hardenings the secret-bearing request requires: (1) redirects are REFUSED
/// (the bearer is never replayed to a redirect target), and (2) the response is
/// streamed with a hard size cap so a hostile/compromised endpoint can't OOM the
/// daemon with a multi-GB body (a 1024×1024 PNG base64 is a couple MB; the cap is
/// far above that but far below memory pressure).
public struct URLSessionMediaHTTP: MediaHTTPPosting {
    private let timeout: TimeInterval
    private let maxResponseBytes: Int
    public init(timeout: TimeInterval = 120, maxResponseBytes: Int = 32 * 1024 * 1024) {
        self.timeout = timeout
        self.maxResponseBytes = max(64 * 1024, maxResponseBytes)
    }

    public func post(url: URL, headers: [String: String], body: Data) async
    -> Result<(status: Int, data: Data), any Error> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            // Early reject on a declared oversize body, before reading any bytes.
            if let declared = (resp as? HTTPURLResponse)?.expectedContentLength,
               declared > Int64(maxResponseBytes) {
                return .failure(MediaHTTPError.responseTooLarge(limit: maxResponseBytes))
            }
            // Stream with a hard cap so an undeclared/chunked oversize body is also
            // bounded (never buffer past the limit).
            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, 1 << 20))
            for try await b in bytes {
                data.append(b)
                if data.count > maxResponseBytes {
                    return .failure(MediaHTTPError.responseTooLarge(limit: maxResponseBytes))
                }
            }
            return .success((status: status, data: data))
        } catch {
            return .failure(error)
        }
    }
}

/// LIVE async media provider backed by OpenAI Images (`gpt-image-1`). It is an
/// INLINE provider despite the network round-trip: `gpt-image-1` returns the PNG
/// as base64 in the JSON body, so `submit` decodes + writes the asset and returns
/// `.inline` synchronously — there is NO queued handle, NO second URL download
/// (so no SSRF on a returned URL), and `poll` is never meaningfully used.
///
/// Because it is inline, it works in BOTH in-process and spawned worker modes
/// (no daemon poller required) — see `MediaConfig.inlineProviders`.
public struct OpenAIImagesProvider: MediaProvider {
    public let id = "openai"

    private let mediaRoot: String
    private let apiKey: String
    private let http: any MediaHTTPPosting
    /// Bounded retry on 429 / 5xx (transient). Capped so a persistently-failing
    /// backend can't burn the turn or the budget.
    private let maxRetries: Int

    public init(mediaRoot: String, apiKey: String,
                http: any MediaHTTPPosting = URLSessionMediaHTTP(),
                maxRetries: Int = 3) {
        self.mediaRoot = mediaRoot
        self.apiKey = apiKey
        self.http = http
        self.maxRetries = max(0, maxRetries)
    }

    public func supports(_ kind: MediaKind) -> Bool { kind == .image }

    public func submit(kind: MediaKind, prompt: String) async -> MediaSubmitResult {
        guard kind == .image else {
            return .failed("openai images provider only supports .image (got \(kind.rawValue))")
        }
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            return .failed("openai: bad endpoint URL")
        }
        let payload: [String: Any] = [
            "model": "gpt-image-1",
            "prompt": prompt,
            "size": "1024x1024",
            "n": 1,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed("openai: failed to encode request body")
        }
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
        ]

        var attempt = 0
        while true {
            let result = await http.post(url: url, headers: headers, body: body)
            switch result {
            case .failure(let err):
                // A deliberately-capped oversize response is NOT transient — fail
                // closed immediately rather than retrying into the same wall.
                if case MediaHTTPError.responseTooLarge(let limit) = err {
                    return .failed("openai: response exceeded the \(limit)-byte cap")
                }
                // Transport failure is treated as transient (timeout / reset).
                if attempt < maxRetries {
                    await backoff(attempt); attempt += 1; continue
                }
                // REDACTED: never interpolate the raw URLError (its userInfo can
                // carry the failing URLRequest/headers) into a persisted, user-
                // visible string — surface only a stable URLError code.
                return .failed("openai: transport error after \(attempt + 1) attempt(s) "
                    + "(\(transportCode(err)))")
            case .success(let (status, data)):
                if status == 429 || (status >= 500 && status <= 599) {
                    if attempt < maxRetries {
                        await backoff(attempt); attempt += 1; continue
                    }
                    return .failed("openai: HTTP \(status) after \(attempt + 1) attempt(s): "
                        + bodySnippet(data))
                }
                guard (200...299).contains(status) else {
                    return .failed("openai: HTTP \(status): \(bodySnippet(data))")
                }
                return decodeAndWrite(data)
            }
        }
    }

    /// Inline provider — never queues, so a poll handle is never minted. If one
    /// is somehow polled, report pending (the inline result already wrote).
    public func poll(providerTaskId: String) async -> MediaPollResult { .pending }

    // MARK: - internals

    private func decodeAndWrite(_ data: Data) -> MediaSubmitResult {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("openai: response was not a JSON object")
        }
        guard let arr = obj["data"] as? [[String: Any]], let first = arr.first else {
            return .failed("openai: response missing data[0]")
        }
        guard let b64 = first["b64_json"] as? String, !b64.isEmpty else {
            return .failed("openai: response missing data[0].b64_json")
        }
        guard let png = Data(base64Encoded: b64), !png.isEmpty else {
            return .failed("openai: data[0].b64_json was not valid base64")
        }
        let name = "image-\(UUID().uuidString).png"
        let path = mediaRoot + "/" + name
        do {
            try FileManager.default.createDirectory(
                atPath: mediaRoot, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            return .failed("openai: asset write failed: \(error)")
        }
        return .inline(assetPath: path)
    }

    private func backoff(_ attempt: Int) async {
        // Exponential-ish, bounded: 0.5s, 1s, 2s … capped at 4s.
        let secs = min(4.0, 0.5 * pow(2.0, Double(attempt)))
        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
    }

    /// A stable, non-sensitive label for a transport error — the URLError code
    /// name when available, else a generic marker. Never includes the request,
    /// URL, or headers.
    private func transportCode(_ err: any Error) -> String {
        if let u = err as? URLError { return "URLError \(u.code.rawValue)" }
        return "transport failure"
    }

    /// A short, non-secret slice of an error body for diagnostics (never logs the
    /// key — the key only ever lives in the request header).
    private func bodySnippet(_ data: Data) -> String {
        let s = String(data: data.prefix(300), encoding: .utf8) ?? "<\(data.count) bytes>"
        return s.replacingOccurrences(of: "\n", with: " ")
    }
}
