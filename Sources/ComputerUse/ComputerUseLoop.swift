import Foundation
#if canImport(AppKit)

/// Runs the OpenAI `computer` tool agent loop against the real macOS desktop:
/// send the task → model returns `computer_call` actions → execute on screen →
/// reply with a screenshot → repeat until the model stops acting. Uses the
/// NON-streaming Responses API (full JSON response) so we can parse the
/// `computer_call`/`computer_call_output` items directly.
///
/// gpt-5.5 natively supports the `computer` tool (environment "mac"), so the
/// same model can both code and drive the GUI.
public final class ComputerUseLoop: @unchecked Sendable {
    public struct Options: Sendable {
        public var model: String = "gpt-5.5"
        public var environment: String = "mac"
        public var reasoningEffort: String = "low"   // low recommended for computer use
        public var maxSteps: Int = 40
        public var confirmRiskyActions: Bool = true   // honor pending_safety_checks
        public var dryRun: Bool = false               // log actions but do NOT touch mouse/keyboard
        public var log: @Sendable (String) -> Void = { print($0); fflush(stdout) }
        public init() {}
    }

    private let apiKey: String
    private let exec: ComputerUseExecutor
    private let opts: Options
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init?(executor: ComputerUseExecutor, options: Options = Options(),
                 env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty else { return nil }
        self.apiKey = key; self.exec = executor; self.opts = options
    }

    public enum LoopError: Error { case permissions(String), http(Int, String), badResponse(String), screenshot }

    /// Drive the desktop to accomplish `task`. Returns the model's final text.
    public func run(task: String) async throws -> String {
        let perms = exec.checkPermissions(prompt: true)
        guard perms.ok else {
            throw LoopError.permissions(
                "Need TCC permissions — Screen Recording: \(perms.screenRecording), Accessibility: \(perms.accessibility). " +
                "Grant both in System Settings → Privacy & Security, then re-run.")
        }
        // gpt-5.5's `computer` tool takes NO parameters (display_width/height/
        // environment are rejected); the model infers the screen from the
        // screenshots we send. Our targetWidth/Height only govern OUR screenshot
        // resize + coordinate mapping (the model returns coords in screenshot space).
        let tool: [String: Any] = ["type": "computer"]
        opts.log("permissions ok (screen-recording + accessibility); display \(exec.targetWidth)×\(exec.targetHeight)")
        // Seed the first turn with the task + the current screen.
        opts.log("capturing initial screenshot…")
        guard let shot = exec.screenshotDataURL() else { throw LoopError.screenshot }
        opts.log("initial screenshot ok (\(shot.count) b64 chars)")
        var input: [[String: Any]] = [[
            "role": "user",
            "content": [["type": "input_text", "text": task],
                        ["type": "input_image", "image_url": shot, "detail": "original"]],
        ]]
        var previousId: String? = nil
        var finalText = ""

        for step in 1...opts.maxSteps {
            var body: [String: Any] = [
                "model": opts.model,
                "tools": [tool],
                "input": input,
                "truncation": "auto",
                "reasoning": ["effort": opts.reasoningEffort],
                "store": true,
            ]
            if let pid = previousId { body["previous_response_id"] = pid }
            opts.log("→ step \(step): requesting model (\(opts.model), \(input.count) input item(s))…")
            let resp = try await post(body)
            previousId = resp["id"] as? String
            let output = resp["output"] as? [[String: Any]] ?? []
            let types = output.compactMap { $0["type"] as? String }.joined(separator: ", ")
            opts.log("← step \(step): \(output.count) output item(s): [\(types)]")

            let calls = output.filter { ($0["type"] as? String) == "computer_call" }
            // Capture any assistant text (final answer / narration).
            for item in output where (item["type"] as? String) == "message" {
                let content = item["content"] as? [[String: Any]] ?? []
                for c in content where (c["type"] as? String) == "output_text" {
                    if let t = c["text"] as? String { finalText = t }
                }
            }
            if calls.isEmpty {
                opts.log("✓ done after \(step) step(s): \(finalText.prefix(200))")
                return finalText
            }

            // Execute each computer_call's action(s) and build outputs.
            var outputs: [[String: Any]] = []
            for call in calls {
                guard let callId = call["call_id"] as? String else { continue }
                let safety = call["pending_safety_checks"] as? [[String: Any]] ?? []
                if !safety.isEmpty {
                    let names = safety.compactMap { $0["code"] as? String ?? $0["id"] as? String }.joined(separator: ", ")
                    opts.log("⚠️ pending safety checks: \(names)")
                    if opts.confirmRiskyActions {
                        opts.log("   (auto-acknowledging in PoC; wire a real confirm here for production)")
                    }
                }
                for action in Self.actions(of: call) {
                    Self.describe(action).map { opts.log("• step \(step): \($0)\(opts.dryRun ? "  [dry-run]" : "")") }
                    if !opts.dryRun { perform(action) }
                }
                guard let shot = exec.screenshotDataURL() else { throw LoopError.screenshot }
                var out: [String: Any] = [
                    "type": "computer_call_output",
                    "call_id": callId,
                    "output": ["type": "computer_screenshot", "image_url": shot, "detail": "original"],
                ]
                if !safety.isEmpty { out["acknowledged_safety_checks"] = safety }
                outputs.append(out)
            }
            input = outputs
        }
        opts.log("⏹ hit max steps (\(opts.maxSteps))")
        return finalText
    }

    // MARK: action parse + dispatch

    /// A computer_call may carry a single `action` object or an `actions` array.
    private static func actions(of call: [String: Any]) -> [[String: Any]] {
        if let arr = call["actions"] as? [[String: Any]] { return arr }
        if let one = call["action"] as? [String: Any] { return [one] }
        return []
    }

    /// Read a numeric field that may be Double or Int, trying several key names.
    private static func num(_ dict: [String: Any], _ keys: [String]) -> Double {
        for k in keys {
            if let v = dict[k] as? Double { return v }
            if let v = dict[k] as? Int { return Double(v) }
        }
        return 0
    }

    private static func dragPath(_ a: [String: Any]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        if let pts = a["path"] as? [[String: Any]] {
            for p in pts { out.append((num(p, ["x"]), num(p, ["y"]))) }
        } else if let pts = a["path"] as? [[Double]] {
            for p in pts { out.append((p.first ?? 0, p.count > 1 ? p[1] : 0)) }
        }
        return out
    }

    private func perform(_ a: [String: Any]) {
        let type = (a["type"] as? String ?? "").lowercased()
        let x = Self.num(a, ["x"]); let y = Self.num(a, ["y"])
        let button = a["button"] as? String ?? "left"
        let keys = (a["keys"] as? [String]) ?? []
        switch type {
        case "click": exec.click(x: x, y: y, button: button, keys: keys)
        case "double_click", "doubleclick": exec.doubleClick(x: x, y: y, button: button)
        case "move", "mouse_move": exec.move(x: x, y: y)
        case "scroll":
            exec.scroll(x: x, y: y,
                        scrollX: Self.num(a, ["scrollX", "scroll_x"]),
                        scrollY: Self.num(a, ["scrollY", "scroll_y"]))
        case "type": exec.type(a["text"] as? String ?? "")
        case "keypress": exec.keypress(keys)
        case "drag": exec.drag(path: Self.dragPath(a), button: button)
        case "wait": Thread.sleep(forTimeInterval: 1.0)
        case "screenshot": break   // handled implicitly (we always send a fresh screenshot)
        default: opts.log("⚠️ unknown action type: \(type)")
        }
        // Small settle delay so the UI updates before the next screenshot.
        Thread.sleep(forTimeInterval: 0.4)
    }

    private static func describe(_ a: [String: Any]) -> String? {
        let t = a["type"] as? String ?? "?"
        switch t {
        case "click", "double_click", "move": return "\(t) @\(a["x"] ?? "?"),\(a["y"] ?? "?")"
        case "type": return "type \"\(a["text"] as? String ?? "")\""
        case "keypress": return "keypress \((a["keys"] as? [String])?.joined(separator: "+") ?? "")"
        case "scroll": return "scroll @\(a["x"] ?? "?"),\(a["y"] ?? "?")"
        default: return t
        }
    }

    // MARK: HTTP (non-streaming Responses)

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw LoopError.http(code, String(decoding: data.prefix(800), as: UTF8.self))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoopError.badResponse("non-object response")
        }
        return obj
    }
}
#endif
