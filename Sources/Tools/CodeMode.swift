import Foundation
import InfraPrimitives

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Pure, portable helpers faithful to codex `code-mode` `description.rs`.
/// These run identically on every platform (no JavaScriptCore needed).
public enum CodeMode {
    /// Upstream `codex_code_mode::PUBLIC_TOOL_NAME` — the model-visible name
    /// of the JavaScript orchestration tool.
    public static let publicToolName = "exec"
    /// Upstream `codex_code_mode::WAIT_TOOL_NAME` — the companion tool used to
    /// resume a yielded `exec` cell.
    public static let waitToolName = "wait"

    /// codex `normalize_code_mode_identifier`: lowercase, every non
    /// ASCII-alphanumeric scalar becomes `_`, consecutive `_` collapse,
    /// leading/trailing `_` are trimmed, empty result becomes `"_"`.
    public static func normalizeIdentifier(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var lastUnderscore = false
        for ch in lower.unicodeScalars {
            let isAlnum = (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "z")
            if isAlnum {
                out.unicodeScalars.append(ch)
                lastUnderscore = false
            } else {
                if !lastUnderscore { out.append("_") }
                lastUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "_" : out
    }

    /// codex `is_code_mode_nested_tool`: the `exec` tool (and its `wait`
    /// companion) plus already-namespaced MCP tools (`mcp__…`) are NOT
    /// re-nested inside the JS sandbox; everything else is eligible.
    /// Matches upstream `description.rs:is_code_mode_nested_tool` which
    /// excludes both `PUBLIC_TOOL_NAME` (`exec`) and `WAIT_TOOL_NAME` (`wait`).
    public static func isNestedTool(_ name: String) -> Bool {
        name != publicToolName && name != waitToolName && !name.hasPrefix("mcp__")
    }

    /// codex `render_code_mode_sample`: a deterministic JS usage sample
    /// listing `await callTool("<name>", { ... })` for each eligible tool,
    /// sorted (no Set ordering) so prompt-cache stays stable.
    public static func renderSample(toolNames: [String]) -> String {
        var lines = [
            "// code-mode: write JavaScript for a plain JavaScriptCore runtime.",
            "// No Node.js (`require`/`fs`/`process`), no browser APIs (no DOM).",
            "// For any side effect, call a codex tool via:",
            "//   const r = await callTool(\"<tool>\", { ...args });",
            "// Use this to orchestrate multi-step tool flows; do NOT edit files",
            "// in JS — use apply_patch/write_file tools.",
        ]
        for name in toolNames.filter(isNestedTool).sorted() {
            lines.append("// const r = await callTool(\"\(name)\", {});")
        }
        lines.append("// return <value>;")
        return lines.joined(separator: "\n")
    }
}

/// The `exec` tool (upstream `codex_code_mode::PUBLIC_TOOL_NAME`): runs
/// model-authored JavaScript that can call other tools through an injected
/// `@Sendable` dispatch bridge. It is a `Sendable` value type bound via the
/// closure exactly like `ToolSearchTool` / the multi-agent tools.
///
/// Caveat (upstream parity gap): upstream evaluates the script in a V8
/// isolate and exposes a rich global surface — `tools.<name>(...)`, `text()`,
/// `image()`, `store()`, `load()`, `notify()`, `yield_control()`, `exit()`,
/// `setTimeout`/`clearTimeout`, and the `ALL_TOOLS` metadata array. The Swift
/// build runs the script in JavaScriptCore with a single `callTool(name, args)`
/// bridge. The rich globals and the cell-yielding semantics that underpin
/// upstream's `wait` tool are deliberately left as future work.
public struct CodeModeTool: Tool {
    public let name = CodeMode.publicToolName
    public let parallelSafe = false
    public var toolDescription: String {
        "Run model-authored JavaScript in a plain JavaScriptCore runtime — "
            + "NOT Node.js and NOT a browser. There is no `require`, no `import`, "
            + "no `fs`, no `process`, no DOM, no network APIs. To do filesystem, "
            + "shell, or any other side-effect work, call codex tools through "
            + "`await callTool(\"<tool>\", { ...args })`. Return a value (or set "
            + "`globalThis.result`) to produce output. Use this tool to compose "
            + "multiple tool calls with control flow; do NOT use it to edit "
            + "files directly — prefer `apply_patch`/`write_file` for that."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"source":{"type":"string"},"timeoutMs":{"type":"integer"}},"required":["source"],"additionalProperties":false}"#
    }

    private let dispatch: @Sendable (String, String, String, Int) async -> String
    private let toolNames: [String]

    public init(toolNames: [String] = [],
                dispatch: @escaping @Sendable (String, String, String, Int) async -> String) {
        self.toolNames = toolNames
        self.dispatch = dispatch
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let source: String; let timeoutMs: Int? }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid exec arguments",
                              success: false, truncated: false)
        }
        let (out, ok) = await CodeModeRuntime.evaluate(source: args.source,
                                                       cwd: cwd,
                                                       dispatch: dispatch,
                                                       timeoutMs: args.timeoutMs ?? 5000)
        return ToolResult(callId: call.callId, output: out, success: ok, truncated: false)
    }
}

/// The `wait` tool (upstream `codex_code_mode::WAIT_TOOL_NAME`): companion to
/// the `exec` tool. Upstream's V8-backed `exec` can yield a "cell" back to the
/// model when a script is still running (returning `Script running with cell
/// ID …`); the model then calls `wait` with that `cell_id` to drain the next
/// chunk of output, or to terminate the cell.
///
/// The Swift JavaScriptCore runtime does NOT (yet) support cell yielding — the
/// `exec` tool always runs the script to completion or times out — so the
/// Swift `wait` tool's runtime is a stub that returns an explicit
/// "no live cell" message. It is registered purely so the tool inventory and
/// JSON schema match upstream's `create_wait_tool()` exactly. See the
/// `CodeModeTool` caveat above; full cell-yielding semantics are tracked as
/// future parity work alongside the rich V8 globals.
public struct WaitTool: Tool {
    public let name = CodeMode.waitToolName
    public let parallelSafe = false
    public var toolDescription: String {
        // Mirror upstream `wait_spec.rs:create_wait_tool()` description:
        // a one-line summary followed by `build_wait_tool_description()`.
        let body = """
            - Use `wait` only after `exec` returns `Script running with cell ID ...`.
            - `cell_id` identifies the running `exec` cell to resume.
            - `yield_time_ms` controls how long to wait for more output before yielding again. If omitted, `wait` uses its default wait timeout.
            - `max_tokens` limits how much new output this wait call returns.
            - `terminate: true` stops the running cell instead of waiting for more output.
            - `wait` returns only the new output since the last yield, or the final completion or termination result for that cell.
            - If the cell is still running, `wait` may yield again with the same `cell_id`.
            - If the cell has already finished, `wait` returns the completed result and closes the cell.
            """
        return "Waits on a yielded `\(CodeMode.publicToolName)` cell and returns new output or completion.\n\(body.trimmingCharacters(in: .newlines))"
    }
    public var jsonSchema: String {
        // Match upstream `wait_spec.rs::create_wait_tool()` byte-for-byte in
        // shape: properties `cell_id` (string, required), `yield_time_ms`
        // (number), `max_tokens` (number), `terminate` (boolean);
        // `additionalProperties: false`.
        #"{"type":"object","properties":{"cell_id":{"type":"string","description":"Identifier of the running exec cell."},"yield_time_ms":{"type":"number","description":"How long to wait (in milliseconds) for more output before yielding again."},"max_tokens":{"type":"number","description":"Maximum number of output tokens to return for this wait call."},"terminate":{"type":"boolean","description":"Whether to terminate the running exec cell."}},"required":["cell_id"],"additionalProperties":false}"#
    }

    public init() {}

    public func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        // The Swift `exec` runtime never yields cells, so any `wait` call is
        // by definition stale. Surface that honestly instead of silently
        // succeeding.
        struct Args: Decodable {
            let cell_id: String?
            let terminate: Bool?
        }
        let args = (try? JSONDecoder().decode(
            Args.self,
            from: Data(call.argumentsJSON.utf8))) ?? Args(cell_id: nil, terminate: nil)
        let cellID = args.cell_id ?? "<missing>"
        let verb = (args.terminate ?? false) ? "terminate" : "wait on"
        let msg = "no live exec cell to \(verb) (cell_id=\(cellID)); "
            + "the Swift `exec` runtime does not yet support cell yielding"
        return ToolResult(callId: call.callId, output: msg,
                          success: false, truncated: false)
    }
}

/// The JS execution engine. macOS uses a real JavaScriptCore runtime; Linux
/// returns an honest, actionable gated message (never a silent stub).
public enum CodeModeRuntime {

    #if canImport(JavaScriptCore)
    /// Bridge box for the synchronous-host → async-Swift hop. The JSC host
    /// callback is synchronous, so we block its thread on a semaphore while a
    /// detached Task drives the async `dispatch`. `@unchecked Sendable`
    /// because access is serialized by the semaphore handshake.
    private final class Box: @unchecked Sendable { var s = "" }
    #endif

    public static func evaluate(source: String,
                                cwd: String = ".",
                                dispatch: @escaping @Sendable (String, String, String, Int) async -> String,
                                timeoutMs: Int) async -> (String, Bool) {
        let cap = min(max(timeoutMs, 100), 60_000)
        #if canImport(JavaScriptCore)
        // Race JavaScript execution against the requested timeout so runaway
        // model-authored code returns a bounded, explicit failure.
        return await withTaskGroup(of: (String, Bool)?.self) { group in
            group.addTask {
                await Self.runJavaScript(source: source, cwd: cwd, dispatch: dispatch, cap: cap)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(cap))
                return ("code-mode timed out", false)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ("code-mode timed out", false)
        }
        #else
        return ("code-mode requires the JavaScriptCore runtime, available on the macOS build (MACOS-COMPLETION: STATUS.md). The JS\u{2194}tool bridge contract is: globalThis.callTool(name, args) -> tool output.", false)
        #endif
    }

    #if canImport(JavaScriptCore)
    /// Run model-authored JavaScript in JavaScriptCore with the Swift tool
    /// bridge installed as `globalThis.callTool`.
    private static func runJavaScript(source: String,
                                      cwd: String,
                                      dispatch: @escaping @Sendable (String, String, String, Int) async -> String,
                                      cap: Int) async -> (String, Bool) {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, Bool), Never>) in
            let q = DispatchQueue(label: "codex.codemode.jsc")
            q.async {
                guard let context = JSContext() else {
                    cont.resume(returning: ("code-mode error: failed to create JSContext", false))
                    return
                }

                // Synchronous host bridge: block the JSC thread on a
                // semaphore while a detached Task drives async `dispatch`,
                // with a bounded wait so a slow tool can never deadlock.
                let hostCall: @convention(block) (String, String) -> String = { name, argsJSON in
                    let sem = DispatchSemaphore(value: 0)
                    let box = Box()
                    Task.detached {
                        box.s = await dispatch(name, argsJSON, cwd, cap)
                        sem.signal()
                    }
                    _ = sem.wait(timeout: .now() + .milliseconds(cap))
                    return box.s
                }
                context.setObject(hostCall,
                                  forKeyedSubscript: "__codex_call_tool" as NSString)

                // Base bridge (callTool + console) + the upstream code-mode
                // OUTPUT-HELPER surface (P5b): scripts compose a structured output
                // by calling image()/generatedImage()/text(), and keep per-run
                // state via store()/load(). The host collects `__codex_output`
                // after the run, validates it (#27732: no remote image URLs), and
                // appends it to the tool output. Helpers VALIDATE in JS for early
                // feedback, but the host re-validates (a script can push to
                // `__codex_output` directly), so the security rule is authoritative.
                let prelude = """
                var __logs=[];
                var console={log:function(){__logs.push(Array.prototype.slice.call(arguments).map(String).join(' '));}};
                globalThis.callTool=function(n,a){var r=__codex_call_tool(n, JSON.stringify(a||{})); try { return JSON.parse(r); } catch(e) { return r; } };
                globalThis.__codex_output=[];
                globalThis.__codex_store={};
                function __codex_imageUrl(arg){
                  var u=(typeof arg==='string')?arg:(arg&&arg.image_url);
                  if(u==null) throw new Error('image: expected a string URL or { image_url }');
                  // Positive allow-list (#27732): only base64 data: URIs are
                  // permitted. Strip leading whitespace/control chars (code<=32)
                  // first so a smuggled remote URL cannot masquerade as data:.
                  var l=String(u).toLowerCase();
                  while(l.length && l.charCodeAt(0)<=32) l=l.slice(1);
                  if(l.indexOf("data:")!==0)
                    throw new Error("Tool call failed: remote image URLs are not supported in tool outputs. Pass a base64 data URI instead");
                  return u;
                }
                globalThis.image=function(arg,detail){
                  var u=__codex_imageUrl(arg);
                  var d=(detail!=null)?detail:(arg&&typeof arg==='object'?arg.detail:null);
                  __codex_output.push({type:'image', image_url:u, detail:(d!=null?d:null)});
                };
                globalThis.generatedImage=function(result){
                  if(!result||result.image_url==null) throw new Error('generatedImage: expected { image_url }');
                  var u=__codex_imageUrl(result.image_url);
                  __codex_output.push({type:'generated_image', image_url:u, output_hint:(result.output_hint!=null?result.output_hint:null)});
                };
                globalThis.text=function(s){ __codex_output.push({type:'text', text:String(s)}); };
                globalThis.store=function(k,v){ __codex_store[String(k)]=v; };
                globalThis.load=function(k){ var v=__codex_store[String(k)]; return v===undefined?null:v; };
                """
                context.evaluateScript(prelude)

                let wrapped = "(function(){\n" + source + "\n})()"
                let value = context.evaluateScript(wrapped)

                if let exc = context.exception {
                    cont.resume(returning: ("code-mode error: \(exc)", false))
                    return
                }

                var output = ""
                if let value = value, !value.isUndefined, !value.isNull {
                    if value.isObject || value.isArray {
                        if let json = context.objectForKeyedSubscript("JSON"),
                           let stringify = json.objectForKeyedSubscript("stringify"),
                           let s = stringify.call(withArguments: [value])?.toString() {
                            output = s
                        } else {
                            output = value.toString() ?? ""
                        }
                    } else {
                        output = value.toString() ?? ""
                    }
                }

                if let logsValue = context.objectForKeyedSubscript("__logs"),
                   let arr = logsValue.toArray(), !arr.isEmpty {
                    let joined = arr.map { "\($0)" }.joined(separator: "\n")
                    output += "\n[console]\n" + joined
                }

                // Collect the code-mode OUTPUT items the script composed. We
                // serialize with JavaScriptCore's own `JSON.stringify` rather
                // than Foundation's `JSONSerialization`: a non-finite Double
                // (NaN/Infinity) anywhere in `__codex_output` makes
                // `JSONSerialization.data(withJSONObject:)` raise an Obj-C
                // NSException that `try?` does NOT catch, aborting the whole
                // process — and the script controls these values. JS renders
                // NaN/Infinity as `null`, so it can never crash the host.
                var outputJSON: String? = nil
                if let outVal = context.objectForKeyedSubscript("__codex_output"),
                   !outVal.isUndefined, !outVal.isNull,
                   let stringify = context.objectForKeyedSubscript("JSON")?
                       .objectForKeyedSubscript("stringify"),
                   let s = stringify.call(withArguments: [outVal])?.toString(),
                   s != "[]", s != "undefined", s != "null" {
                    outputJSON = s
                }
                // #27732 (AUTHORITATIVE host-side rule): a script can bypass the
                // JS helper validation by pushing to `__codex_output` directly,
                // so the host re-validates here against a POSITIVE allow-list —
                // every image item's `image_url` must be a String that, once
                // leading whitespace/control chars are stripped, begins with
                // `data:`. Anything else (remote URL, whitespace-smuggled URL,
                // or a non-String value) fails closed.
                if let json = outputJSON,
                   let data = json.data(using: .utf8),
                   let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    for item in items {
                        let t = item["type"] as? String
                        guard t == "image" || t == "generated_image" else { continue }
                        let normalized = (item["image_url"] as? String)
                            .map { url -> String in
                                var s = Substring(url)
                                while let f = s.first, f.unicodeScalars.allSatisfy({ $0.value <= 32 }) {
                                    s = s.dropFirst()
                                }
                                return s.lowercased()
                            }
                        if normalized == nil || !normalized!.hasPrefix("data:") {
                            cont.resume(returning: (
                                "Tool call failed: remote image URLs are not supported in tool outputs. "
                                + "Pass a base64 data URI instead", false))
                            return
                        }
                    }
                    if !items.isEmpty {
                        output += (output.isEmpty ? "" : "\n") + "[code-mode output]\n" + json
                    }
                }

                cont.resume(returning: (output, true))
            }
        }
    }
    #endif
}

/// Installer for the always-active code-mode tools — both `exec`
/// (`CodeModeTool`) and its `wait` companion (`WaitTool`), mirroring upstream
/// `codex-rs/core/src/tools/code_mode` which registers the pair together.
/// `DefaultTools.register` uses this with a nested router dispatch bridge so
/// JavaScript can call sibling tools without reacquiring the outer
/// code-tool gate.
public func installCodeMode(on router: ToolRouter,
                            toolNames: [String] = [],
                            dispatch: @escaping @Sendable (String, String, String, Int) async -> String) async {
    await router.register(CodeModeTool(toolNames: toolNames, dispatch: dispatch))
    await router.register(WaitTool())
}
