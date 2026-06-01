import Foundation
import InfraPrimitives

private func wfParseArgs(_ json: String) -> [String: Any] {
    guard let d = json.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any]
    else { return [:] }
    return o
}
private func wfJSON(_ o: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}
private func wfReserialize(_ v: Any?) -> String? {
    guard let v, !(v is NSNull) else { return nil }
    return (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
        .flatMap { String(data: $0, encoding: .utf8) }
}

/// The `workflow` tool (port of Claude's `WorkflowTool`/`KR3`). Authors or
/// invokes a JavaScript orchestration script that fans out GPT sub-agents
/// deterministically. Returns immediately (`async_launched`) and runs detached;
/// progress is observed via `workflow_status` / `workflow_list`.
///
/// Registered *deferred* (hidden until the `/workflow` command or the
/// "workflow" trigger word activates it), matching the explicit-opt-in model.
public struct WorkflowTool: Tool {
    public let name = "workflow"
    public let parallelSafe = false
    public init() {}

    public var toolDescription: String {
        """
        Execute a workflow script that orchestrates multiple sub-agents deterministically. \
        A workflow structures work across many agents — to be comprehensive (decompose and cover \
        in parallel), to be confident (independent perspectives and adversarial checks), or to take \
        on scale one context can't hold. Runs in the background and returns immediately with a runId; \
        observe progress via `workflow_status`/`workflow_list` and stop via `workflow_stop`.

        Pass the script inline via `script`, or run a predefined one via `name` (built-in or from \
        `.agents/workflows/`), or a file via `scriptPath`. Resume a prior run with `resumeFromRunId`.

        Every script must begin with `export const meta = { name, description, phases }` followed by \
        the body. Available primitives:
        - `agent(prompt, opts?)` — spawn a GPT sub-agent; returns its text, or a schema-validated \
          object when `opts.schema` is given; `null` if skipped. opts: {label, phase, schema, model}.
        - `parallel(thunks)` — run `() => agent(...)` thunks concurrently (barrier; failed → null).
        - `pipeline(items, ...stages)` — run each item through the stages independently (no barrier; \
          a stage that throws/returns null drops that item to null).
        - `phase(title)` / `log(msg)` / `budget` ({total, spent(), remaining()}) / `args` (the input) \
          / `workflow(name, args)` (one-level nested).

        Pass `budget` (an output-token ceiling) to bound the run: `budget.total`/`remaining()` then \
        reflect it and `agent()` throws once the ceiling is hit. The budget is shared across the run \
        and any nested `workflow()` children.

        Determinism: `Date.now()`, `Math.random()`, and argless `new Date()` are unavailable inside \
        scripts (they break resume).
        """
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{
          "script":{"type":"string","description":"Self-contained workflow script beginning with `export const meta = {...}`."},
          "name":{"type":"string","description":"Name of a predefined workflow (built-in or from .agents/workflows/)."},
          "args":{"description":"Value exposed to the script as the global `args`, verbatim. Pass arrays/objects as real JSON."},
          "scriptPath":{"type":"string","description":"Path to a workflow script file on disk. Takes precedence over script and name."},
          "resumeFromRunId":{"type":"string","pattern":"^wf_[a-z0-9-]{6,}$","description":"Run id of a prior invocation to resume. Stop the prior run first."},
          "budget":{"type":"integer","minimum":1,"description":"Output-token ceiling for the run, exposed to the script as `budget` and shared with nested workflows. Omit for no limit."}
        },"additionalProperties":false}
        """#
    }
    public var outputSchemaJSON: String? {
        #"{"type":"object","properties":{"status":{"type":"string"},"runId":{"type":"string"},"taskId":{"type":"string"},"summary":{"type":"string"},"transcriptDir":{"type":"string"},"scriptPath":{"type":"string"},"error":{"type":"string"}},"additionalProperties":true}"#
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = wfParseArgs(call.argumentsJSON)
        let budget = (a["budget"] as? Int) ?? (a["budget"] as? Double).map(Int.init)
        let req = WorkflowBus.LaunchRequest(
            script: a["script"] as? String,
            name: a["name"] as? String,
            scriptPath: a["scriptPath"] as? String,
            argsJSON: wfReserialize(a["args"]),
            resumeFromRunId: a["resumeFromRunId"] as? String,
            cwd: cwd,
            budget: budget.flatMap { $0 > 0 ? $0 : nil })

        let v = await WorkflowBus.shared.validate(req)
        if !v.ok {
            return ToolResult(callId: call.callId,
                              output: wfJSON(["error": v.message as Any? ?? "invalid workflow input",
                                              "errorCode": v.errorCode as Any? ?? NSNull()]),
                              success: false, truncated: false)
        }
        do {
            let resp = try await WorkflowBus.shared.launch(req)
            var out: [String: Any] = ["status": resp.status, "runId": resp.runId, "taskId": resp.taskId]
            if let s = resp.summary { out["summary"] = s }
            if let t = resp.transcriptDir { out["transcriptDir"] = t }
            if let p = resp.scriptPath { out["scriptPath"] = p }
            return ToolResult(callId: call.callId, output: wfJSON(out), success: true, truncated: false)
        } catch WorkflowBus.WorkflowError.unconfigured {
            return ToolResult(callId: call.callId,
                              output: wfJSON(["error": "workflow: orchestrator not configured"]),
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId,
                              output: wfJSON(["error": "workflow launch failed: \(error)"]),
                              success: false, truncated: false)
        }
    }
}

/// `workflow_stop` — abort a running workflow by runId or taskId.
public struct WorkflowStopTool: Tool {
    public let name = "workflow_stop"
    public let parallelSafe = false
    public init() {}
    public var toolDescription: String { "Stop a running workflow by its runId or taskId." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"runId":{"type":"string"},"taskId":{"type":"string"}},"additionalProperties":false}"#
    }
    public func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        let a = wfParseArgs(call.argumentsJSON)
        let id = (a["runId"] as? String) ?? (a["taskId"] as? String) ?? ""
        let out = await WorkflowBus.shared.stop(id)
        return ToolResult(callId: call.callId, output: out, success: !out.contains("\"error\""), truncated: false)
    }
}

/// `workflow_list` — list live + recent workflow runs.
public struct WorkflowListTool: Tool {
    public let name = "workflow_list"
    public let parallelSafe = true
    public init() {}
    public var toolDescription: String { "List live and recently-completed workflow runs and their statuses." }
    public var jsonSchema: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        let out = await WorkflowBus.shared.list()
        return ToolResult(callId: call.callId, output: out, success: true, truncated: false)
    }
}

/// `workflow_status` — fetch one run's status + result.
public struct WorkflowStatusTool: Tool {
    public let name = "workflow_status"
    public let parallelSafe = true
    public init() {}
    public var toolDescription: String { "Get the status (and result, when finished) of a workflow run by runId." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"runId":{"type":"string"}},"required":["runId"],"additionalProperties":false}"#
    }
    public func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        let a = wfParseArgs(call.argumentsJSON)
        let out = await WorkflowBus.shared.status((a["runId"] as? String) ?? "")
        return ToolResult(callId: call.callId, output: out, success: true, truncated: false)
    }
}
