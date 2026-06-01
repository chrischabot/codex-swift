export const meta = {
  name: 'finish-longtail',
  description: 'Implement the remaining codex-rs→codex-swift architectural long tail (turn/diff tracker, remote compaction, ThreadStatus flags, lifecycle notifications, steer/gating) with Opus reviewers',
  phases: [
    { title: 'Spec', detail: 'parallel read-only research of upstream + port per feature' },
    { title: 'Implement', detail: 'sequential, tree-green-gated implementation per feature' },
    { title: 'Review', detail: 'Opus 4.8 high-effort fidelity reviewer per feature', model: 'opus' },
    { title: 'Gate', detail: 'final full build + test suite' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'

const SPEC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['feature', 'upstreamRefs', 'portFiles', 'wireShapes', 'plan', 'risks'],
  properties: {
    feature: { type: 'string' },
    upstreamRefs: { type: 'array', items: { type: 'string' }, description: 'upstream file:line refs that define the contract' },
    portFiles: { type: 'array', items: { type: 'string' }, description: 'swift files to add or edit' },
    wireShapes: { type: 'string', description: 'exact JSON wire shapes / serde attributes to reproduce (camelCase, tags, skip_serializing_if)' },
    plan: { type: 'array', items: { type: 'string' }, description: 'ordered concrete edits' },
    risks: { type: 'string', description: 'shared-file conflicts, test churn, behavior risks' },
  },
}

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['feature', 'filesChanged', 'buildGreen', 'testsAdded', 'summary', 'incomplete'],
  properties: {
    feature: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean', description: 'true ONLY if `swift build` succeeds at finish' },
    testsAdded: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    incomplete: { type: 'string', description: 'anything left unfinished or reverted to keep the tree green; empty string if fully done' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['feature', 'faithful', 'verdict', 'issues'],
  properties: {
    feature: { type: 'string' },
    faithful: { type: 'boolean', description: 'true iff the port faithfully reproduces the upstream contract' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    issues: { type: 'array', items: { type: 'string' }, description: 'concrete divergences from upstream; empty if PASS' },
  },
}

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd is the port root).
This is a JSON-RPC app-server-v2 fidelity port. Wire fidelity is paramount:
serde camelCase, internally-tagged enums (#[serde(tag="type")]), skip_serializing_if
must all be reproduced exactly. Match the existing port idioms (JSONValue,
Codable wire types, the Events/ProtocolModel/SessionEngine structure).
Cross-reference tools/audit-findings.txt and tools/FIDELITY_REMEDIATION.md for context.`

// The remaining architectural long tail. Ordered so earlier features establish
// types/plumbing later ones can reuse. Implemented SEQUENTIALLY because they all
// touch shared files (Events.swift, SessionEngine.swift, ProtocolModel, RequestRouter).
const FEATURES = [
  {
    key: 'turn-diff',
    title: 'turn/diff/updated + TurnDiffTracker',
    detail: `Reproduce upstream's TurnDiffTracker and the turn/diff/updated notification.
Upstream: search ${UP} for "TurnDiffTracker", "turn_diff", "TurnDiffEvent", and the
unified-diff aggregation that accumulates per-turn file changes (apply_patch + exec
file writes) into a single cumulative unified diff emitted as turn/diff/updated.
Port: add a TurnDiffTracker type (likely Sources/HarnessCore or Sources/Tools), wire it
into SessionEngine so each file mutation in a turn updates the tracker and emits the
turn/diff/updated notification (add the event case to Sources/ProtocolModel/Events.swift).
Reproduce the exact wire shape (method name, params: the cumulative unified diff string).`,
  },
  {
    key: 'remote-compact',
    title: 'remote /compact endpoint (OpenAI provider)',
    detail: `Reproduce upstream remote compaction. Upstream: search ${UP} for the compact
endpoint / "compact" request against the Responses API (the server-side summarization the
default OpenAI provider uses instead of the local prompt-driven compaction). Find how the
request is built and the summary response parsed.
Port: the 3 transports live in Sources/ModelClient/{OpenAI,URLSession,WebSocket}ResponsesClient.swift
and compaction logic in SessionEngine/compaction. Add the remote-compact request path for the
default provider, parse the returned summary, and feed it into the existing compaction flow.
Keep the local-compaction fallback intact for providers without the endpoint.`,
  },
  {
    key: 'thread-status',
    title: 'ThreadStatus tagged activeFlags + commandActions',
    detail: `Reproduce two upstream wire details. (1) thread/status/changed: ThreadStatus must
carry the tagged "active flags" set. Upstream: search ${UP} for "ThreadStatus", "activeFlags"/
"active_flags", thread status reporting. (2) commandExecution items must carry "commandActions"
(the tagged action set on the command item). Upstream: search for "commandActions"/"command_actions"
on the command-execution item type.
Port: ProtocolModel (Items.swift + the thread-status type) + wherever thread/status/changed is
emitted (RequestRouter/SessionEngine). Reproduce exact tags + camelCase.`,
  },
  {
    key: 'lifecycle-notifs',
    title: 'terminalInteraction + fileChange/patchUpdated + autoApprovalReview/* notifications',
    detail: `Add the remaining lifecycle notifications. Upstream: search ${UP} for
"terminalInteraction"/"terminal_interaction", "patchUpdated"/"patch_updated" (item/fileChange/patchUpdated),
and "autoApprovalReview"/"auto_approval_review" (item/autoApprovalReview/* lifecycle). Determine each
method name, params shape, and when it fires.
Port: add the event cases to Sources/ProtocolModel/Events.swift and emit them from the right SessionEngine
sites (terminal/PTY interaction, apply_patch incremental update, auto-approval guardian review lifecycle).
Reproduce exact wire shapes.`,
  },
  {
    key: 'steer-gating',
    title: 'turn/steer validation + whole-method experimental gating',
    detail: `(1) turn/steer: reproduce upstream's request validation for the steer method (the
guard conditions / error responses when steering is invalid). Upstream: search ${UP} for "steer",
turn steering validation. (2) Whole-method experimental gating: upstream gates certain whole methods
behind the experimental API flag. Search ${UP} for the experimental-method gate list.
Port: Sources/Supervisor/RequestRouter.swift + Sources/WireProtocol/ExperimentalGate.swift +
Sources/ProtocolModel/ClientRequest.swift. IMPORTANT: the port INTENTIONALLY serves
fuzzyFileSearch/remoteControl/realtime/goal WITHOUT experimentalApi (forcing the gate there broke
10+ tests previously — see FIDELITY_REMEDIATION.md). Only gate the methods upstream actually gates,
and add steer validation. Do not regress existing tests.`,
  },
]

// ---- Phase 1: Spec (parallel, read-only research) ----
phase('Spec')
const specs = await parallel(FEATURES.map(f => () =>
  agent(
    `You are researching ONE feature to produce a precise, faithful implementation spec.
Feature: ${f.title}
${f.detail}
${COMMON}
Do NOT edit any files — this is read-only research. Read the upstream Rust definitions and the
current Swift port, then return the spec: exact upstream refs, the port files to touch, the exact
wire shapes to reproduce, an ordered edit plan, and risks (especially shared-file conflicts).`,
    { label: `spec:${f.key}`, phase: 'Spec', schema: SPEC_SCHEMA, agentType: 'Explore' }
  ).then(s => ({ ...f, spec: s }))
))

const specByKey = {}
for (const s of specs.filter(Boolean)) specByKey[s.key] = s

// ---- Phase 2: Implement (SEQUENTIAL — shared files, each keeps tree green) ----
phase('Implement')
const implResults = []
for (const f of FEATURES) {
  const s = specByKey[f.key]
  const specText = s && s.spec ? JSON.stringify(s.spec, null, 2) : '(no spec produced; research it yourself first)'
  log(`Implementing: ${f.title}`)
  const r = await agent(
    `Implement ONE feature faithfully in the Swift port. Work in the main working tree (cwd).
Feature: ${f.title}
${f.detail}
${COMMON}

Implementation spec from the research phase:
${specText}

Requirements:
- Reproduce the upstream wire shape EXACTLY (method names, tags, camelCase, optional-field omission).
- Match existing port idioms. Add focused unit tests where the existing suites have a natural home
  (Tests/ProtocolModelTests, Tests/HarnessCoreTests, Tests/IntegrationTests, etc.).
- The tree MUST build green when you finish: run \`swift build\` and confirm "Build complete!".
- If you cannot make a piece compile/work cleanly, REVERT that piece so the tree stays green and
  report it precisely in "incomplete" — never leave the build broken for the next feature.
- Do NOT regress existing behavior; remember the intentional non-gating of
  fuzzyFileSearch/remoteControl/realtime/goal.
Return the structured result.`,
    { label: `impl:${f.key}`, phase: 'Implement', schema: IMPL_SCHEMA }
  )
  implResults.push(r)
  log(`Done: ${f.title} — build ${r && r.buildGreen ? 'GREEN' : 'NOT GREEN'}${r && r.incomplete ? ` — incomplete: ${r.incomplete}` : ''}`)
}

// ---- Phase 3: Review (parallel, Opus 4.8 high-effort per the goal) ----
phase('Review')
const reviews = await parallel(FEATURES.map((f, i) => () => {
  const impl = implResults[i]
  const s = specByKey[f.key]
  return agent(
    `You are an Opus 4.8 high-effort fidelity REVIEWER. Adversarially verify that this feature was
reproduced FAITHFULLY from upstream codex-rs in the Swift port. Be skeptical; default to FAIL if the
wire shape, method name, tagging, casing, or firing conditions diverge from upstream.
Feature: ${f.title}
${f.detail}
${COMMON}

Spec: ${s && s.spec ? JSON.stringify(s.spec) : '(none)'}
Implementation report: ${impl ? JSON.stringify(impl) : '(none)'}

Read the upstream Rust contract AND the port's actual current code (do not trust the report — verify
the files yourself). Confirm: exact method name, exact params/wire shape, serde-equivalent encoding
(camelCase, tags, omitted optionals), correct firing sites, and that the build is green
(run \`swift build\` if needed). Return PASS only if it is a faithful reproduction with the tree green;
otherwise FAIL with concrete issues.`,
    { label: `review:${f.key}`, phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' }
  )
})).then(rs => rs.filter(Boolean))

// ---- Phase 4: Final gate (full build + suite) ----
phase('Gate')
const gate = await agent(
  `Run the final regression gate for the Swift port (cwd = ${SW}).
1. \`swift build -c release\` — confirm it completes.
2. \`swift test --skip LiveTests\` — capture the totals line and the list of FAILED test names.
Known pre-existing-WIP failures NOT caused by this work (report them as pre-existing, not regressions):
the 4 AdversarialTests prompt-injection tests, the 2 IntegrationTests.EndToEndTests
(testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath, testFullStreamedTurnEndToEnd),
and TokenizerTests.testModelCatalogResolutionAndDerivation. Also known timing-flaky in parallel:
testRulesStoreReadLockedBlocksUntilWriterCompletes, testConcurrencyNoLeaks.
Return a concise report: release build status, test totals, and a classification of every failure as
either "pre-existing/flaky" or "REGRESSION (new)".`,
  { label: 'gate:build+test', phase: 'Gate' }
)

return {
  specs: specs.filter(Boolean).map(s => ({ feature: s.title, portFiles: s.spec && s.spec.portFiles })),
  implemented: implResults.filter(Boolean),
  reviews,
  reviewSummary: reviews.map(r => `${r.feature}: ${r.verdict}`),
  gate,
}
