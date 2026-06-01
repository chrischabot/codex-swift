export const meta = {
  name: 'remediate-wave',
  description: 'Remediate one wave of audit-v7 findings (a set of units): parallel spec → sequential implement+adversarial-review+fix-loop per unit → wave gate. Lock-safe (one build/test at a time).',
  phases: [
    { title: 'Spec', detail: 'parallel read-only research per unit' },
    { title: 'Remediate', detail: 'sequential per unit: implement → Opus review → fix-loop until all findings done', model: 'opus' },
    { title: 'Gate', detail: 'build + targeted tests for the wave' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'
const FINDINGS = `${SW}/tools/audit-findings-v8.json`

// args = { wave: "A", units: ["tools-router", ...] } — optional override.
// Self-contained fallback (edited per wave) since args may not be forwarded with scriptPath.
const WAVE = (args && args.wave) || 'F'
const UNITS = (args && args.units) || ["model-client", "tools-router", "apply-patch", "config"]

const SPEC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'findingCount', 'portFiles', 'plan', 'intentionalDivergences', 'risks'],
  properties: {
    unit: { type: 'string' },
    findingCount: { type: 'integer' },
    portFiles: { type: 'array', items: { type: 'string' } },
    plan: { type: 'array', items: { type: 'string' }, description: 'ordered concrete edits, one or more per finding, each tagged with the finding title' },
    intentionalDivergences: { type: 'array', items: { type: 'string' }, description: 'findings that are deliberate port divergences NOT to change, with justification' },
    risks: { type: 'string' },
  },
}

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'findingsAddressed', 'filesChanged', 'testsAdded', 'buildGreen', 'summary', 'notDone'],
  properties: {
    unit: { type: 'string' },
    findingsAddressed: { type: 'array', items: { type: 'string' }, description: 'finding titles fully implemented' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    testsAdded: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean' },
    summary: { type: 'string' },
    notDone: { type: 'array', items: { type: 'string' }, description: 'finding titles NOT fully done + why (intentional divergence or blocked)' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'verdict', 'perFinding', 'unresolved'],
  properties: {
    unit: { type: 'string' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    perFinding: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'status'],
        properties: {
          title: { type: 'string' },
          status: { type: 'string', enum: ['FAITHFUL', 'DIVERGENT', 'INTENTIONAL_SKIP', 'MISSING'] },
          issue: { type: 'string' },
        },
      },
    },
    unresolved: { type: 'array', items: { type: 'string' }, description: 'finding titles that are DIVERGENT or MISSING (must be fixed)' },
  },
}

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd is the port root).
This is a JSON-RPC app-server-v2 fidelity port of codex-rs. Wire fidelity is paramount:
serde camelCase, internally/externally-tagged enums (#[serde(tag=...)]), skip_serializing_if,
null-vs-omit — reproduce EXACTLY. Match existing port idioms.
The complete verified findings backlog is ${FINDINGS} (JSON: units{<unit>:[{title,severity,
category,rustEvidence,swiftStatus,description,fixRecommendation}]}). Read it and filter to YOUR unit.
BUILD LOCK: only ONE swift build/test may run at a time across this whole workflow — you are
scheduled sequentially, so just run your builds/tests normally; do not spawn background builds.
The tree MUST stay green: run \`swift build\` and confirm "Build complete!" before finishing; if a
piece can't compile, revert just that piece and report it. Do NOT regress existing tests.
TEST-RUN DISCIPLINE (MANDATORY — the run is killed if any single command shows no output for 180s):
- NEVER run the full unfiltered suite. ALWAYS use \`swift test --skip LiveTests --filter <SpecificSuiteOrTest>\`
  scoped to the few suites your unit touches.
- NEVER run LiveTests here (they make live API calls and will hang the run); live E2E is a separate final wave.
- Keep every single \`swift\`/\`swift test\` invocation well under 3 minutes. If a build/test would take longer,
  split it into smaller filtered runs so output keeps flowing.`

log(`Wave ${WAVE}: ${UNITS.length} units → ${UNITS.join(', ')}`)

// ---- Phase 1: Spec (parallel, read-only) ----
phase('Spec')
const specs = await parallel(UNITS.map(u => () =>
  agent(`Read-only research for ONE audit unit. Produce a precise remediation plan.
Unit: "${u}"
${COMMON}
Read ${FINDINGS}, filter to unit=="${u}", and for EVERY finding in it: read the cited rustEvidence in
upstream and the swiftStatus location in the port, then produce an ordered edit plan (tag each step
with its finding title). Flag any finding that is a DELIBERATE port divergence (e.g. an intentional
architectural choice an existing test depends on) under intentionalDivergences with justification —
but default strongly to faithful reproduction. Do NOT edit files.`,
    { label: `spec:${u}`, phase: 'Spec', schema: SPEC_SCHEMA, agentType: 'Explore' }
  ).then(s => ({ unit: u, spec: s }))
))
const specByUnit = {}
for (const s of specs.filter(Boolean)) specByUnit[s.unit] = s.spec

// ---- Phase 2: Remediate (SEQUENTIAL per unit; implement → review → fix-loop) ----
phase('Remediate')
const results = []
for (const u of UNITS) {
  const spec = specByUnit[u]
  const specText = spec ? JSON.stringify(spec, null, 2) : '(no spec; research it yourself)'
  log(`[${u}] implementing`)
  let impl = await agent(`Implement EVERY finding for ONE audit unit, faithfully, in the Swift port (cwd).
Unit: "${u}"
${COMMON}
Read ${FINDINGS}, filter to unit=="${u}", and implement ALL of its findings (both major and minor).
Use the fixRecommendation + rustEvidence on each. For each finding either (a) faithfully reproduce the
upstream behavior/wire-shape, or (b) if it is a deliberate documented port divergence an existing test
depends on, leave it and record it in notDone with justification — but default strongly to fixing.
Add/extend focused unit tests for each behavioral change (port the upstream test when one exists).
Ensure \`swift build\` is green and run the unit's targeted test suites.
Research plan:
${specText}
Return the structured result.`,
    { label: `impl:${u}`, phase: 'Remediate', schema: IMPL_SCHEMA })

  // Adversarial Opus review, then bounded fix-loop until nothing unresolved.
  let review = await agent(`You are an Opus 4.8 high-effort adversarial REVIEWER. Verify EVERY finding for
this unit was reproduced FAITHFULLY from upstream codex-rs. Be skeptical; verify the ACTUAL current port
code yourself (don't trust the impl report). Status per finding: FAITHFUL (matches upstream),
INTENTIONAL_SKIP (a justified deliberate divergence — acceptable), DIVERGENT (changed but still wrong),
MISSING (not done). Mark verdict FAIL if any finding is DIVERGENT or MISSING, or the build is not green.
Unit: "${u}"
${COMMON}
Read ${FINDINGS} (filter to unit=="${u}") for the full finding list. Implementation report: ${JSON.stringify(impl)}
Run \`swift build\` + the unit's targeted tests as needed. Return per-finding statuses + the unresolved list.`,
    { label: `review:${u}`, phase: 'Remediate', schema: REVIEW_SCHEMA, model: 'opus' })

  let iter = 0
  while (review.verdict === 'FAIL' && (review.unresolved || []).length && iter < 2) {
    iter++
    log(`[${u}] fix-loop ${iter}: ${review.unresolved.length} unresolved`)
    const fix = await agent(`Fix the UNRESOLVED findings for this unit (the prior pass left them DIVERGENT or
MISSING). Make each faithful to upstream; keep the build green; add tests.
Unit: "${u}"
${COMMON}
Unresolved findings to fix: ${JSON.stringify(review.unresolved)}
Reviewer detail: ${JSON.stringify(review.perFinding)}
Read ${FINDINGS} (filter unit=="${u}") + the cited rustEvidence. Return the structured impl result.`,
      { label: `fix:${u}:${iter}`, phase: 'Remediate', schema: IMPL_SCHEMA })
    impl = { ...impl, findingsAddressed: [...(impl.findingsAddressed||[]), ...(fix.findingsAddressed||[])],
             filesChanged: [...new Set([...(impl.filesChanged||[]), ...(fix.filesChanged||[])])],
             notDone: fix.notDone || [] }
    review = await agent(`Re-review (adversarial, Opus) the previously-unresolved findings for this unit after a fix pass.
Unit: "${u}"
${COMMON}
Previously unresolved: ${JSON.stringify(review.unresolved)}
Read ${FINDINGS} (filter unit=="${u}"). Verify the ACTUAL port code + run targeted tests. Return per-finding statuses + unresolved.`,
      { label: `re-review:${u}:${iter}`, phase: 'Remediate', schema: REVIEW_SCHEMA, model: 'opus' })
  }
  log(`[${u}] done — verdict ${review.verdict}${(review.unresolved||[]).length ? ` (still unresolved: ${review.unresolved.join('; ')})` : ''}`)
  results.push({ unit: u, impl, review })
}

// ---- Phase 3: Wave gate ----
phase('Gate')
const gate = await agent(`Wave ${WAVE} gate (cwd = ${SW}). Run \`swift build -c release\` (confirm completion), then run
the test suite. IMPORTANT (the run is killed on 180s of no output): do NOT run one giant unfiltered
\`swift test\`. Instead run it in per-target batches that each finish in well under 3 minutes, e.g.
\`swift test --skip LiveTests --filter <Target>\` for each test target (ProtocolModelTests, HarnessCoreTests,
ToolsTests, IntegrationTests, ConfigTests, ModelClientTests, PersistenceTests, AuthTests, SandboxTests,
PromptsTests, AdversarialTests, TokenizerTests, MCPTests, ChannelsTests, ExtensionsTests, WireProtocolTests),
and SUM the totals. Never run LiveTests. Capture totals + FAILED test case names across the batches.
Known pre-existing-WIP failures
(report as pre-existing, NOT regressions): the 4 AdversarialTests prompt-injection tests,
IntegrationTests.EndToEndTests.testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath,
IntegrationTests.EndToEndTests.testFullStreamedTurnEndToEnd, TokenizerTests.testModelCatalogResolutionAndDerivation.
Known parallel-flaky: testRulesStoreReadLockedBlocksUntilWriterCompletes, testConcurrencyNoLeaks,
testRemoteControlWebSocketReassemblesClientChunksAndSplitsLargeServerMessages.
NOTE: some of this wave's fidelity fixes may legitimately UPDATE those pre-existing-WIP assertions (e.g.
approvalPolicy default, prompt-snapshot text) — if a previously-failing pre-existing test now PASSES, say so.
Return: release build status, test totals, and classify EVERY failure as pre-existing/flaky or REGRESSION (new).`,
  { label: `gate:wave-${WAVE}`, phase: 'Gate' })

return {
  wave: WAVE,
  units: results.map(r => ({
    unit: r.unit, verdict: r.review.verdict,
    unresolved: r.review.unresolved || [],
    notDone: r.impl.notDone || [],
    filesChanged: r.impl.filesChanged || [],
    testsAdded: r.impl.testsAdded || [],
  })),
  gate,
}
