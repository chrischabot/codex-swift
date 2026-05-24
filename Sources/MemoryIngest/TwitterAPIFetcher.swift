import Foundation
import InfraPrimitives

/// Fetcher for the `x` source kind, backed by TwitterAPI.io's pay-as-you-go
/// REST surface (design doc §4 and the verbatim price pin
/// `$0.15 per 1,000 tweets, $0.18 per 1,000 profiles`).
///
/// The SourceSpec's `uri` doubles as the query identifier. We support three
/// shapes so the same fetcher handles handle tracking, keyword search, and
/// list streaming:
///
///   user:elonmusk            → /twitter/user/last_tweets?userName=elonmusk
///   list:1234567890          → /twitter/list/tweets?listId=1234567890
///   search:"openai codex"    → /twitter/tweet/advanced_search?query=…
///
/// Pagination cursors land in `state.highWatermarkID`. The fetcher writes
/// one TSV-like joined body so the downstream Normaliser can dedupe + chunk
/// without a Twitter-specific parser.
public struct TwitterAPIFetcher: Fetcher {
    public struct Config: Sendable {
        public var endpoint: String
        public var apiKeyEnv: String
        public var maxResults: Int
        public init(endpoint: String = "https://api.twitterapi.io",
                    apiKeyEnv: String = "TWITTERAPI_IO_KEY",
                    maxResults: Int = 100) {
            self.endpoint = endpoint
            self.apiKeyEnv = apiKeyEnv
            self.maxResults = maxResults
        }
    }

    public let config: Config

    public init(config: Config = Config()) { self.config = config }

    public func fetch(_ spec: SourceSpec,
                      state: SourceState,
                      deadline: Deadline) async -> FetchOutcome {
        guard let apiKey = ProcessInfo.processInfo.environment[config.apiKeyEnv],
              !apiKey.isEmpty else {
            return .failed("TwitterAPI.io key missing: set $\(config.apiKeyEnv)")
        }
        guard let endpoint = Self.resolveEndpoint(uri: spec.uri,
                                                  base: config.endpoint,
                                                  maxResults: config.maxResults,
                                                  cursor: state.highWatermarkID)
        else { return .failed("unsupported x: spec \(spec.uri)") }

        let maxTime = max(2, Int(deadline.remaining.seconds))
        let argv = [
            "-sS", "--max-time", "\(maxTime)",
            "-H", "x-api-key: \(apiKey)",
            "-H", "accept: application/json",
            endpoint,
        ]
        let result = await runCurl(argv: argv)
        guard result.exit == 0 else {
            return .failed("curl exit=\(result.exit) \(result.stderr.prefix(200))")
        }
        // Parse the JSON, extract tweet bodies, fold to a newline-joined text
        // blob the downstream Normaliser can process. TwitterAPI.io returns
        // `{ "tweets": [ { "id_str": "...", "text": "..." } ], "next_cursor": "..." }`.
        guard let obj = try? JSONSerialization.jsonObject(with: result.stdout)
                as? [String: Any] else {
            return .failed("non-JSON x payload (\(result.stdout.count) bytes)")
        }
        if let err = obj["error"] as? String {
            return .failed("twitterapi.io: \(err)")
        }
        let tweets = (obj["tweets"] as? [[String: Any]])
            ?? (obj["data"] as? [[String: Any]])
            ?? []
        if tweets.isEmpty {
            return .unchanged(etag: nil, lastModified: nil,
                              highWatermarkID: state.highWatermarkID)
        }
        var lines: [String] = []
        var highestID: String?
        for t in tweets {
            let id = (t["id_str"] as? String) ?? (t["id"] as? String) ?? ""
            let text = (t["text"] as? String) ?? (t["full_text"] as? String) ?? ""
            if !text.isEmpty {
                lines.append("[\(id)] \(text)")
            }
            // Twitter snowflake ids are lexicographically monotonic, so we
            // can take the string maximum across this batch.
            if !id.isEmpty, (highestID ?? "") < id { highestID = id }
        }
        // Compare against the prior watermark so a partial page can't
        // accidentally walk the cursor backward.
        let advancedID: String? = {
            switch (highestID, state.highWatermarkID) {
            case let (.some(h), .some(prior)): return h > prior ? h : prior
            case let (.some(h), .none):        return h
            case let (.none, .some(prior)):    return prior
            case (.none, .none):               return nil
            }
        }()
        // Optional API-provided cursor takes precedence over snowflake max
        // when present (handles list / search pagination cleanly).
        let nextCursor = (obj["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let body = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        return .fresh(body: body, etag: nil, lastModified: nil,
                      highWatermarkID: nextCursor ?? advancedID)
    }

    static func resolveEndpoint(uri: String,
                                base: String,
                                maxResults: Int,
                                cursor: String?) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("user:") {
            let user = String(trimmed.dropFirst("user:".count))
            var url = "\(base)/twitter/user/last_tweets?userName=\(percent(user))"
            url += "&count=\(maxResults)"
            if let c = cursor { url += "&cursor=\(percent(c))" }
            return url
        }
        if trimmed.hasPrefix("list:") {
            let list = String(trimmed.dropFirst("list:".count))
            var url = "\(base)/twitter/list/tweets?listId=\(percent(list))"
            url += "&count=\(maxResults)"
            if let c = cursor { url += "&cursor=\(percent(c))" }
            return url
        }
        if trimmed.hasPrefix("search:") {
            let q = String(trimmed.dropFirst("search:".count))
            var url = "\(base)/twitter/tweet/advanced_search?query=\(percent(q))"
            url += "&queryType=Latest&count=\(maxResults)"
            if let c = cursor { url += "&cursor=\(percent(c))" }
            return url
        }
        return nil
    }

    static func percent(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func runCurl(argv: [String]) async -> CurlFetcher.SubprocessResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = argv
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch {
                cont.resume(returning: CurlFetcher.SubprocessResult(
                    exit: 127, stdout: Data(),
                    stderr: "spawn failed: \(error)"))
                return
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: CurlFetcher.SubprocessResult(
                exit: p.terminationStatus, stdout: outData,
                stderr: String(data: errData, encoding: .utf8) ?? ""))
        }
    }
}

/// A `Fetcher` that dispatches by source kind: TwitterAPI.io for `.x`, the
/// default `CurlFetcher` for everything else. This is what the scheduler
/// is wired with so a single `Fetcher` parameter handles every source type.
public struct CompositeFetcher: Fetcher {
    public let httpFetcher: any Fetcher
    public let twitterFetcher: any Fetcher

    public init(httpFetcher: any Fetcher = CurlFetcher(),
                twitterFetcher: any Fetcher = TwitterAPIFetcher()) {
        self.httpFetcher = httpFetcher
        self.twitterFetcher = twitterFetcher
    }

    public func fetch(_ spec: SourceSpec,
                      state: SourceState,
                      deadline: Deadline) async -> FetchOutcome {
        switch spec.kind {
        case .x:
            return await twitterFetcher.fetch(spec, state: state, deadline: deadline)
        default:
            return await httpFetcher.fetch(spec, state: state, deadline: deadline)
        }
    }
}
