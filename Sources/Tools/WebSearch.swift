import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `@unchecked Sendable` Process box so the non-Sendable `Process` can be used
/// from the async `WebSearchBackend.search` (same pattern as the model/auth
/// HTTP clients).
private final class WSProc: @unchecked Sendable { let p = Process() }

/// Portable curl-backed JSON POST used by the web-search backends. Works on
/// Linux + macOS without URLSession; mirrors `CurlTokenExchanger` /
/// `OpenAIResponsesClient`.
enum WebHTTP {
    static func postJSON(_ url: String,
                         headers: [String: String],
                         body: Data) async -> Result<Data, ToolError> {
        let box = WSProc()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["curl", "-sS", "--max-time", "60", "-X", "POST", url,
                    "-H", "Content-Type: application/json",
                    "-H", "Accept: application/json",
                    "--data-binary", "@-"]
        for (k, v) in headers { args += ["-H", "\(k): \(v)"] }
        p.arguments = args
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch { return .failure(ToolError(message: "web_search: failed to spawn curl: \(error)")) }
        inPipe.fileHandleForWriting.write(body)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            return .failure(ToolError(message:
                "web_search: curl exit \(p.terminationStatus): "
                + String(decoding: e.prefix(300), as: UTF8.self)))
        }
        return .success(out)
    }
}

/// Primary backend: Perplexity Sonar (default `sonar-reasoning-pro`) via the
/// OpenAI-compatible `/chat/completions` endpoint. Real network call; returns
/// the answer text plus any returned citations.
public struct PerplexityWebSearch: WebSearchBackend {
    public let apiKey: String
    public let model: String
    public let endpoint: String
    public var requiredHosts: [String] {
        URL(string: endpoint)?.host.map { [$0] } ?? ["api.perplexity.ai"]
    }

    public init(apiKey: String,
                model: String = "sonar-reasoning-pro",
                endpoint: String = "https://api.perplexity.ai/chat/completions") {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    /// Deterministic, offline-testable request body.
    public static func requestBody(_ query: String, model: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system",
                 "content": "You are a web search assistant. Answer concisely and cite sources."],
                ["role": "user", "content": query],
            ],
        ]
    }

    public func search(_ query: String) async -> Result<String, ToolError> {
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(query, model: model)) else {
            return .failure(ToolError(message: "web_search(perplexity): bad request body"))
        }
        switch await WebHTTP.postJSON(endpoint,
                                      headers: ["Authorization": "Bearer \(apiKey)"],
                                      body: body) {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            guard let o = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
                return .failure(ToolError(message: "web_search(perplexity): non-JSON response"))
            }
            if let err = o["error"] as? [String: Any] {
                let m = (err["message"] as? String) ?? "\(err)"
                return .failure(ToolError(message: "web_search(perplexity): \(m)"))
            }
            let choices = o["choices"] as? [[String: Any]]
            let content = ((choices?.first?["message"] as? [String: Any])?["content"]
                           as? String) ?? ""
            var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cits = o["citations"] as? [String], !cits.isEmpty {
                text += "\n\nCitations:\n"
                    + cits.enumerated()
                        .map { "[\($0.offset + 1)] \($0.element)" }
                        .joined(separator: "\n")
            } else if let results = o["search_results"] as? [[String: Any]],
                      !results.isEmpty {
                text += "\n\nSources:\n" + results.compactMap { r -> String? in
                    let t = (r["title"] as? String) ?? ""
                    let u = (r["url"] as? String) ?? ""
                    return u.isEmpty ? nil : "- \(t) \(u)"
                }.joined(separator: "\n")
            }
            return text.isEmpty
                ? .failure(ToolError(message: "web_search(perplexity): empty result"))
                : .success(text)
        }
    }
}

/// Fallback backend: the OpenAI Responses API built-in `web_search` tool
/// (https://developers.openai.com/api/docs/guides/tools-web-search). Real
/// network call; extracts the assistant text plus URL citations.
public struct OpenAIWebSearch: WebSearchBackend {
    public let apiKey: String
    public let model: String
    public let toolType: String
    public let endpoint: String
    public var requiredHosts: [String] {
        URL(string: endpoint)?.host.map { [$0] } ?? ["api.openai.com"]
    }

    public init(apiKey: String,
                model: String = "gpt-4o-mini",
                toolType: String = "web_search",
                endpoint: String = "https://api.openai.com/v1/responses") {
        self.apiKey = apiKey
        self.model = model
        self.toolType = toolType
        self.endpoint = endpoint
    }

    public static func requestBody(_ query: String, model: String,
                                   toolType: String) -> [String: Any] {
        [
            "model": model,
            "tools": [["type": toolType]],
            "tool_choice": "auto",
            "input": query,
        ]
    }

    private func extractText(_ o: [String: Any]) -> String {
        var text = ""
        var citations: [String] = []
        if let output = o["output"] as? [[String: Any]] {
            for item in output where (item["type"] as? String) == "message" {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if let s = c["text"] as? String { text += s }
                        if let anns = c["annotations"] as? [[String: Any]] {
                            for a in anns where (a["type"] as? String) == "url_citation" {
                                let u = (a["url"] as? String) ?? ""
                                let t = (a["title"] as? String) ?? ""
                                if !u.isEmpty { citations.append("- \(t) \(u)") }
                            }
                        }
                    }
                }
            }
        }
        if text.isEmpty, let ot = o["output_text"] as? String { text = ot }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !citations.isEmpty {
            text += "\n\nSources:\n" + citations.joined(separator: "\n")
        }
        return text
    }

    public func search(_ query: String) async -> Result<String, ToolError> {
        guard let body = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(query, model: model,
                                             toolType: toolType)) else {
            return .failure(ToolError(message: "web_search(openai): bad request body"))
        }
        switch await WebHTTP.postJSON(endpoint,
                                      headers: ["Authorization": "Bearer \(apiKey)"],
                                      body: body) {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            guard let o = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
                return .failure(ToolError(message: "web_search(openai): non-JSON response"))
            }
            if let err = o["error"] as? [String: Any] {
                let m = (err["message"] as? String) ?? "\(err)"
                return .failure(ToolError(message: "web_search(openai): \(m)"))
            }
            let text = extractText(o)
            return text.isEmpty
                ? .failure(ToolError(message: "web_search(openai): empty result"))
                : .success(text)
        }
    }
}

/// Primary → fallback composition. The fallback is attempted only when the
/// primary fails; both failures are surfaced together.
public struct CompositeWebSearch: WebSearchBackend {
    private let primary: any WebSearchBackend
    private let fallback: (any WebSearchBackend)?
    public var requiredHosts: [String] {
        var hosts = primary.requiredHosts
        if let fallback { hosts += fallback.requiredHosts }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }
    public init(primary: any WebSearchBackend, fallback: (any WebSearchBackend)?) {
        self.primary = primary
        self.fallback = fallback
    }
    public func search(_ query: String) async -> Result<String, ToolError> {
        switch await primary.search(query) {
        case .success(let s):
            return .success(s)
        case .failure(let pe):
            guard let fb = fallback else { return .failure(pe) }
            switch await fb.search(query) {
            case .success(let s):
                return .success(s)
            case .failure(let fe):
                return .failure(ToolError(message:
                    "web_search failed — primary: \(pe.message); fallback: \(fe.message)"))
            }
        }
    }
}

/// Returned only when NO provider key is configured. This is an explicit,
/// actionable error (an environment constraint), not a silent stub.
public struct UnconfiguredWebSearch: WebSearchBackend {
    public init() {}
    public func search(_ query: String) async -> Result<String, ToolError> {
        .failure(ToolError(message:
            "web_search requires PERPLEXITY_API_KEY (preferred: sonar-reasoning-pro) "
            + "or OPENAI_API_KEY (OpenAI web_search tool fallback); neither is set"))
    }
}

/// Resolves the production web-search backend from the environment: Perplexity
/// (primary) with the OpenAI web_search tool as fallback. This is what the
/// shipped daemon and `DefaultTools` use — web_search is never disabled in the
/// real product.
public enum ResolvedWebSearch {
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> any WebSearchBackend {
        func nonEmpty(_ k: String) -> String? {
            if let v = env[k], !v.isEmpty { return v }
            return nil
        }
        let pxModel = nonEmpty("CODEXKIT_PERPLEXITY_MODEL") ?? "sonar-reasoning-pro"
        let oaModel = nonEmpty("CODEXKIT_WEBSEARCH_MODEL") ?? "gpt-4o-mini"
        let oaToolType = nonEmpty("CODEXKIT_OPENAI_WEBSEARCH_TYPE") ?? "web_search"
        let perplexity = nonEmpty("PERPLEXITY_API_KEY")
            .map { PerplexityWebSearch(apiKey: $0, model: pxModel) }
        let openai = nonEmpty("OPENAI_API_KEY")
            .map { OpenAIWebSearch(apiKey: $0, model: oaModel, toolType: oaToolType) }
        if let p = perplexity {
            return CompositeWebSearch(primary: p, fallback: openai)
        }
        if let o = openai {
            return CompositeWebSearch(primary: o, fallback: nil)
        }
        return UnconfiguredWebSearch()
    }
}
