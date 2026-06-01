export const meta = {
  name: 'fix-criticals-v6',
  description: 'Fix the 3 re-ranked criticals from the validation-6 audit (apply_patch freeform tool, dangerous-command heuristic [safety], apply-patch chunk-ordering correctness) with Opus reviewers',
  phases: [
    { title: 'Spec', detail: 'parallel read-only research per critical' },
    { title: 'Implement', detail: 'sequential, tree-green-gated implementation' },
    { title: 'Review', detail: 'Opus 4.8 high-effort fidelity reviewer per critical', model: 'opus' },
    { title: 'Gate', detail: 'full build + test suite' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'

const SPEC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'upstreamRefs', 'portFiles', 'plan', 'risks'],
  properties: {
    feature: { type: 'string' },
    upstreamRefs: { type: 'array', items: { type: 'string' } },
    portFiles: { type: 'array', items: { type: 'string' } },
    plan: { type: 'array', items: { type: 'string' } },
    risks: { type: 'string' },
  },
}
const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'filesChanged', 'buildGreen', 'testsAdded', 'summary', 'incomplete'],
  properties: {
    feature: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean' },
    testsAdded: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    incomplete: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'faithful', 'verdict', 'issues'],
  properties: {
    feature: { type: 'string' },
    faithful: { type: 'boolean' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd is the port root).
JSON-RPC app-server-v2 fidelity port. Wire fidelity is paramount (serde camelCase,
internally-tagged enums, skip_serializing_if). Match existing port idioms. The build
MUST stay green: run \`swift build\` and confirm "Build complete!". If a piece can't be
made to compile/work, revert it and report under "incomplete" — never leave the tree broken.
Cross-reference tools/audit-findings.txt and tools/FIDELITY_REMEDIATION.md.`

const FEATURES = [
  {
    key: 'apply-patch-ordering',
    title: 'apply-patch chunk-ordering correctness (compute-all → sort → apply descending)',
    detail: `BUG (correctness): the port applies Update chunks SEQUENTIALLY against a mutating array, so a
pure-addition chunk followed by an edit chunk produces the wrong result.
UPSTREAM CONTRACT: ${UP}/apply-patch/src/lib.rs:694-810. compute_replacements records
(start_idx,len,new) tuples against the IMMUTABLE original_lines while advancing line_index; a
pure-addition chunk uses insertion_idx = original_lines.len() (or len-1 if trailing empty)
(lib.rs:722-731). Replacements are sorted by index (lib.rs:779) and apply_replacements applies them
in DESCENDING order (lib.rs:792 .iter().rev()). See the explicit test
test_pure_addition_chunk_followed_by_removal (lib.rs:1261-1295): input "line1\\nline2\\nline3\\n",
a pure-addition chunk (+after-context/+second-line) then an edit chunk
(-line2/-line3/+line2-replacement) must yield "line1\\nline2-replacement\\nafter-context\\nsecond-line\\n".
PORT BUG: ${SW}/Sources/Tools/ApplyPatch.swift:558-612 deriveNewContents mutates \`lines\` in place per
chunk (pure-addition inserts at current end, advances lineIndex past it). There is NO
compute-all/sort/apply-descending phase.
FIX: rewrite deriveNewContents to (1) compute all replacements against the immutable original lines
advancing a read cursor, with pure additions anchored to original EOF exactly per upstream; (2) sort
by index; (3) apply in descending order. Port the upstream test as a Swift test and confirm it passes.`,
  },
  {
    key: 'dangerous-command-heuristic',
    title: 'dangerous-command heuristic (command_might_be_dangerous) — SAFETY',
    detail: `BUG (SAFETY): under approval policy .never the port runs dangerous unmatched commands
(rm -rf /, sudo ...) in the sandbox instead of forbidding them, and other policies don't escalate
dangerous unmatched commands to a prompt.
UPSTREAM CONTRACT: ${UP}/core/src/.../is_dangerous_command.rs:7-28,145-157 (command_might_be_dangerous:
flags rm -f/-rf, sudo <dangerous> recursively, and bash -lc scripts) and exec_policy.rs:296,676-702
(render_decision_for_unmatched_command: for a dangerous unmatched command returns Forbidden under
Never when sandbox is not explicitly disabled, and Prompt under the other policies).
PORT BUG: no dangerous classifier exists. ${SW}/Sources/Tools/CommandSafety.swift has only
safe/needsApproval; ExecPolicy.forbidden derives only from explicit forbidden-rule prefixes;
decideCommand(.never) always returns proceedSandboxed.
FIX: port command_might_be_dangerous into CommandSafety/ExecPolicy (recurse through sudo and the
bash -lc decomposition already present from the validation-5 work), and wire the unmatched-command
decision so .never forbids dangerous commands and the other policies prompt — faithfully matching
render_decision_for_unmatched_command. Add tests for rm -rf /, sudo rm -rf, bash -lc "rm -rf /",
and a benign command (must still proceed). Do NOT regress existing ExecPolicy/CommandSafety tests.`,
  },
  {
    key: 'apply-patch-freeform-tool',
    title: 'apply_patch as Freeform/custom-grammar (lark) tool',
    detail: `DIVERGENCE: upstream advertises apply_patch as a Freeform custom-grammar tool; the port sends it
as a JSON function tool with a "patch" string property.
UPSTREAM CONTRACT: ${UP}/core/src/tools/handlers/apply_patch_spec.rs:9-28 +
apply_patch.rs:307 (spec() ALWAYS returns create_apply_patch_freeform_tool, no gating). The wire shape
is {"type":"custom","name":"apply_patch","description":"Use the \\\`apply_patch\\\` tool to edit files.
This is a FREEFORM tool, so do not wrap the patch in JSON.","format":{"type":"grammar","syntax":"lark",
"definition":"<APPLY_PATCH_LARK_GRAMMAR>"}}. See tools/src/tool_spec.rs:16-50 (#[serde(tag="type")],
Freeform→"custom") and responses_api.rs:12-22 (FreeformTool/FreeformToolFormat layout). The lark
grammar definition is APPLY_PATCH_LARK_GRAMMAR (find it in upstream and reproduce byte-faithfully).
PORT STATE: ${SW}/Sources/ModelClient/ModelClient.swift:26-39 ToolSpec is a struct with only
name/description/parametersJSON/outputSchemaJSON — no freeform/grammar variant. ApplyPatchTool
(Sources/Tools/ToolRouter.swift:392-400) advertises a JSON function schema with a "patch" property.
On the response side, the SSE parsers currently decode message + function_call from
response.output_item.done but DROP custom_tool_call items.
FIX (end-to-end, faithfully):
1. Extend the model-facing tool-spec serialization so apply_patch emits the Freeform custom-grammar
   wire shape (type:"custom", format:{type:"grammar",syntax:"lark",definition:...}) with the verbatim
   description + lark grammar. This likely means making the tool able to declare a freeform/custom
   spec rather than a JSON function spec; keep all OTHER tools as JSON function tools unchanged.
2. Handle the custom_tool_call response item end-to-end: parse custom_tool_call (and its input) from
   the Responses SSE in all 3 transports (OpenAI/URLSession/WebSocket), and route a custom apply_patch
   call's raw patch text into ApplyPatchTool (the input is the raw patch envelope, NOT JSON).
3. Keep back-compat: the legacy JSON {"patch":"..."} call path must still work so existing tests and
   older clients don't regress. Update/extend tests that assert the apply_patch tool schema.
This is the largest of the three — if any sub-part can't be made faithful + green, implement what you
can faithfully, keep the tree green, and report the remainder precisely under "incomplete".`,
  },
]

phase('Spec')
const specs = await parallel(FEATURES.map(f => () =>
  agent(`Read-only research to produce a precise implementation spec.
Feature: ${f.title}
${f.detail}
${COMMON}
Do NOT edit files. Return the spec.`,
    { label: `spec:${f.key}`, phase: 'Spec', schema: SPEC_SCHEMA, agentType: 'Explore' }
  ).then(s => ({ ...f, spec: s }))
))
const specByKey = {}
for (const s of specs.filter(Boolean)) specByKey[s.key] = s

phase('Implement')
const implResults = []
for (const f of FEATURES) {
  const s = specByKey[f.key]
  const specText = s && s.spec ? JSON.stringify(s.spec, null, 2) : '(research it yourself)'
  log(`Implementing: ${f.title}`)
  const r = await agent(`Implement ONE fix faithfully in the Swift port (work in cwd).
Feature: ${f.title}
${f.detail}
${COMMON}
Spec from research:
${specText}
Add focused tests (port the upstream test where one exists). Ensure \`swift build\` is green at finish.
Return the structured result.`,
    { label: `impl:${f.key}`, phase: 'Implement', schema: IMPL_SCHEMA })
  implResults.push(r)
  log(`Done: ${f.title} — build ${r && r.buildGreen ? 'GREEN' : 'NOT GREEN'}${r && r.incomplete ? ` — incomplete: ${r.incomplete}` : ''}`)
}

phase('Review')
const reviews = await parallel(FEATURES.map((f, i) => () => {
  const impl = implResults[i]
  return agent(`You are an Opus 4.8 high-effort fidelity REVIEWER. Adversarially verify this critical fix
is faithful to upstream codex-rs. Be skeptical; default to FAIL if it diverges or the build is not green.
Feature: ${f.title}
${f.detail}
${COMMON}
Implementation report: ${impl ? JSON.stringify(impl) : '(none)'}
Read the upstream Rust AND the port's ACTUAL current code (verify yourself, don't trust the report).
For the ordering fix, confirm the ported upstream test actually passes. For the safety fix, confirm
.never forbids dangerous commands and others prompt. For the freeform tool, confirm the wire shape and
that the custom_tool_call path routes raw patch text. Run \`swift build\` / targeted tests as needed.
Return PASS only if faithful AND tree green; otherwise FAIL with concrete issues.`,
    { label: `review:${f.key}`, phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' })
})).then(rs => rs.filter(Boolean))

phase('Gate')
const gate = await agent(`Final regression gate (cwd = ${SW}).
1. \`swift build -c release\` — confirm completion.
2. \`swift test --skip LiveTests\` — capture totals + the list of FAILED test case names.
Known pre-existing-WIP failures (report as pre-existing, NOT regressions): the 4 AdversarialTests
prompt-injection tests, IntegrationTests.EndToEndTests.testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath,
IntegrationTests.EndToEndTests.testFullStreamedTurnEndToEnd, TokenizerTests.testModelCatalogResolutionAndDerivation.
Known flaky in parallel: testRulesStoreReadLockedBlocksUntilWriterCompletes, testConcurrencyNoLeaks.
Return: release build status, test totals, and classify EVERY failure as pre-existing/flaky or REGRESSION (new).`,
  { label: 'gate:build+test', phase: 'Gate' })

return {
  implemented: implResults.filter(Boolean),
  reviews,
  reviewSummary: reviews.map(r => `${r.feature}: ${r.verdict}`),
  gate,
}
