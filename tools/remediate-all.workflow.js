export const meta = {
  name: 'remediate-all',
  description: 'Run remaining audit-v8 waves G,H,I (spec→implement→Opus-review→fix-loop→gate per unit, sequential/lock-safe), then re-audit inline',
  phases: [
    { title: 'Spec', detail: 'parallel read-only research per unit' },
    { title: 'Remediate', detail: 'sequential implement → Opus review → fix-loop per unit', model: 'opus' },
    { title: 'Gate', detail: 'build + targeted tests per wave' },
    { title: 'ReAudit', detail: 'inline audit-fidelity validation pass' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'
const FINDINGS = `${SW}/tools/audit-findings-v13.json`

// v13 round (after v12; 0 criticals). 12 maj / 28 min across 14 units.
// Round 1 = waves Z+AA (security bugs + 10 of 12 majors). Inline audit disabled.
const SKIP_AUDIT = true
const WAVES = [
  { wave: 'AB', units: ['app-server-events', 'context-compaction', 'protocol-wire-types', 'app-server-registry'] },
  { wave: 'AC', units: ['exec-unified-shell', 'persistence-rollout'] },
]

const SPEC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'portFiles', 'plan', 'intentionalDivergences', 'risks'],
  properties: {
    unit: { type: 'string' },
    portFiles: { type: 'array', items: { type: 'string' } },
    plan: { type: 'array', items: { type: 'string' } },
    intentionalDivergences: { type: 'array', items: { type: 'string' } },
    risks: { type: 'string' },
  },
}
const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'findingsAddressed', 'filesChanged', 'buildGreen', 'summary', 'notDone'],
  properties: {
    unit: { type: 'string' },
    findingsAddressed: { type: 'array', items: { type: 'string' } },
    filesChanged: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean' },
    summary: { type: 'string' },
    notDone: { type: 'array', items: { type: 'string' } },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'verdict', 'perFinding', 'unresolved'],
  properties: {
    unit: { type: 'string' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    perFinding: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['title', 'status'],
      properties: { title: { type: 'string' },
        status: { type: 'string', enum: ['FAITHFUL', 'DIVERGENT', 'INTENTIONAL_SKIP', 'MISSING'] },
        issue: { type: 'string' } } } },
    unresolved: { type: 'array', items: { type: 'string' } },
  },
}

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd = port root). JSON-RPC app-server-v2 fidelity port.
Wire fidelity is paramount (serde camelCase, tagged enums, skip_serializing_if, null-vs-omit) — reproduce EXACTLY.
Findings backlog: ${FINDINGS} (JSON units{<unit>:[{title,severity,category,rustEvidence,swiftStatus,description,
fixRecommendation}]}). Read it, filter to YOUR unit.
BUILD LOCK: only ONE swift build/test at a time across this whole run — you are scheduled sequentially.
TEST DISCIPLINE (run is KILLED on 180s of no output): NEVER run the full unfiltered suite or LiveTests as one
command; ALWAYS \`swift test --skip LiveTests --filter <Suite>\` scoped small, each under 3 minutes. Keep
\`swift build\` green; if a piece can't compile, revert just it and report. Do NOT regress existing tests, and do
NOT touch the untracked BenchKit/codex-bench/Benchmarks WIP (another worker's). Default strongly to faithful
reproduction; only skip a finding if it is a deliberate documented port divergence an existing test depends on.`

async function remediateWave(W) {
  log(`=== WAVE ${W.wave}: ${W.units.join(', ')} ===`)

  // Spec — parallel, read-only (no build → lock-safe to parallelise).
  const specs = await parallel(W.units.map(u => () =>
    agent(`Read-only research for ONE audit unit; produce a precise remediation plan.
Unit: "${u}"
${COMMON}
Read ${FINDINGS} (filter unit=="${u}"); for EVERY finding read the cited rustEvidence + swiftStatus and produce an
ordered edit plan (tag each step with its finding title). Flag deliberate port divergences under
intentionalDivergences with justification. Do NOT edit files.`,
      { label: `spec:${W.wave}:${u}`, phase: `Spec-${W.wave}`, schema: SPEC_SCHEMA, agentType: 'Explore' }
    ).then(s => ({ unit: u, spec: s }))))
  const byUnit = {}
  for (const s of specs.filter(Boolean)) byUnit[s.unit] = s.spec

  // Remediate — SEQUENTIAL per unit (build lock): implement → review → bounded fix-loop.
  const results = []
  for (const u of W.units) {
    const specText = byUnit[u] ? JSON.stringify(byUnit[u], null, 2) : '(research it yourself)'
    log(`[${W.wave}/${u}] implementing`)
    let impl = await agent(`Implement EVERY finding for ONE audit unit, faithfully (cwd = port root).
Unit: "${u}"
${COMMON}
Read ${FINDINGS} (filter unit=="${u}") and implement ALL its findings (major + minor) using fixRecommendation +
rustEvidence. Add/extend focused unit tests for each behavioral change (port the upstream test when one exists).
Ensure \`swift build\` is green + run the unit's targeted test suites.
Research plan:
${specText}
Return the structured result.`,
      { label: `impl:${W.wave}:${u}`, phase: `Remediate-${W.wave}`, schema: IMPL_SCHEMA })

    let review = await agent(`Opus 4.8 adversarial REVIEWER. Verify EVERY finding for this unit was reproduced
FAITHFULLY from upstream codex-rs. Verify the ACTUAL current port code yourself (don't trust the report). Per-finding
status: FAITHFUL / INTENTIONAL_SKIP (justified divergence — acceptable) / DIVERGENT (changed but wrong) / MISSING.
FAIL if any finding is DIVERGENT or MISSING, or the build is not green.
Unit: "${u}"
${COMMON}
Read ${FINDINGS} (filter unit=="${u}"). Implementation report: ${JSON.stringify(impl)}
Run \`swift build\` + the unit's targeted tests. Return per-finding statuses + the unresolved list.`,
      { label: `review:${W.wave}:${u}`, phase: `Remediate-${W.wave}`, schema: REVIEW_SCHEMA, model: 'opus' })

    let iter = 0
    while (review.verdict === 'FAIL' && (review.unresolved || []).length && iter < 2) {
      iter++
      log(`[${W.wave}/${u}] fix-loop ${iter}: ${review.unresolved.length} unresolved`)
      const fix = await agent(`Fix the UNRESOLVED findings for this unit (prior pass left them DIVERGENT/MISSING).
Make each faithful to upstream; keep the build green; add tests.
Unit: "${u}"
${COMMON}
Unresolved: ${JSON.stringify(review.unresolved)}
Reviewer detail: ${JSON.stringify(review.perFinding)}
Read ${FINDINGS} (filter unit=="${u}") + cited rustEvidence. Return the impl result.`,
        { label: `fix:${W.wave}:${u}:${iter}`, phase: `Remediate-${W.wave}`, schema: IMPL_SCHEMA })
      impl = { ...impl, notDone: fix.notDone || [],
               filesChanged: [...new Set([...(impl.filesChanged || []), ...(fix.filesChanged || [])])] }
      review = await agent(`Re-review (Opus, adversarial) the previously-unresolved findings for this unit after a fix.
Unit: "${u}"
${COMMON}
Previously unresolved: ${JSON.stringify(review.unresolved)}
Read ${FINDINGS} (filter unit=="${u}"). Verify the ACTUAL code + run targeted tests. Return per-finding + unresolved.`,
        { label: `re-review:${W.wave}:${u}:${iter}`, phase: `Remediate-${W.wave}`, schema: REVIEW_SCHEMA, model: 'opus' })
    }
    log(`[${W.wave}/${u}] ${review.verdict}${(review.unresolved || []).length ? ` unresolved: ${review.unresolved.join('; ')}` : ''}`)
    results.push({ unit: u, verdict: review.verdict, unresolved: review.unresolved || [],
                   notDone: impl.notDone || [], filesChanged: impl.filesChanged || [] })
  }

  // Gate — build + batched targeted tests.
  const gate = await agent(`Wave ${W.wave} gate (cwd = ${SW}). Run \`swift build -c release\` (confirm completion), then run
the suite in per-target filtered batches (each <3min): \`swift test --skip LiveTests --filter <Target>\` for
ProtocolModelTests, HarnessCoreTests, ToolsTests, IntegrationTests, ConfigTests, ModelClientTests, PersistenceTests,
AuthTests, SandboxTests, PromptsTests, AdversarialTests, TokenizerTests, MCPTests, ChannelsTests, WireProtocolTests,
and the units this wave touched. Never run LiveTests/the full unfiltered suite. SUM totals; list any failing test
cases. Classify each failure as pre-existing/known-flaky (testRulesStoreReadLockedBlocksUntilWriterCompletes,
testConcurrencyNoLeaks, testRemoteControlWebSocketReassembles...) or REGRESSION (new) — flag regressions loudly.`,
    { label: `gate:${W.wave}`, phase: `Gate-${W.wave}` })

  return { wave: W.wave, units: results, gate }
}

const waveResults = []
for (const W of WAVES) waveResults.push(await remediateWave(W))

// Re-audit inline (one-level nested workflow) to measure convergence after the waves.
let audit = null
if (!SKIP_AUDIT) {
  phase('ReAudit')
  log('Running audit-fidelity re-audit to measure convergence...')
  try {
    audit = await workflow({ scriptPath: `${SW}/tools/audit-fidelity.workflow.js` })
  } catch (e) {
    log(`re-audit failed to run inline: ${e}`)
  }
} else {
  log('SKIP_AUDIT set — run audit-fidelity separately after this orchestrator completes.')
}

return {
  waves: waveResults.map(w => ({
    wave: w.wave,
    summary: w.units.map(u => `${u.unit}:${u.verdict}${u.unresolved.length ? `(unresolved:${u.unresolved.length})` : ''}`),
    units: w.units,
    gate: w.gate,
  })),
  auditTotals: audit ? (audit.totals || audit.result?.totals || null) : null,
  audit: audit || null,   // full result (incl. confirmed findings) for the next round
}
