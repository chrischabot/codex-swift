export const meta = {
  name: 'audit-fidelity',
  description: 'Audit codex-rs harness+server fidelity against the codex-swift port; verify each finding adversarially',
  phases: [
    { title: 'Compare' },
    { title: 'Verify' },
  ],
}

// ---------------------------------------------------------------------------
// Roots
const RUST = '/Users/chabotc/Projects/codex/codex-rs'
const SWIFT = '/Users/chabotc/Projects/codex-swift'

// The "harness + codex server" surface, split into focused comparison units.
// Each unit names the upstream Rust source-of-truth and the Swift counterpart.
const UNITS = [
  {
    key: 'protocol-wire-types',
    title: 'Wire protocol types (requests/responses/notifications/items/events)',
    rust: `${RUST}/app-server-protocol/src/protocol/ (common.rs client_request_definitions!/server_request_definitions!/server_notification_definitions!/client_notification_definitions! macros, v2/*.rs payload structs incl. account.rs apps.rs config.rs environment.rs experimental_feature.rs feedback.rs fs.rs hook.rs item.rs mcp.rs model.rs notification.rs permissions.rs plugin.rs process.rs realtime.rs remote_control.rs review.rs thread.rs thread_data.rs turn.rs command_exec.rs), and core protocol types in ${RUST}/protocol/src/ (items.rs events? approvals.rs error.rs exec_output.rs config_types.rs)`,
    swift: `${SWIFT}/Sources/ProtocolModel/ and ${SWIFT}/Sources/WireProtocol/`,
    focus: 'Every JSON-RPC method name string, every request param field, every response field, every notification payload field — check exact serde rename/camelCase casing, optionality, enum variant rename strings, defaults, and tag/untagged representations. This is the single most important unit for protocol fidelity.',
  },
  {
    key: 'app-server-registry',
    title: 'App-server method registry & request processors (dispatch)',
    rust: `${RUST}/app-server/src/ (message_processor.rs, request_processors.rs, request_processors/*.rs, outgoing_message.rs, error_code.rs, server_request_error.rs, connection_rpc_gate.rs, request_serialization.rs)`,
    swift: `${SWIFT}/Sources/Supervisor/RequestRouter.swift and the rest of ${SWIFT}/Sources/Supervisor/`,
    focus: 'Which methods are dispatched and handled. Confirm each upstream method has a handler. Check JSON-RPC error codes (-32xxx incl -32001 overload, -32601 method-not-found), per-connection gating, request vs notification handling, and the set of server->client requests (serverRequest/resolved flow).',
  },
  {
    key: 'app-server-events',
    title: 'App-server event emission, thread state/status, streaming notifications',
    rust: `${RUST}/app-server/src/ (bespoke_event_handling.rs, thread_state.rs, thread_status.rs, event mapping; ${RUST}/app-server-protocol/src/protocol/event_mapping.rs and protocol/v2 item.rs/turn.rs notification payloads)`,
    swift: `${SWIFT}/Sources/Supervisor/ and ${SWIFT}/Sources/HarnessCore/ event emission paths, ${SWIFT}/Sources/ProtocolModel/Events.swift`,
    focus: 'Streaming notification fidelity: item/started, item/completed, item/agentMessage/delta, item/reasoning/textDelta + summaryTextDelta + summaryPartAdded, item/plan/delta, item/commandExecution/outputDelta + terminalInteraction, item/fileChange/outputDelta + patchUpdated, turn/diff/updated, turn/plan/updated, turn/started/completed, thread/compacted, thread/tokenUsage/updated, rawResponseItem/completed, item/autoApprovalReview/*. Check each notification is actually emitted with correct payload and ordering.',
  },
  {
    key: 'session-turn-loop',
    title: 'Core session / turn loop / thread manager',
    rust: `${RUST}/core/src/ (session/, codex_thread.rs, thread_manager.rs, tasks/, spawn.rs, turn_metadata.rs, turn_timing.rs, turn_diff_tracker.rs, stream_events_utils.rs, event_mapping.rs, goals.rs)`,
    swift: `${SWIFT}/Sources/HarnessCore/SessionEngine.swift, MultiAgent.swift, and ${SWIFT}/Sources/SessionWorkerCore/`,
    focus: 'Turn lifecycle: submit -> model stream -> tool calls -> tool results -> loop -> completion. Interrupt/steer handling, turn diff tracking, goals accounting, token usage, multi-agent spawn. Check ordering, abort semantics, and that every turn-affecting event is produced.',
  },
  {
    key: 'context-compaction',
    title: 'Context manager & compaction',
    rust: `${RUST}/core/src/ (context/, context_manager/, compact.rs, compact_remote.rs, compact_remote_v2.rs)`,
    swift: `${SWIFT}/Sources/HarnessCore/ContextManager.swift, Compaction.swift`,
    focus: 'Token budgeting, auto-compact threshold, buildCompactedHistory + initial-context insertion, SUMMARY_PREFIX, trim-and-retry semantics, remote compaction variants. Check thresholds, prefixes, and retry/reset semantics match exactly.',
  },
  {
    key: 'model-client',
    title: 'Model client / Responses API / streaming',
    rust: `${RUST}/core/src/ (client.rs, client_common.rs) and ${RUST}/codex-api/src/, ${RUST}/core/src/client_common_tests.rs for contract`,
    swift: `${SWIFT}/Sources/ModelClient/`,
    focus: 'Responses API request shape (model, input items, tools, store/previous_response_id coupling, reasoning, include fields), SSE event parsing (response.output_item.*, response.reasoning*, response.completed/incomplete/failed), error classification, retry/backoff, rate-limit header parsing. Check request and event field fidelity.',
  },
  {
    key: 'tools-router',
    title: 'Tool router & tool definitions',
    rust: `${RUST}/core/src/tools/ and ${RUST}/tools/src/, ${RUST}/core/src/function_tool.rs, ${RUST}/core/src/mcp_tool_exposure.rs`,
    swift: `${SWIFT}/Sources/Tools/ToolRouter.swift and tool files in ${SWIFT}/Sources/Tools/`,
    focus: 'The set of built-in tools and their JSON schemas (names, parameter names/types/required, descriptions where load-bearing), parallel vs serial gating, tool exposure/filtering, function-call dispatch, and result formatting. Check each tool definition field-for-field.',
  },
  {
    key: 'exec-unified-shell',
    title: 'Exec / unified-exec / exec-server / shell',
    rust: `${RUST}/core/src/ (exec.rs, exec_env.rs, unified_exec/, user_shell_command.rs, shell.rs, shell_detect.rs, shell_snapshot.rs, command_canonicalization.rs) and ${RUST}/exec-server/src/, ${RUST}/unified-exec/`,
    swift: `${SWIFT}/Sources/Tools/ShellTool.swift, UnifiedExec.swift, RemoteExecServerTools.swift`,
    focus: 'exec_command/wait/write_stdin persistent-session semantics, environment scrubbing/policy, command canonicalization, shell detection/snapshot, output truncation (head/tail), exit-code and timeout handling, PTY/resize. Check the exec-server websocket data path methods.',
  },
  {
    key: 'sandbox-safety-policy',
    title: 'Sandbox / safety / exec policy',
    rust: `${RUST}/core/src/ (sandboxing/, safety.rs, safety_tests.rs, exec_policy.rs, sandbox_tags.rs, network_policy_decision.rs, network_proxy_loader.rs) and ${RUST}/execpolicy/, ${RUST}/sandboxing? (seatbelt)`,
    swift: `${SWIFT}/Sources/Sandbox/ and ${SWIFT}/Sources/Tools/ExecPolicy.swift, CommandSafety.swift, RulesStore.swift`,
    focus: 'Approval/safety decision matrix (sandbox vs approval vs auto), writable-root computation, Seatbelt/SBPL profile correctness, network denial, execpolicy .rules prefix-rule matching + strictest-decision, network_rule domains. Check the decision logic matches upstream truth tables.',
  },
  {
    key: 'apply-patch',
    title: 'Apply-patch',
    rust: `${RUST}/apply-patch/src/ and ${RUST}/core/src/apply_patch.rs`,
    swift: `${SWIFT}/Sources/Tools/ApplyPatch.swift`,
    focus: 'Patch grammar (Begin/End Patch, Add/Update/Delete/Move File, @@ context hunks), fuzzy context matching, error messages, multi-file patches. Check parser + applier fidelity including error text.',
  },
  {
    key: 'persistence-rollout',
    title: 'Persistence: rollout / state / thread store',
    rust: `${RUST}/core/src/ (rollout.rs, state/, state_db_bridge.rs, thread_rollout_truncation.rs, session/) `,
    swift: `${SWIFT}/Sources/Persistence/`,
    focus: 'Rollout JSONL record shape and ordering, SessionMeta, ResponseItem serialization (incl context messages), thread store schema, resume/replay semantics, truncation. Check on-disk byte shape and replay fidelity.',
  },
  {
    key: 'config',
    title: 'Config loading & schema',
    rust: `${RUST}/config/src/`,
    swift: `${SWIFT}/Sources/Config/`,
    focus: 'config.toml schema (all keys + types + defaults), layering order (defaults/system/user/profile/env/overrides), profile-v2, camelCase aliases, wire_api enforcement, project-local denylist, config read/write/batchWrite RPC shapes.',
  },
  {
    key: 'prompts',
    title: 'Prompts / AGENTS.md / skills / personality',
    rust: `${RUST}/core/src/ (prompts/, review_prompts.rs, review_format.rs, realtime_prompt.rs, agents_md.rs, skills.rs, personality_migration.rs, prompt_debug.rs) and the verbatim prompt corpus at /Users/chabotc/Projects/codex/codex_prompts_verbatim.md /Users/chabotc/Projects/codex/prompts.md`,
    swift: `${SWIFT}/Sources/Prompts/`,
    focus: 'Base instruction prompt text byte-fidelity, approval/sandbox preambles, AGENTS.md discovery (ancestor walk, markers, max bytes, fallback names), skills body assembly, personality, review prompts. Check prompt STRINGS match upstream verbatim where they should.',
  },
  {
    key: 'mcp',
    title: 'MCP client/runtime',
    rust: `${RUST}/core/src/ (mcp.rs, mcp_tool_call.rs, mcp_tool_exposure.rs, mcp_openai_file.rs, mcp_skill_dependencies.rs) and ${RUST}/codex-mcp/`,
    swift: `${SWIFT}/Sources/MCP/`,
    focus: 'stdio + streaming-HTTP MCP transports, tools/list + tools/call + resources/read, elicitation/create routing, OAuth login, notification dispatch, env_clear + process containment, tool name namespacing/exposure. Check JSON-RPC shapes against MCP spec usage in upstream.',
  },
  {
    key: 'hooks',
    title: 'Hooks engine',
    rust: `${RUST}/core/src/ (hook_runtime.rs) and hook protocol in app-server-protocol/src/protocol/v2/hook.rs`,
    swift: `${SWIFT}/Sources/HarnessCore/Hooks.swift`,
    focus: 'Hook events (SessionStart/PreToolUse/PostToolUse/Stop/PreCompact/PostCompact/PermissionRequest/UserPromptSubmit/Notification), trust hashing, hook input/output JSON shapes, exit-code semantics, {"continue":false} blocking, hook/started + hook/completed notifications.',
  },
  {
    key: 'auth',
    title: 'Auth / login / token store',
    rust: `${RUST}/login/src/, ${RUST}/keyring-store?, ${RUST}/core/src/ (account auth paths), app-server account/* handlers`,
    swift: `${SWIFT}/Sources/Auth/ and auth paths in ${SWIFT}/Sources/Supervisor/`,
    focus: 'ChatGPT OAuth (browser callback + device code), token refresh + coalescing, API key auth, account/read union shape, rateLimits read/updated, logout, Keychain store + auth.json migration. Check the account/* and auth state machine fidelity.',
  },
]

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    unit: { type: 'string' },
    summary: { type: 'string', description: 'One-paragraph overall fidelity assessment of this unit' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
          category: {
            type: 'string',
            enum: ['missing-method', 'missing-notification', 'wrong-field', 'wrong-casing', 'wrong-semantics', 'missing-error-code', 'missing-type', 'wrong-default', 'ordering', 'missing-tool', 'prompt-text', 'other'],
          },
          rustEvidence: { type: 'string', description: 'Upstream file:line(s) + short snippet proving the contract' },
          swiftStatus: { type: 'string', description: 'ABSENT, or Swift file:line + what is actually there' },
          description: { type: 'string', description: 'Precise divergence: what upstream does vs what Swift does' },
          fixRecommendation: { type: 'string', description: 'Concrete fix: file to edit + what to add/change' },
        },
        required: ['title', 'severity', 'category', 'rustEvidence', 'swiftStatus', 'description', 'fixRecommendation'],
      },
    },
  },
  required: ['unit', 'summary', 'findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    isReal: { type: 'boolean', description: 'true only if this is a genuine divergence not handled anywhere in the Swift port' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    reasoning: { type: 'string' },
    correctedSwiftStatus: { type: 'string', description: 'What you actually found in the Swift port on independent inspection' },
    refinedFix: { type: 'string', description: 'Refined concrete fix if real; empty if not real' },
  },
  required: ['isReal', 'confidence', 'reasoning', 'correctedSwiftStatus'],
}

function comparePrompt(u) {
  return `You are auditing whether the OpenAI codex (Rust, "codex-rs") harness + app-server has been FAITHFULLY, ACCURATELY, and COMPLETELY reproduced in a Swift macOS port ("codex-swift"). The goal is a multi-process native macOS codex server with EXACT JSON-RPC protocol fidelity so a frontend (CodexApp) can talk to it.

AUDIT UNIT: ${u.title}

UPSTREAM (source of truth), read thoroughly:
${u.rust}

SWIFT PORT (must faithfully reproduce the above):
${u.swift}

WHAT TO CHECK (focus): ${u.focus}

METHOD:
1. Read the upstream Rust source for this unit and build a precise inventory of its externally-observable contract: method-name strings, request/response/notification payload field names + casing (serde rename/rename_all), enum variant wire strings, error codes, defaults, ordering/streaming/state-transition semantics, and load-bearing string constants (prompts, error text).
2. Read the corresponding Swift source. For each upstream contract element, determine whether Swift reproduces it faithfully. Swift may implement it in a different file, via constructed strings, helpers, or different naming — search before concluding ABSENT (use grep/Explore across the whole Sources/ tree, not just the named dir).
3. Report ONLY genuine divergences that would break protocol fidelity or harness correctness: missing methods/notifications, wrong field names or casing, wrong enum strings, missing error codes, wrong defaults, wrong semantics/ordering, missing tools, or prompt text that should be verbatim but differs.

IGNORE: pure test/fixture-only names (e.g. mock/experimentalMethod, plugins/foo, plugins/example, owner/repo, relative/path, tmp/source, tmp/destination, tmp/example), Rust-internal implementation detail with no wire/behavioral effect, Windows/Linux-sandbox-only code (this is macOS), and stylistic differences. Items already correctly handled are NOT findings.

Severity: critical = breaks wire compatibility or correctness a frontend depends on; major = missing feature/method/notification a real client uses; minor = cosmetic / edge-case / low-traffic.

Provide exact file:line evidence on BOTH sides. Be precise and skeptical — every finding will be independently re-verified, so do not pad with speculative items. Return your structured findings.`
}

function verifyPrompt(u, f) {
  return `You are adversarially verifying a claimed fidelity divergence in the codex-swift port (Swift reproduction of OpenAI codex-rs). Your job is to REFUTE it unless it is clearly real. Default to isReal=false if you find the behavior is actually handled.

CLAIMED FINDING (unit: ${u.title})
Title: ${f.title}
Severity: ${f.severity} | Category: ${f.category}
Upstream evidence: ${f.rustEvidence}
Claimed Swift status: ${f.swiftStatus}
Description: ${f.description}

INDEPENDENTLY verify by reading the actual files:
- Upstream truth: under /Users/chabotc/Projects/codex/codex-rs
- Swift port: under /Users/chabotc/Projects/codex-swift/Sources (search the WHOLE tree — grep for the method name, field name, enum string, or constant; the behavior may live in a different file/target than claimed, or be produced by a constructed string, a shared helper, a Codable CodingKeys map, or a macro-like pattern).

Confirm: (a) the upstream contract is really as described, and (b) Swift really does NOT reproduce it anywhere. If Swift handles it (even differently-but-equivalently), isReal=false. If genuinely missing/wrong, isReal=true with a refined, concrete fix (exact Swift file + change). Report what you actually found in correctedSwiftStatus.`
}

// ---------------------------------------------------------------------------
phase('Compare')
log(`Auditing ${UNITS.length} harness+server units against upstream codex-rs`)

const results = await pipeline(
  UNITS,
  (u) => agent(comparePrompt(u), { label: `compare:${u.key}`, phase: 'Compare', schema: FINDINGS_SCHEMA }),
  async (report, u) => {
    if (!report || !report.findings) return { unit: u.key, title: u.title, summary: report?.summary || '', findings: [] }
    // Adversarially verify critical + major findings; pass minor through flagged.
    const toVerify = report.findings.filter((f) => f.severity === 'critical' || f.severity === 'major')
    const verified = await parallel(
      toVerify.map((f) => () =>
        agent(verifyPrompt(u, f), { label: `verify:${u.key}:${f.title.slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA })
          .then((v) => ({ ...f, verdict: v }))
          .catch(() => ({ ...f, verdict: null }))
      )
    )
    const minors = report.findings
      .filter((f) => f.severity === 'minor')
      .map((f) => ({ ...f, verdict: { isReal: true, confidence: 'low', reasoning: 'minor — not adversarially verified', correctedSwiftStatus: f.swiftStatus } }))
    return { unit: u.key, title: u.title, summary: report.summary, findings: [...verified.filter(Boolean), ...minors] }
  }
)

// ---------------------------------------------------------------------------
// Aggregate confirmed findings.
const units = results.filter(Boolean)
const confirmed = []
for (const r of units) {
  for (const f of r.findings) {
    if (f.verdict && f.verdict.isReal) confirmed.push({ unit: r.unit, ...f })
  }
}
const order = { critical: 0, major: 1, minor: 2 }
confirmed.sort((a, b) => (order[a.severity] - order[b.severity]))

const bySeverity = { critical: 0, major: 0, minor: 0 }
confirmed.forEach((f) => { bySeverity[f.severity] = (bySeverity[f.severity] || 0) + 1 })

log(`Confirmed ${confirmed.length} real divergences (critical=${bySeverity.critical}, major=${bySeverity.major}, minor=${bySeverity.minor})`)

return {
  totals: bySeverity,
  unitSummaries: units.map((u) => ({ unit: u.unit, title: u.title, summary: u.summary, confirmedCount: u.findings.filter((f) => f.verdict && f.verdict.isReal).length })),
  confirmed,
}
