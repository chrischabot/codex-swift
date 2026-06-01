import Foundation

/// Post-hoc forensics on a run's agent rollouts — the harness-health + behavior
/// metrics we hill-climb on: success, tool-calling quality, continuation,
/// efficiency, and agility. Sourced from `result.json` + the rollout JSONL +
/// `commands.jsonl`. `codex-bench analyze <run-id>`.
public struct RolloutAnalyzer: Sendable {
    public struct TaskStats: Sendable {
        public var taskId: String
        public var reward: Int?
        public var completed = false
        // tool calling
        public var modelCalls = 0
        public var commands = 0
        public var failedCommands = 0
        public var commandTimeouts = 0
        public var testRuns = 0
        public var missingTools: Set<String> = []
        // continuation
        public var continuationRetries = 0
        // efficiency
        public var inputTokens = 0
        public var cachedInputTokens = 0
        public var outputTokens = 0
        public var costUSD = 0.0
        public var wallSec = 0.0
        // agility
        public var execs = 0
        public var edits = 0
        public var timeToFirstEditSec = -1.0
        public var diffBytes = 0
        public var cachedPct: Int { inputTokens > 0 ? cachedInputTokens * 100 / inputTokens : 0 }
        public var failPct: Int { commands > 0 ? failedCommands * 100 / commands : 0 }
    }

    public static func analyze(runDir: URL) -> [TaskStats] {
        let fm = FileManager.default
        let tasksDir = runDir.appendingPathComponent("tasks")
        let taskDirs = (try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)) ?? []
        return taskDirs.compactMap { td -> TaskStats? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: td.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            var s = TaskStats(taskId: td.lastPathComponent)
            // result.json — reward + efficiency + continuation
            if let d = try? Data(contentsOf: td.appendingPathComponent("result.json")),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                s.reward = o["reward"] as? Int
                if let a = o["agent"] as? [String: Any] {
                    s.costUSD = a["costUSD"] as? Double ?? 0
                    s.wallSec = a["agentWallSec"] as? Double ?? 0
                    s.continuationRetries = a["continuationRetries"] as? Int ?? 0
                    s.completed = a["completed"] as? Bool ?? false
                    s.diffBytes = a["diffBytes"] as? Int ?? 0
                    s.inputTokens = a["inputTokens"] as? Int ?? 0
                    s.cachedInputTokens = a["cachedInputTokens"] as? Int ?? 0
                    s.outputTokens = a["outputTokens"] as? Int ?? 0
                }
            }
            // commands.jsonl — agility (execs, edits, time-to-first-edit)
            parseCommands(td.appendingPathComponent("commands.jsonl"), into: &s)
            // rollout — tool-calling quality
            if let roll = findRollout(td) { parseRollout(roll, into: &s) }
            return s
        }.sorted { $0.taskId < $1.taskId }
    }

    private static func parseCommands(_ url: URL, into s: inout TaskStats) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let iso = ISO8601DateFormatter()
        var firstTs: Date?, firstEditTs: Date?
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let ts = (o["ts"] as? String).flatMap { iso.date(from: $0) }
            if let ts, firstTs == nil { firstTs = ts }
            switch o["kind"] as? String {
            case "exec": s.execs += 1
            case "write": s.edits += 1; if firstEditTs == nil { firstEditTs = ts }
            default: break
            }
        }
        if let a = firstTs, let b = firstEditTs { s.timeToFirstEditSec = b.timeIntervalSince(a) }
    }

    private static func parseRollout(_ roll: URL, into s: inout TaskStats) {
        guard let text = try? String(contentsOf: roll, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count" {
                s.modelCalls += 1
            }
            if let it = o["item"] as? [String: Any], it["type"] as? String == "commandExecution" {
                s.commands += 1
                let out = it["aggregatedOutput"] as? String ?? ""
                let ec = it["exitCode"] as? Int
                if it["status"] as? String == "failed" || (ec != nil && ec != 0) { s.failedCommands += 1 }
                if out.contains("timed out") { s.commandTimeouts += 1 }
                if out.range(of: #"go test|--- FAIL|ok\s+\S+|PASS|vitest|mocha|pytest|cargo test|Tests:"#,
                             options: .regularExpression) != nil { s.testRuns += 1 }
                for m in matches(#"([\w.-]+): not found"#, out) { s.missingTools.insert(m) }
            }
        }
    }

    public static func render(_ stats: [TaskStats]) -> String {
        func f(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
        var out = "task                                   rwd  calls cmds fail% TO test edits t2edit retry  cost   time  cache\n"
        for s in stats {
            out += f(s.taskId, 39)
            out += f(s.reward.map { $0 == 1 ? "✅" : "❌" } ?? "—", 4)
            out += f("\(s.modelCalls)", 6) + f("\(s.commands)", 5) + f("\(s.failPct)%", 6)
            out += f("\(s.commandTimeouts)", 3) + f("\(s.testRuns)", 5) + f("\(s.edits)", 6)
            out += f(s.timeToFirstEditSec >= 0 ? "\(Int(s.timeToFirstEditSec))s" : "—", 7)
            out += f("\(s.continuationRetries)", 6)
            out += f(String(format: "$%.2f", s.costUSD), 7)
            out += f("\(Int(s.wallSec))s", 6)
            out += "\(s.cachedPct)%\n"
        }
        // aggregate
        let n = stats.count
        let resolved = stats.filter { $0.reward == 1 }.count
        let empties = stats.filter { $0.diffBytes == 0 }.count
        func avg(_ k: (TaskStats) -> Double) -> Double { n == 0 ? 0 : stats.map(k).reduce(0,+)/Double(n) }
        out += "\nAGGREGATE  Pass@1=\(n > 0 ? resolved*100/n : 0)% (\(resolved)/\(n))"
        out += String(format: "  avgCost=$%.2f  avgTime=%.0fs  avgCalls=%.0f", avg { $0.costUSD }, avg { $0.wallSec }, avg { Double($0.modelCalls) })
        out += "  totTimeouts=\(stats.map { $0.commandTimeouts }.reduce(0,+))"
        out += "  emptyDiffs=\(empties)  avgRetries=" + String(format: "%.1f", avg { Double($0.continuationRetries) })
        out += String(format: "  avgT2Edit=%.0fs\n", avg { max($0.timeToFirstEditSec, 0) })
        return out
    }

    private static func findRollout(_ taskDir: URL) -> URL? {
        let sessions = taskDir.appendingPathComponent("codexhome/sessions")
        guard let en = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension == "jsonl" { return u }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).split(separator: "/").last.map(String.init) : nil
        }
    }
}
