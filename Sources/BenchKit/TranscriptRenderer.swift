import Foundation

/// Renders a readable per-task transcript (prompt → assistant messages → tool
/// calls + outputs → final message) from the agent rollout, for mining runs for
/// improvements. Pairs with `commands.jsonl` (exact argv/paths) and the rollout
/// JSONL (the complete machine record).
public enum TranscriptRenderer {
    public static func render(rollout: URL) -> String {
        var out = "# Agent transcript\n\n"
        guard let text = try? String(contentsOf: rollout, encoding: .utf8) else { return out + "(no rollout found)\n" }
        var toolCalls = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let p = o["payload"] as? [String: Any] {
                switch p["type"] as? String {
                case "user_message":
                    out += "## Task prompt\n\n```\n" + String((p["message"] as? String ?? "").prefix(1400)) + "\n```\n\n---\n\n"
                case "agent_message":
                    if let m = p["message"] as? String, !m.isEmpty { out += "**assistant:** \(m)\n\n" }
                case "task_complete":
                    out += "\n## Final message\n\n" + String((p["last_agent_message"] as? String ?? "").prefix(2500)) + "\n"
                default: break
                }
            }
            if let it = o["item"] as? [String: Any], it["type"] as? String == "commandExecution" {
                toolCalls += 1
                let tool = it["command"] as? String ?? "?"
                let ec = (it["exitCode"] as? Int).map(String.init) ?? "?"
                let body = String((it["aggregatedOutput"] as? String ?? "").prefix(1500))
                out += "**\u{2192} [\(tool)]** exit=\(ec)\n```\n\(body)\n```\n\n"
            }
        }
        out += "\n_(\(toolCalls) tool calls — see commands.jsonl for exact argv/paths, and the rollout JSONL for the full machine record.)_\n"
        return out
    }

    /// Find the rollout JSONL written under a task's `codexhome/sessions` tree.
    public static func findRollout(taskDir: URL) -> URL? {
        let sessions = taskDir.appendingPathComponent("codexhome/sessions")
        guard let en = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension == "jsonl" { return u }
        return nil
    }
}
