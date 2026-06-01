import Foundation
import InfraPrimitives

/// Multi-agent tool surface (upstream parity H-19 / P3.5):
///
/// * `spawn_agent` — spawn a sub-agent thread for a scoped task.
/// * `wait_agent`  — wait for one or more sub-agents to reach a final status.
/// * `close_agent` — terminate a sub-agent (and its descendants).
/// * `send_input`  — queue a message into a sub-agent, optionally interrupting.
/// * `resume_agent`— reopen a closed sub-agent so it accepts new input.
///
/// All five tools are thin JSON shims around `MultiAgentBus.shared`, the
/// in-process bridge the host (HarnessCore.AgentOrchestrator) configures at
/// startup. The schemas match upstream `multi_agents_spec.rs` byte-for-byte
/// (verified in `MultiAgentToolsTests`); the result payloads match the
/// upstream output schemas (`spawn_agent_output_schema_v1`, etc.).
///
/// Source of truth (upstream):
///   * `codex-rs/core/src/tools/handlers/multi_agents_spec.rs`
///   * `codex-rs/core/src/tools/handlers/multi_agents/{spawn,wait,close_agent,send_input,resume_agent}.rs`
///   * `codex-rs/protocol/src/protocol.rs` (`AgentStatus`)

// MARK: - Shared helpers

private func multiAgentJSONObject(_ obj: [String: Any]) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
    return "{}"
}

private func multiAgentParse(_ json: String) -> [String: Any] {
    guard let d = json.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}

/// Minimal JSON string escape for embedding caller-supplied descriptions
/// into the static schema literal. Covers the characters JSON forbids in
/// a string literal; everything else is passed through unchanged.
private func escapeJSONString(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

private func multiAgentErrorResult(_ callId: String, _ message: String) -> ToolResult {
    ToolResult(callId: callId,
               output: multiAgentJSONObject(["error": message]),
               success: false, truncated: false)
}

// MARK: - spawn_agent

/// Per-session configuration for the `spawn_agent` tool. Mirrors the upstream
/// `SpawnAgentToolOptions` struct (`core/src/tools/handlers/multi_agents_spec.rs`):
///   * `agentTypeDescription` — runtime-supplied description for the
///     `agent_type` JSON-schema property. Upstream pulls this from
///     `ToolsConfig::agent_type_description` (default: empty → fallback string).
///   * `availableModelsDescription` — pre-rendered "Available model overrides"
///     block that upstream builds from `ModelPreset` lists. We accept it
///     pre-rendered because the harness does not yet have a full
///     `ModelPreset` registry; downstream code that does can build the
///     string and pass it in verbatim.
///   * `includeUsageHint` / `usageHintText` — toggles the
///     `spawn_agent_tool_description` usage hint. When `includeUsageHint`
///     is true and `usageHintText` is nil, upstream emits the long
///     default delegation rubric. We replicate that rubric verbatim.
public struct SpawnAgentToolOptions: Sendable {
    public var agentTypeDescription: String
    public var availableModelsDescription: String?
    public var includeUsageHint: Bool
    public var usageHintText: String?

    public init(agentTypeDescription: String = DefaultSpawnAgentAgentTypeDescription,
                availableModelsDescription: String? = nil,
                includeUsageHint: Bool = true,
                usageHintText: String? = nil) {
        self.agentTypeDescription = agentTypeDescription
        self.availableModelsDescription = availableModelsDescription
        self.includeUsageHint = includeUsageHint
        self.usageHintText = usageHintText
    }
}

/// Built-in `default` agent role description (`role.rs` built_in::configs()).
private let SPAWN_AGENT_BUILTIN_DEFAULT_ROLE_DESC = "Default agent."

/// Built-in `explorer` agent role description (`role.rs` built_in::configs()).
/// Its `config_file` (explorer.toml) is empty, so it carries no
/// locked-settings note.
private let SPAWN_AGENT_BUILTIN_EXPLORER_ROLE_DESC = """
Use `explorer` for specific codebase questions.
Explorers are fast and authoritative.
They must be used to ask specific, well-scoped questions on the codebase.
Rules:
- In order to avoid redundant work, you should avoid exploring the same problem that explorers have already covered. Typically, you should trust the explorer results without additional verification. You are still allowed to inspect the code yourself to gain the needed context!
- You are encouraged to spawn up multiple explorers in parallel when you have multiple distinct questions to ask about the codebase that can be answered independently. This allows you to get more information faster without waiting for one question to finish before asking the next. While waiting for the explorer results, you can continue working on other local tasks that do not depend on those results. This parallelism is a key advantage of delegation, so use it whenever you have multiple questions to ask.
- Reuse existing explorers for related questions.
"""

/// Built-in `worker` agent role description (`role.rs` built_in::configs()).
private let SPAWN_AGENT_BUILTIN_WORKER_ROLE_DESC = """
Use for execution and production work.
Typical tasks:
- Implement part of a feature
- Fix tests or bugs
- Split large refactors into independent chunks
Rules:
- Explicitly assign **ownership** of the task (files / responsibility). When the subtask involves code changes, you should clearly specify which files or modules the worker is responsible for. This helps avoid merge conflicts and ensures accountability. For example, you can say "Worker 1 is responsible for updating the authentication module, while Worker 2 will handle the database layer." By defining clear ownership, you can delegate more effectively and reduce coordination overhead.
- Always tell workers they are **not alone in the codebase**, and they should not revert the edits made by others, and they should adjust their implementation to accommodate the changes made by others. This is important because there may be multiple workers making changes in parallel, and they need to be aware of each other's work to avoid conflicts and ensure a cohesive final product.
"""

/// Default `agent_type` description used when no session config supplies one.
///
/// Faithful port of upstream `spawn_tool_spec::build(&BTreeMap::new())`
/// (`core/src/agent/role.rs:279-305`), which for a default session (no
/// user-defined roles) emits the omit-default guidance plus the built-in role
/// catalog. Built-in roles iterate in BTreeMap (sorted) order — default,
/// explorer, worker — each formatted as `"{name}: {\n{description}\n}"`
/// (no locked-settings note: none of the built-ins pin a model/effort) and
/// joined with `"\n"`. This is the string injected as the `agent_type`
/// property description (`multi_agents_spec.rs:526-528`).
public let DefaultSpawnAgentAgentTypeDescription: String = {
    let roleNames = ["default", "explorer", "worker"]
    let descs = [
        SPAWN_AGENT_BUILTIN_DEFAULT_ROLE_DESC,
        SPAWN_AGENT_BUILTIN_EXPLORER_ROLE_DESC,
        SPAWN_AGENT_BUILTIN_WORKER_ROLE_DESC,
    ]
    let formatted = zip(roleNames, descs)
        .map { "\($0): {\n\($1)\n}" }
        .joined(separator: "\n")
    return "Optional type name for the new agent. If omitted, `default` is used.\n"
        + "Available roles:\n" + formatted
}()

/// Upstream `SPAWN_AGENT_INHERITED_MODEL_GUIDANCE` (multi_agents_spec.rs:9).
private let SPAWN_AGENT_INHERITED_MODEL_GUIDANCE =
    "Spawned agents inherit your current model by default. Omit `model` to "
    + "use that preferred default; set `model` only when an explicit override "
    + "is needed."

/// Render the full upstream `spawn_agent_tool_description` (v1) for the
/// given options. Byte-for-byte parity with `multi_agents_spec.rs`'s
/// `spawn_agent_tool_description` so the model sees identical guidance.
public func renderSpawnAgentToolDescriptionV1(_ options: SpawnAgentToolOptions)
    -> String
{
    let agentRoleGuidance = options.availableModelsDescription ?? ""
    let returnValueDescription =
        "Returns the spawned agent id plus the user-facing nickname when "
        + "available."
    let toolDescription = """

            \(agentRoleGuidance)
            Spawn a sub-agent for a well-scoped task. \(returnValueDescription) \(SPAWN_AGENT_INHERITED_MODEL_GUIDANCE)
    """

    if !options.includeUsageHint {
        return toolDescription
    }
    if let usageHintText = options.usageHintText {
        return """

                \(toolDescription)
        \(usageHintText)
        """
    }
    let agentRoleUsageHint = options.availableModelsDescription
        .map { _ in
            "Agent-role guidance below only helps choose which agent to use after spawning is already authorized; it never authorizes spawning by itself."
        }
        ?? ""
    return """

            \(toolDescription)
        This spawn_agent tool provides you access to sub-agents that inherit your current model by default. Do not set the `model` field unless the user explicitly asks for a different model or there is a clear task-specific reason. You should follow the rules and guidelines below to use this tool.

        Only use `spawn_agent` if and only if the user explicitly asks for sub-agents, delegation, or parallel agent work.
        Requests for depth, thoroughness, research, investigation, or detailed codebase analysis do not count as permission to spawn.
        \(agentRoleUsageHint)

        ### When to delegate vs. do the subtask yourself
        - First, quickly analyze the overall user task and form a succinct high-level plan. Identify which tasks are immediate blockers on the critical path, and which tasks are sidecar tasks that are needed but can run in parallel without blocking the next local step. As part of that plan, explicitly decide what immediate task you should do locally right now. Do this planning step before delegating to agents so you do not hand off the immediate blocking task to a submodel and then waste time waiting on it.
        - Use a subagent when a subtask is easy enough for it to handle and can run in parallel with your local work. Prefer delegating concrete, bounded sidecar tasks that materially advance the main task without blocking your immediate next local step.
        - Do not delegate urgent blocking work when your immediate next step depends on that result. If the very next action is blocked on that task, the main rollout should usually do it locally to keep the critical path moving.
        - Keep work local when the subtask is too difficult to delegate well and when it is tightly coupled, urgent, or likely to block your immediate next step.

        ### Designing delegated subtasks
        - Subtasks must be concrete, well-defined, and self-contained.
        - Delegated subtasks must materially advance the main task.
        - Do not duplicate work between the main rollout and delegated subtasks.
        - Avoid issuing multiple delegate calls on the same unresolved thread unless the new delegated task is genuinely different and necessary.
        - Narrow the delegated ask to the concrete output you need next.
        - For coding tasks, prefer delegating concrete code-change worker subtasks over read-only explorer analysis when the subagent can make a bounded patch in a clear write scope.
        - When delegating coding work, instruct the submodel to edit files directly in its forked workspace and list the file paths it changed in the final answer.
        - For code-edit subtasks, decompose work so each delegated task has a disjoint write set.

        ### After you delegate
        - Call wait_agent very sparingly. Only call wait_agent when you need the result immediately for the next critical-path step and you are blocked until it returns.
        - Do not redo delegated subagent tasks yourself; focus on integrating results or tackling non-overlapping work.
        - While the subagent is running in the background, do meaningful non-overlapping work immediately.
        - Do not repeatedly wait by reflex.
        - When a delegated coding task returns, quickly review the uploaded changes, then integrate or refine them.

        ### Parallel delegation patterns
        - Run multiple independent information-seeking subtasks in parallel when you have distinct questions that can be answered independently.
        - Split implementation into disjoint codebase slices and spawn multiple agents for them in parallel when the write scopes do not overlap.
        - Delegate verification only when it can run in parallel with ongoing implementation and is likely to catch a concrete risk before final integration.
        - The key is to find opportunities to spawn multiple independent subtasks in parallel within the same round, while ensuring each subtask is well-defined, self-contained, and materially advances the main task.
        """
}

public struct SpawnAgentTool: Tool {
    public let name = "spawn_agent"
    /// Not parallel-safe upstream: spawning mutates the agent registry.
    public let parallelSafe = false

    /// Per-session options (upstream parity `SpawnAgentToolOptions`).
    /// `agent_type` description and the rendered tool description both
    /// derive from these — i.e. they are runtime-configurable, not a
    /// hardcoded string baked into the tool.
    public let options: SpawnAgentToolOptions

    public var toolDescription: String {
        // Full upstream `spawn_agent_tool_description` (v1). When no
        // session config supplies overrides this still emits the long
        // delegation rubric the model needs, matching the upstream default
        // (`include_usage_hint = true`, no caller-supplied hint).
        renderSpawnAgentToolDescriptionV1(options)
    }

    /// Upstream parity (`create_spawn_agent_tool_v1`,
    /// `spawn_agent_common_properties_v1`): all fields optional, strict
    /// `additionalProperties=false`, no `required` array. The `agent_type`
    /// description is now drawn from `options.agentTypeDescription` so the
    /// host can override it per session (mirrors upstream
    /// `ToolsConfig::agent_type_description` flow).
    public var jsonSchema: String {
        let agentTypeDesc = escapeJSONString(options.agentTypeDescription)
        // Upstream `spawn_agent_common_properties_v1` builds a BTreeMap, so
        // serde serializes the property keys in sorted (alphabetical) order:
        //   agent_type, fork_context, items, message, model, reasoning_effort,
        //   service_tier. The nested collab input-items object likewise sorts to
        //   image_url, name, path, text, type (multi_agents_spec.rs:480-507).
        return #"{"type":"object","properties":{"agent_type":{"type":"string","description":""# + agentTypeDesc + #""},"fork_context":{"type":"boolean","description":"When true, fork the current thread history into the new agent before sending the initial prompt. This must be used when you want the new agent to have exactly the same context as you."},"items":{"type":"array","description":"Structured input items. Use this to pass explicit mentions (for example app:// connector paths).","items":{"type":"object","properties":{"image_url":{"type":"string","description":"Image URL when type is image."},"name":{"type":"string","description":"Display name when type is skill or mention."},"path":{"type":"string","description":"Path when type is local_image/skill, or structured mention target such as app://<connector-id> or plugin://<plugin-name>@<marketplace-name> when type is mention."},"text":{"type":"string","description":"Text content when type is text."},"type":{"type":"string","description":"Input item type: text, image, local_image, skill, or mention."}},"additionalProperties":false}},"message":{"type":"string","description":"Initial plain-text task for the new agent. Use either message or items."},"model":{"type":"string","description":"Optional model override for the new agent. Leave unset to inherit the same model as the parent, which is the preferred default. Only set this when the user explicitly asks for a different model or the task clearly requires one."},"reasoning_effort":{"type":"string","description":"Optional reasoning effort override for the new agent. Replaces the inherited reasoning effort."},"service_tier":{"type":"string","description":"Optional service tier override for the new agent. Leave unset unless the user explicitly asks for one."}},"additionalProperties":false}"#
    }

    public init(options: SpawnAgentToolOptions = SpawnAgentToolOptions()) {
        self.options = options
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = multiAgentParse(call.argumentsJSON)
        let req = MultiAgentBus.SpawnRequest(
            message: a["message"] as? String,
            agentType: a["agent_type"] as? String,
            model: a["model"] as? String,
            reasoningEffort: a["reasoning_effort"] as? String,
            serviceTier: a["service_tier"] as? String,
            forkContext: (a["fork_context"] as? Bool) ?? false,
            rawArgsJSON: call.argumentsJSON)
        do {
            let resp = try await MultiAgentBus.shared.spawn(req)
            // Upstream `spawn_agent_output_schema_v1`:
            // {agent_id: string, nickname: string|null}
            return ToolResult(callId: call.callId,
                              output: multiAgentJSONObject([
                                "agent_id": resp.agentId,
                                "nickname": resp.nickname as Any? ?? NSNull(),
                              ]),
                              success: true, truncated: false)
        } catch let MultiAgentBus.MultiAgentError.unconfigured {
            return multiAgentErrorResult(call.callId,
                "spawn_agent: multi-agent orchestrator is not configured for this session")
        } catch {
            return multiAgentErrorResult(call.callId,
                "spawn_agent failed: \(error)")
        }
    }
}

// MARK: - wait_agent

public struct WaitAgentTool: Tool {
    public let name = "wait_agent"
    /// Upstream parity: the wait handler implements `ToolExecutor`/`CoreToolRuntime`
    /// with NO `supports_parallel_tool_calls` override (core/src/tools/handlers/
    /// multi_agents/wait.rs:31-205), so it falls back to the trait default
    /// (`tools/src/tool_executor.rs:50-52` => `false`). It therefore takes the
    /// exclusive (write) side of the per-turn parallel gate (`tools/parallel.rs`)
    /// and runs serially, not concurrently.
    public let parallelSafe = false

    public var toolDescription: String {
        "Wait for agents to reach a final status. Completed statuses may "
        + "include the agent's final message. Returns empty status when "
        + "timed out. Once the agent reaches a final status, a notification "
        + "message will be received containing the same completed status."
    }

    /// Upstream parity (`wait_agent_tool_parameters_v1`):
    ///   * `targets`: array of agent ids (required)
    ///   * `timeout_ms`: optional number (default 30000, min 10000, max 3_600_000)
    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"targets":{"type":"array","description":"Agent ids to wait on. Pass multiple ids to wait for whichever finishes first.","items":{"type":"string"}},"timeout_ms":{"type":"number","description":"Optional timeout in milliseconds. Defaults to 30000, min 10000, max 3600000. Prefer longer waits (minutes) to avoid busy polling."}},"required":["targets"],"additionalProperties":false}
        """#
    }

    public init() {}

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = multiAgentParse(call.argumentsJSON)
        guard let rawTargets = a["targets"] as? [Any] else {
            return multiAgentErrorResult(call.callId,
                "wait_agent: missing or invalid `targets` array")
        }
        let targets: [String] = rawTargets.compactMap { $0 as? String }
        if targets.isEmpty {
            return multiAgentErrorResult(call.callId,
                "wait_agent: `targets` must contain at least one agent id")
        }
        // Clamp the timeout the same way upstream does
        // (`multi_agents_common::DEFAULT_WAIT_TIMEOUT_MS` and friends).
        let requested: Int64
        if let v = a["timeout_ms"] as? Int64 {
            requested = v
        } else if let v = a["timeout_ms"] as? Int {
            requested = Int64(v)
        } else if let v = a["timeout_ms"] as? Double {
            requested = Int64(v)
        } else {
            requested = MultiAgentTimeouts.defaultMs
        }
        let clamped = max(MultiAgentTimeouts.minMs,
                          min(MultiAgentTimeouts.maxMs, requested))

        let req = MultiAgentBus.WaitRequest(targets: targets, timeoutMs: clamped)
        do {
            let resp = try await MultiAgentBus.shared.wait(req)
            var statusMap: [String: Any] = [:]
            for (id, status) in resp.statusByAgent {
                statusMap[id] = status.jsonValue()
            }
            return ToolResult(callId: call.callId,
                              output: multiAgentJSONObject([
                                "status": statusMap,
                                "timed_out": resp.timedOut,
                              ]),
                              success: true, truncated: false)
        } catch let MultiAgentBus.MultiAgentError.unconfigured {
            return multiAgentErrorResult(call.callId,
                "wait_agent: multi-agent orchestrator is not configured for this session")
        } catch {
            return multiAgentErrorResult(call.callId,
                "wait_agent failed: \(error)")
        }
    }
}

// MARK: - close_agent

public struct CloseAgentTool: Tool {
    public let name = "close_agent"
    public let parallelSafe = false

    public var toolDescription: String {
        "Close an agent and any open descendants when they are no longer "
        + "needed, and return the target agent's previous status before "
        + "shutdown was requested. Don't keep agents open for too long if "
        + "they are not needed anymore."
    }

    /// Upstream parity (`create_close_agent_tool_v1`).
    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"target":{"type":"string","description":"Agent id to close (from spawn_agent)."}},"required":["target"],"additionalProperties":false}
        """#
    }

    public init() {}

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = multiAgentParse(call.argumentsJSON)
        guard let target = a["target"] as? String, !target.isEmpty else {
            return multiAgentErrorResult(call.callId,
                "close_agent: missing `target`")
        }
        do {
            let previous = try await MultiAgentBus.shared.close(target: target)
            return ToolResult(callId: call.callId,
                              output: multiAgentJSONObject([
                                "previous_status": previous.jsonValue(),
                              ]),
                              success: true, truncated: false)
        } catch let MultiAgentBus.MultiAgentError.unconfigured {
            return multiAgentErrorResult(call.callId,
                "close_agent: multi-agent orchestrator is not configured for this session")
        } catch let MultiAgentBus.MultiAgentError.agentNotFound(id) {
            return multiAgentErrorResult(call.callId,
                "close_agent: agent not found: \(id)")
        } catch {
            return multiAgentErrorResult(call.callId,
                "close_agent failed: \(error)")
        }
    }
}

// MARK: - send_input

public struct SendInputTool: Tool {
    public let name = "send_input"
    public let parallelSafe = false

    public var toolDescription: String {
        "Send a message to an existing agent. Use interrupt=true to redirect "
        + "work immediately. You should reuse the agent by send_input if you "
        + "believe your assigned task is highly dependent on the context of "
        + "a previous task."
    }

    /// Upstream parity (`create_send_input_tool_v1`). Properties emitted in
    /// upstream BTreeMap (sorted) order: interrupt, items, message, target.
    /// The nested collab input-items object likewise sorts to image_url, name,
    /// path, text, type (multi_agents_spec.rs:480-507).
    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"interrupt":{"type":"boolean","description":"When true, stop the agent's current task and handle this immediately. When false (default), queue this message."},"items":{"type":"array","description":"Structured input items. Use this to pass explicit mentions (for example app:// connector paths).","items":{"type":"object","properties":{"image_url":{"type":"string","description":"Image URL when type is image."},"name":{"type":"string","description":"Display name when type is skill or mention."},"path":{"type":"string","description":"Path when type is local_image/skill, or structured mention target such as app://<connector-id> or plugin://<plugin-name>@<marketplace-name> when type is mention."},"text":{"type":"string","description":"Text content when type is text."},"type":{"type":"string","description":"Input item type: text, image, local_image, skill, or mention."}},"additionalProperties":false}},"message":{"type":"string","description":"Legacy plain-text message to send to the agent. Use either message or items."},"target":{"type":"string","description":"Agent id to message (from spawn_agent)."}},"required":["target"],"additionalProperties":false}
        """#
    }

    public init() {}

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = multiAgentParse(call.argumentsJSON)
        guard let target = a["target"] as? String, !target.isEmpty else {
            return multiAgentErrorResult(call.callId,
                "send_input: missing `target`")
        }
        let req = MultiAgentBus.SendInputRequest(
            target: target,
            message: a["message"] as? String,
            interrupt: (a["interrupt"] as? Bool) ?? false,
            rawArgsJSON: call.argumentsJSON)
        do {
            let submissionId = try await MultiAgentBus.shared.sendInput(req)
            // Upstream `send_input_output_schema`: {submission_id: string}
            return ToolResult(callId: call.callId,
                              output: multiAgentJSONObject([
                                "submission_id": submissionId,
                              ]),
                              success: true, truncated: false)
        } catch let MultiAgentBus.MultiAgentError.unconfigured {
            return multiAgentErrorResult(call.callId,
                "send_input: multi-agent orchestrator is not configured for this session")
        } catch let MultiAgentBus.MultiAgentError.agentNotFound(id) {
            return multiAgentErrorResult(call.callId,
                "send_input: agent not found: \(id)")
        } catch {
            return multiAgentErrorResult(call.callId,
                "send_input failed: \(error)")
        }
    }
}

// MARK: - resume_agent

public struct ResumeAgentTool: Tool {
    public let name = "resume_agent"
    public let parallelSafe = false

    public var toolDescription: String {
        "Resume a previously closed agent by id so it can receive send_input "
        + "and wait_agent calls."
    }

    /// Upstream parity (`create_resume_agent_tool`).
    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"id":{"type":"string","description":"Agent id to resume."}},"required":["id"],"additionalProperties":false}
        """#
    }

    public init() {}

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = multiAgentParse(call.argumentsJSON)
        guard let id = a["id"] as? String, !id.isEmpty else {
            return multiAgentErrorResult(call.callId,
                "resume_agent: missing `id`")
        }
        do {
            let status = try await MultiAgentBus.shared.resume(id: id)
            // Upstream `resume_agent_output_schema`: {status: <AgentStatus>}
            return ToolResult(callId: call.callId,
                              output: multiAgentJSONObject([
                                "status": status.jsonValue(),
                              ]),
                              success: true, truncated: false)
        } catch let MultiAgentBus.MultiAgentError.unconfigured {
            return multiAgentErrorResult(call.callId,
                "resume_agent: multi-agent orchestrator is not configured for this session")
        } catch let MultiAgentBus.MultiAgentError.agentNotFound(id) {
            return multiAgentErrorResult(call.callId,
                "resume_agent: agent not found: \(id)")
        } catch {
            return multiAgentErrorResult(call.callId,
                "resume_agent failed: \(error)")
        }
    }
}
