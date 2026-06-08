import Foundation
import Mem0Core
import Mem0Extension
import Mem0Store
import Tools
#if os(macOS)
import Darwin
#endif

/// Equal-workload driver for the native Swift mem0 engine — the framework-overhead
/// counterpart to the Rust `bench_run` example and Python `compare.py`. Runs the
/// SAME workload (N raw adds with infer=false + M searches + one getAll) using a
/// fixed hash-based mock embedder (no network), an in-process vector store, and
/// in-memory history — isolating the orchestration cost that differs between the
/// implementations. Prints timings + peak RSS as JSON.
///
/// Usage:
///   mem0-bench [N=2000] [M=500]
///   mem0-bench admin [N=5000] [M=200]

func peakRSSkb() -> UInt64? {
    // Linux: VmHWM (peak resident set) from /proc/self/status, in kB.
    if let s = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
        for line in s.split(separator: "\n") where line.hasPrefix("VmHWM:") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            if parts.count >= 2, let v = UInt64(parts[1]) { return v }
        }
    }
    #if os(macOS)
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 {
        return UInt64(usage.ru_maxrss) / 1024
    }
    #endif
    return nil
}

@main
struct Bench {
    static func main() async {
        let args = CommandLine.arguments
        if args.dropFirst().first == "admin" {
            await runAdmin(args: args)
            return
        }
        let n = args.count > 1 ? (Int(args[1]) ?? 2000) : 2000
        let m = args.count > 2 ? (Int(args[2]) ?? 500) : 500

        let mem = Mem0Engine(config: Mem0Config(historyDbPath: ":memory:"),
                             embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                             vectorStore: InMemoryVectorStore(), historyStore: InMemoryHistoryStore())
        let opts = AddOptions(userID: "u1", infer: false)
        let filters: JSONObject = ["user_id": .string("u1")]

        let t0 = Date()
        for i in 0..<n {
            _ = try? await mem.add(.text("memory item \(i) about hiking cooking travel"), opts)
        }
        let t1 = Date()
        for _ in 0..<m {
            _ = try? await mem.search("hiking travel", filters, SearchOptions())
        }
        let t2 = Date()
        _ = try? await mem.getAll(filters, topK: 20)
        let t3 = Date()

        let out: [String: Any] = [
            "impl": "swift",
            "n_add": n,
            "add_ms": t1.timeIntervalSince(t0) * 1000.0,
            "n_search": m,
            "search_ms": t2.timeIntervalSince(t1) * 1000.0,
            "get_all_ms": t3.timeIntervalSince(t2) * 1000.0,
            "peak_rss_kb": peakRSSkb() as Any,
        ]
        printJSON(out)
    }

    static func runAdmin(args: [String]) async {
        let n = args.count > 2 ? (Int(args[2]) ?? 5000) : 5000
        let m = args.count > 3 ? (Int(args[3]) ?? 200) : 200
        guard n > 0, m > 0 else {
            printJSON(["valid": false, "error": "N and M must be positive"])
            return
        }
        let path = NSTemporaryDirectory() + "mem0-admin-bench-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let store = try? Mem0SQLiteStore(path: path) else {
            printJSON(["valid": false, "error": "cannot open temp sqlite store"])
            return
        }
        let mem = Mem0Engine(config: Mem0Config(historyDbPath: path),
                             embedder: MockEmbedder(dims: 64), llm: MockLLM(),
                             vectorStore: store, historyStore: store)
        let scope = Mem0Scope(userId: "u42")
        let list = Mem0ListTool(engine: mem, scope: scope, defaultLimit: 50)
        let update = Mem0UpdateTool(engine: mem, scope: scope)
        let history = Mem0HistoryTool(engine: mem, scope: scope)
        let privacy = Mem0PrivacyTool(engine: mem, scope: scope)
        let delete = Mem0DeleteTool(engine: mem, scope: scope)
        var scopedIDs: [String] = []
        var failures = 0

        let seed0 = Date()
        for i in 0..<n {
            let user = "u\(i % 100)"
            let category = (i % 2 == 0) ? "wardrobe" : "project"
            let sensitivity = (i % 5 == 0) ? "personal" : "normal"
            let added = try? await mem.add(
                .text("memory item \(i) for \(user) about \(category)"),
                AddOptions(userID: user, metadata: [
                    "category": .string(category),
                    "sensitivity": .string(sensitivity),
                ], infer: false))
            if added == nil { failures += 1 }
            if user == scope.userId, let id = added?.first?.id {
                scopedIDs.append(id)
            }
        }
        let seed1 = Date()

        let list0 = Date()
        for _ in 0..<m {
            let result = try? await list.run(toolCall("mem0_list", #"{"category":"wardrobe","limit":50}"#),
                                             cwd: "/tmp")
            recordToolResult(result, failures: &failures)
        }
        let list1 = Date()

        let updateIDs = Array(scopedIDs.prefix(min(scopedIDs.count, max(1, m / 2))))
        let update0 = Date()
        for (idx, id) in updateIDs.enumerated() {
            let result = try? await update.run(
                toolCall("mem0_update",
                         #"{"id":"\#(id)","text":"updated memory \#(idx) for benchmark","metadata":{"category":"benchmark"}}"#),
                cwd: "/tmp")
            recordToolResult(result, failures: &failures)
        }
        let update1 = Date()

        let history0 = Date()
        for id in updateIDs {
            let result = try? await history.run(toolCall("mem0_history", #"{"id":"\#(id)"}"#),
                                                cwd: "/tmp")
            recordToolResult(result, failures: &failures)
        }
        let history1 = Date()

        let export0 = Date()
        for _ in 0..<max(1, m / 20) {
            let result = try? await privacy.run(toolCall("mem0_privacy", #"{"operation":"export","limit":1000}"#),
                                                cwd: "/tmp")
            recordToolResult(result, failures: &failures)
        }
        let export1 = Date()

        let deleteIDs = Array(updateIDs.prefix(min(updateIDs.count, max(1, m / 4))))
        let delete0 = Date()
        for id in deleteIDs {
            let result = try? await delete.run(toolCall("mem0_delete", #"{"id":"\#(id)"}"#),
                                               cwd: "/tmp")
            recordToolResult(result, failures: &failures)
        }
        let delete1 = Date()
        for id in deleteIDs {
            if (try? await mem.get(id)) != nil { failures += 1 }
        }

        let out: [String: Any] = [
            "valid": failures == 0,
            "failures": failures,
            "impl": "swift",
            "mode": "admin",
            "seed_memories": n,
            "scoped_memories": scopedIDs.count,
            "seed_ms": seed1.timeIntervalSince(seed0) * 1000.0,
            "list_iterations": m,
            "list_ms": list1.timeIntervalSince(list0) * 1000.0,
            "update_iterations": updateIDs.count,
            "update_ms": update1.timeIntervalSince(update0) * 1000.0,
            "history_iterations": updateIDs.count,
            "history_ms": history1.timeIntervalSince(history0) * 1000.0,
            "export_iterations": max(1, m / 20),
            "export_ms": export1.timeIntervalSince(export0) * 1000.0,
            "delete_iterations": deleteIDs.count,
            "delete_ms": delete1.timeIntervalSince(delete0) * 1000.0,
            "peak_rss_kb": peakRSSkb() as Any,
        ]
        printJSON(out)
    }

    static func toolCall(_ name: String, _ json: String) -> ToolCall {
        ToolCall(callId: UUID().uuidString, name: name, argumentsJSON: json)
    }

    static func recordToolResult(_ result: ToolResult?, failures: inout Int) {
        guard let result, result.success else {
            failures += 1
            return
        }
    }

    static func printJSON(_ object: [String: Any]) {
        var normalized = object
        for (key, value) in normalized {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let child = mirror.children.first {
                    normalized[key] = child.value
                } else {
                    normalized[key] = NSNull()
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: normalized) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
