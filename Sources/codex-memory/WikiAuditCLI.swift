import Foundation
import MemoryStore
import MemoryScore
import PinnedFetcher
import EgressGuard

/// `codex-memory wiki-audit [--json --limit N] [--escalate]` — the audit output-drift
/// scan over the compiled wiki pages: which pages were compiled from a claim that has
/// since changed (so the page may no longer reflect its evidence). Pure timestamps, no
/// model — the cheap structural pass (Pass 2). With `--escalate` (and `OPENAI_API_KEY`),
/// Pass 3 truth-escalation RE-VERIFIES the drifted pages: re-fetch cited URLs through
/// EgressGuard+PinnedFetcher + a confirm/disprove frontier pass (spend-gated), persisting
/// `<vault>/.audit/verdicts.json`. Drifted pages list first.
///
/// NOTE: design §5.D frames Pass 3 as default-on with `--quick` to skip it; we
/// deliberately INVERT that to default-OFF / opt-in `--escalate`, so a plain
/// `wiki-audit` never spends model budget or touches the network without consent.
enum CodexMemoryWikiAudit {
    struct Options { var json = false; var limit = 50; var escalate = false }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        let bundle = try await CodexMemoryRun.assemble()
        let scan = try await bundle.store.auditDriftScan()

        var verdicts: [AuditPageVerdict] = []
        var note: String?
        if opt.escalate {
            let drifted = scan.filter { $0.status == .drifted || $0.status == .indirectlyDrifted }.map(\.id)
            if drifted.isEmpty {
                note = "no drifted pages to escalate"
            } else if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
                      !key.isEmpty {
                let env = ProcessInfo.processInfo.environment
                let model = env["CODEXKIT_WIKI_AUDIT_MODEL"] ?? "gpt-4o-mini"
                let gate = SpendGate(store: bundle.store, config: SpendGate.Config(
                    monthlyCeilingUSD: 20, bucket: "wiki-audit",
                    inputUSDPerMTok: 0.15, outputUSDPerMTok: 0.60, reservationUSD: 0.05))
                let fetcher = PinnedAuditFetcher(fetcher: PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: true))))
                let judge = WikiClaimAdjudicator(apiKey: key, model: model, spendGate: gate)
                let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
                verdicts = await AuditTruthEscalation.escalate(store: bundle.store, driftedIDs: drifted,
                                                               fetcher: fetcher, judge: judge, limit: opt.limit)
                AuditTruthEscalation.persist(vaultRoot: vaultRoot, verdicts: verdicts,
                                             now: Int64(Date().timeIntervalSince1970))
            } else {
                note = "Pass-3 escalation skipped: set OPENAI_API_KEY to re-verify drifted pages"
            }
        }
        return (format(scan, verdicts: verdicts, note: note, opt: opt), true)
    }

    static func format(_ scan: [(id: Int64, status: DriftStatus)], verdicts: [AuditPageVerdict] = [],
                       note: String? = nil, opt: Options) -> String {
        let drifted = scan.filter { $0.status == .drifted }
        let indirect = scan.filter { $0.status == .indirectlyDrifted }
        let verdictByID = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.pageID, $0) })
        if opt.json {
            let rows = scan.prefix(opt.limit).map { row -> [String: Any] in
                var r: [String: Any] = ["id": NSNumber(value: row.id), "status": row.status.rawValue]
                if let v = verdictByID[row.id] { r["verdict"] = v.verdict.rawValue }
                return r
            }
            var obj: [String: Any] = ["pages": scan.count, "drifted": drifted.count,
                                      "indirectlyDrifted": indirect.count, "pagesDetail": rows,
                                      "escalated": verdicts.count,
                                      "contradicted": verdicts.filter { $0.verdict == .contradicted }.count]
            if let note { obj["escalation_note"] = note }
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-audit: \(scan.count) page(s) — \(drifted.count) drifted, \(indirect.count) indirectly drifted"
        out += verdicts.isEmpty ? "\n" : ", \(verdicts.count) escalated (\(verdicts.filter { $0.verdict == .contradicted }.count) contradicted)\n"
        for row in scan.prefix(opt.limit) where row.status != .current {
            out += "  ⚠ doc \(row.id)  \(row.status.rawValue)"
            if let v = verdictByID[row.id] { out += "  → \(v.verdict.rawValue)" }
            out += "\n"
        }
        if drifted.isEmpty && indirect.isEmpty { out += "  (all pages current)\n" }
        if let note { out += "  · \(note)\n" }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        while i < args.count {
            switch args[i] {
            case "--json": o.json = true
            case "--escalate": o.escalate = true
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }
}
