import Foundation
import WikiResearch
import WikiIngest

/// NDJSON progress formatters for the `--progress` CLI mode. codexd's WikiJobRunner
/// spawns the CLI with `--progress`, reads these single-line JSON objects from
/// stdout, and forwards each as a `wiki/job/event` (type=event) / `wiki/job/done`
/// (type=result) WS notification. One object per line; stdout is unbuffered.
enum WikiProgress {
    static func line(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj,
              options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: research

    static func researchEvent(_ e: ResearchProgress) -> String {
        var o: [String: Any] = ["type": "event"]
        switch e {
        case .started(let mode):
            o["kind"] = "started"; o["mode"] = mode.rawValue
        case .roundStarted(let r):
            o["kind"] = "round_started"; o["round"] = r
        case .sourcesGathered(let r, let c):
            o["kind"] = "sources"; o["round"] = r; o["count"] = c
        case .compiled(let r, let w, let cl):
            o["kind"] = "compiled"; o["round"] = r; o["written"] = w; o["claims"] = cl
        case .roundCompleted(let r, let s):
            o["kind"] = "round_completed"; o["round"] = r; o["score"] = s
        case .finished(let st, let r, let s):
            o["kind"] = "finished"; o["status"] = st; o["rounds"] = r; o["score"] = s
        }
        return line(o)
    }

    static func researchResult(_ r: ResearchResult) -> String {
        line([
            "type": "result", "sessionID": r.sessionID, "mode": r.mode.rawValue,
            "status": r.status, "rounds": r.roundsCompleted, "sources": r.cumulativeSources,
            "pages": r.cumulativeArticles, "finalScore": r.finalScore,
            "termination": r.termination.rawValue,
        ])
    }

    // MARK: ingest

    static func ingestEvent(_ e: WikiIngestOrchestrator.Progress) -> String {
        var o: [String: Any] = ["type": "event"]
        switch e {
        case .candidate(let seq, let uri, let status):
            o["kind"] = "candidate"; o["seq"] = seq; o["uri"] = uri; o["status"] = status
        case .finished(let w, let s, let f):
            o["kind"] = "finished"; o["written"] = w; o["skipped"] = s; o["failed"] = f
        }
        return line(o)
    }

    static func ingestResult(_ s: WikiIngestOrchestrator.Summary) -> String {
        line([
            "type": "result", "jobID": s.jobID, "status": s.status, "candidates": s.candidates,
            "written": s.written, "skipped": s.skipped, "failed": s.failed,
            "cursor": s.cursor as Any,
        ])
    }
}
