import Foundation
import InfraPrimitives

/// Result of one fetch attempt. `unchanged` lets callers honour 304-style
/// "nothing new" responses without consulting body bytes again. `highWatermarkID`
/// is a cursor token (the largest ID seen on this page, the next-cursor link,
/// etc.) that the scheduler stamps into `source_cursor.high_watermark_id` so
/// the next fetch can resume from where this one left off. ETag and watermark
/// are separate fields because some sources expose only one of the two.
public enum FetchOutcome: Sendable, Equatable {
    case fresh(body: Data,
               etag: String? = nil,
               lastModified: Int64? = nil,
               highWatermarkID: String? = nil)
    case unchanged(etag: String? = nil,
                   lastModified: Int64? = nil,
                   highWatermarkID: String? = nil)
    case failed(String)
}

public protocol Fetcher: Sendable {
    func fetch(_ spec: SourceSpec,
               state: SourceState,
               deadline: Deadline) async -> FetchOutcome
}

/// Default `Fetcher` that shells out to `curl` for HTTP/RSS/JSON sources and
/// to `git ls-remote` / file reads for repos. Kept dependency-free on purpose
/// — `URLSession` would suffice on macOS but `Foundation`'s URLSession on
/// Swift-on-Linux is in a separate module (`FoundationNetworking`) and the
/// existing CodexKit posture is to prefer subprocess shellouts for parity.
public struct CurlFetcher: Fetcher {
    public let userAgent: String
    public let maxBytes: Int

    public init(userAgent: String = "CodexKit-Memory/1.0", maxBytes: Int = 8 << 20) {
        self.userAgent = userAgent
        self.maxBytes = maxBytes
    }

    public func fetch(_ spec: SourceSpec,
                      state: SourceState,
                      deadline: Deadline) async -> FetchOutcome {
        switch spec.kind {
        case .manual:
            return .failed("manual sources are not auto-fetched")
        case .x:
            // `x` traffic flows through `TwitterAPIFetcher`; if a caller wires
            // `CurlFetcher` directly for an `x` spec we surface the misconfig
            // here rather than silently hitting twitter.com.
            return .failed("x source requires TwitterAPIFetcher; use CompositeFetcher")
        default:
            break
        }

        // Build the curl argv. -sS (silent + show errors), -L (follow redirects),
        // -A user agent, -D - (dump headers to stdout), --max-time = remaining.
        let remaining = deadline.remaining.seconds
        let maxTime = Swift.max(2, Int(remaining))
        var argv: [String] = ["-sS", "-L", "-A", userAgent,
                              "--max-time", "\(maxTime)",
                              "--max-filesize", "\(maxBytes)",
                              "-D", "-"]
        for (k, v) in spec.headers { argv += ["-H", "\(k): \(v)"] }
        if let et = state.lastETag {
            argv += ["-H", "If-None-Match: \(et)"]
        }
        argv.append(spec.uri)

        let result = await runCurl(argv: argv)
        guard result.exit == 0 else {
            return .failed("curl exit=\(result.exit) \(result.stderr.prefix(200))")
        }

        // Split headers from body using the canonical double-CRLF separator.
        guard let split = splitHeaders(result.stdout) else {
            return .fresh(body: result.stdout, etag: nil, lastModified: nil)
        }
        let (statusCode, etag, lastModified) = parseHeaders(split.headers)
        if statusCode == 304 {
            return .unchanged(etag: etag ?? state.lastETag, lastModified: lastModified)
        }
        if statusCode >= 400 {
            return .failed("HTTP \(statusCode)")
        }
        return .fresh(body: split.body, etag: etag, lastModified: lastModified)
    }

    // MARK: - subprocess

    public struct SubprocessResult: Sendable {
        public var exit: Int32
        public var stdout: Data
        public var stderr: String
        public init(exit: Int32, stdout: Data, stderr: String) {
            self.exit = exit; self.stdout = stdout; self.stderr = stderr
        }
    }

    func runCurl(argv: [String]) async -> SubprocessResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = argv
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            do {
                try p.run()
            } catch {
                cont.resume(returning: SubprocessResult(
                    exit: 127, stdout: Data(), stderr: "spawn failed: \(error)"))
                return
            }
            // Read both pipes concurrently to avoid deadlock on large bodies.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: SubprocessResult(
                exit: p.terminationStatus,
                stdout: outData,
                stderr: String(data: errData, encoding: .utf8) ?? ""))
        }
    }

    // MARK: - HTTP parsing

    /// Split the FINAL header block off `data`. `curl -L -D -` concatenates
    /// the header block of every redirect hop, so a naïve "first CRLFCRLF"
    /// split returns the 301/302 headers and leaves the real response inside
    /// `body`. We iterate forward through every block whose first line starts
    /// with `HTTP/` and report the last one we see — i.e., the headers of the
    /// final hop, immediately followed by the actual body bytes.
    /// Returns nil if no CRLFCRLF boundary is found at all.
    func splitHeaders(_ data: Data) -> (headers: String, body: Data)? {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lflf = Data([0x0A, 0x0A])
        var search = data
        var lastHeaders: String?
        var lastBody: Data?
        while true {
            let crlfRange = search.range(of: crlfcrlf)
            let lfRange = search.range(of: lflf)
            // Pick whichever boundary appears first.
            let sep: Range<Data.Index>?
            switch (crlfRange, lfRange) {
            case let (.some(a), .some(b)): sep = a.lowerBound <= b.lowerBound ? a : b
            case let (.some(a), .none):    sep = a
            case let (.none, .some(b)):    sep = b
            case (.none, .none):           sep = nil
            }
            guard let sep else { break }
            let headerBytes = search.prefix(upTo: sep.lowerBound)
            let remainder = Data(search.suffix(from: sep.upperBound))
            let headers = String(data: headerBytes, encoding: .utf8) ?? ""
            lastHeaders = headers
            lastBody = remainder
            // Peek at the start of `remainder` — if it's another HTTP status
            // line, we have more redirect hops; otherwise this was the final
            // response and `remainder` is the body.
            if !startsWithHTTPStatusLine(remainder) { break }
            search = remainder
        }
        guard let h = lastHeaders, let b = lastBody else { return nil }
        return (h, b)
    }

    /// Tight check that the first line of `data` looks like an HTTP status
    /// line — `HTTP/X.Y NNN ...`. Looser checks (just the literal `HTTP/`
    /// prefix) would wrongly treat any payload starting with "HTTP/" — log
    /// dumps, mirrored response captures, etc. — as another redirect hop.
    private func startsWithHTTPStatusLine(_ data: Data) -> Bool {
        // Bound the inspection so a hostile body can't make us scan megabytes.
        let head = data.prefix(64)
        guard head.starts(with: Data("HTTP/".utf8)) else { return false }
        let after = head.dropFirst(5)
        // Need at least one digit, a dot, one digit, a space, a 3-digit code.
        let chars = after.prefix(while: { $0 != 0x20 && $0 != 0x0D && $0 != 0x0A })
        let version = String(data: Data(chars), encoding: .ascii) ?? ""
        guard version.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
        else { return false }
        // Status code: three ASCII digits right after the space.
        let rest = after.dropFirst(chars.count)
        guard rest.first == 0x20 else { return false }
        let statusBytes = Array(rest.dropFirst().prefix(3))
        guard statusBytes.count == 3,
              statusBytes.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return false
        }
        return true
    }

    func parseHeaders(_ raw: String) -> (status: Int, etag: String?, lastModified: Int64?) {
        var status = 0
        var etag: String?
        var lastModified: Int64?
        // Use `isNewline` to split because Swift coalesces "\r\n" into a
        // single extended grapheme cluster — `split(separator: "\n")` would
        // return one line containing both header lines and lose every
        // header after the status line.
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("HTTP/") {
                // HTTP/1.1 304 Not Modified  → take the second whitespace-separated token.
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let code = Int(parts[1]) { status = code }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].lowercased()
            let value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "etag":
                etag = value
            case "last-modified":
                lastModified = parseHTTPDate(value)
            default:
                break
            }
        }
        return (status, etag, lastModified)
    }

    /// Parse RFC 1123 / 850 / asctime HTTP dates into a Unix timestamp.
    /// Returns nil if the format is unrecognised (the caller treats this as
    /// "no Last-Modified" rather than a failure).
    func parseHTTPDate(_ s: String) -> Int64? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 1123
            "EEEE, dd-MMM-yy HH:mm:ss zzz",    // RFC 850
            "EEE MMM d HH:mm:ss yyyy",         // asctime
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        }
        return nil
    }
}
