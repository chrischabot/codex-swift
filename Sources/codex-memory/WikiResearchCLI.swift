import Foundation
import WikiResearch
import WikiIngest
import MemoryStore
import MemoryScore   // SpendGate (wiki-research budget bucket)
import EgressGuard
import PinnedFetcher
import Tools

/// `codex-memory wiki-research "<topic>" [flags]` — run the multi-round research
/// engine LIVE: a web-search swarm gathers sources per angle, credibility-filters
/// them locally, ingests the survivors (queryable), compiles a synthesis page, and
/// terminates on the progress/gap arithmetic. Mode auto-detects (topic/question/
/// thesis); `--min-time` enables multi-round gap drilling.
enum CodexMemoryWikiResearch {
    struct Options {
        var topic = ""
        var mode: ResearchMode?
        var depth: ResearchDepth = .standard
        var sources = 5
        var perAngle = 4
        var minTime: Int64?
        var maxRounds = 3
        var json = false
        var extractClaims = true
        var progress = false      // emit NDJSON live events to stdout (for the WS job stream)
        var maxUSD: Double?        // wiki-research SpendGate ceiling override (default $40 / env)
    }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        guard !opt.topic.isEmpty else { throw CLIError(message: "wiki-research requires a topic/question") }

        // web search must be configured (OPENAI_API_KEY / PERPLEXITY_API_KEY).
        let webSearch = ResolvedWebSearch.fromEnvironment()
        if webSearch is UnconfiguredWebSearch {
            throw CLIError(message: "no web-search backend configured (set OPENAI_API_KEY or PERPLEXITY_API_KEY)")
        }

        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)
        let fetcher = PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: true)))
        let writer = WikiIngestWriter(store: bundle.store, processor: bundle.processor)
        let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent

        // Claim extraction (the producer for the trust layer) uses OpenAI directly.
        let env = ProcessInfo.processInfo.environment
        // Single shared budget bucket for the WHOLE wiki-research lane: claim extraction
        // (OpenAI chat) + the web_search swarm + the gap reflector. Mirrors the 4 sibling
        // lanes (wiki-contradictions / -librarian / -audit / -frontier), each of which
        // meters its own bucket. Without this the lane has NO ceiling on paid calls.
        let researchBudgetUSD = opt.maxUSD ?? Double(env["CODEX_MEMORY_WIKI_BUDGET_USD"] ?? "") ?? 40
        let researchGate = SpendGate(store: bundle.store, config: .init(
            monthlyCeilingUSD: researchBudgetUSD, bucket: "wiki-research",
            inputUSDPerMTok: 0.15, outputUSDPerMTok: 0.60, reservationUSD: 0.10))
        let claimExtractor: WikiClaimExtractor? = (opt.extractClaims ? (env["OPENAI_API_KEY"].map {
            WikiClaimExtractor(apiKey: $0, model: env["CODEXKIT_WIKI_CLAIM_MODEL"] ?? "gpt-4o-mini",
                               spendGate: researchGate)
        }) : nil)

        let orch = WikiResearchOrchestrator(
            probe: LiveKnowledgeProbe(retriever: bundle.retriever),
            swarm: LiveResearchSwarm(webSearch: webSearch, perAngle: opt.perAngle, spendGate: researchGate),
            compiler: LiveResearchCompiler(writer: writer, store: bundle.store, fetcher: fetcher,
                                           fetchedAt: now, vaultRoot: vaultRoot,
                                           claimExtractor: claimExtractor),
            reflector: LiveGapReflector(webSearch: webSearch, spendGate: researchGate),
            now: { Int64(Date().timeIntervalSince1970) })

        let sessionStore = ResearchSessionStore(root: vaultRoot + "/research")
        // In --progress mode, stream NDJSON events to stdout as the run proceeds.
        let onProgress: (@Sendable (ResearchProgress) -> Void)? = opt.progress
            ? ({ @Sendable ev in FileHandle.standardOutput.write(Data((WikiProgress.researchEvent(ev) + "\n").utf8)) })
            : nil
        let config = ResearchConfig(depth: opt.depth, minTimeBudget: opt.minTime,
                                    sourcesPerRound: opt.sources, maxRounds: opt.maxRounds,
                                    sessionStore: sessionStore, onProgress: onProgress)
        let sessionID = "research-\(now)"
        let result = await orch.run(input: opt.topic, sessionID: sessionID,
                                    forcedMode: opt.mode, config: config)
        // --progress: a final NDJSON result line; otherwise the human/--json summary.
        if opt.progress {
            return (WikiProgress.researchResult(result) + "\n", result.status != "failed")
        }
        return (format(result, json: opt.json), result.status != "failed")
    }

    static func format(_ r: ResearchResult, json: Bool) -> String {
        if json {
            let obj: [String: Any] = [
                "sessionID": r.sessionID, "mode": r.mode.rawValue, "status": r.status,
                "rounds": r.roundsCompleted, "sources": r.cumulativeSources,
                "pages": r.cumulativeArticles, "finalScore": r.finalScore,
                "termination": r.termination.rawValue, "flags": r.flags.map(\.rawValue),
                "error": r.error as Any,
            ]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-research [\(r.sessionID)] mode=\(r.mode.rawValue) status=\(r.status)\n"
        out += "  rounds=\(r.roundsCompleted)  sources ingested=\(r.cumulativeSources)  pages=\(r.cumulativeArticles)\n"
        out += "  final score=\(r.finalScore)  termination=\(r.termination.rawValue)\n"
        for rd in r.rounds {
            out += "  · round \(rd.round): \(rd.sourcesIngested) sources, score \(rd.score)\n"
        }
        if !r.flags.isEmpty { out += "  flags: \(r.flags.map(\.rawValue).joined(separator: ", "))\n" }
        if let e = r.error { out += "  error: \(e)\n" }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--mode":
                guard let m = ResearchMode(rawValue: try val(a).lowercased()) else { throw CLIError(message: "--mode must be topic|question|thesis") }
                o.mode = m
            case "--depth":
                guard let d = ResearchDepth(rawValue: try val(a).lowercased()) else { throw CLIError(message: "--depth must be standard|deep|retardmax") }
                o.depth = d
            case "--sources": o.sources = Int(try val(a)) ?? 5
            case "--per-angle": o.perAngle = Int(try val(a)) ?? 4
            case "--min-time": o.minTime = Int64(try val(a))
            case "--max-rounds": o.maxRounds = Int(try val(a)) ?? 3
            case "--max-usd": o.maxUSD = Double(try val(a))
            case "--no-claims": o.extractClaims = false
            case "--progress": o.progress = true
            case "--json": o.json = true
            default:
                if a.hasPrefix("-") { throw CLIError(message: "unknown flag \(a)") }
                o.topic = o.topic.isEmpty ? a : o.topic + " " + a
            }
            i += 1
        }
        return o
    }
}
