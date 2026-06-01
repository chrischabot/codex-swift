export const meta = {
  name: 'remediate-wave-E',
  description: 'Final wave: reconcile remaining pre-existing-WIP failures to upstream fidelity (reviewed), then full suite + LIVE E2E (real OPENAI_API_KEY) + severe adversarial sweep',
  phases: [
    { title: 'Reconcile', detail: 'sequential: fix each remaining failing cluster + Opus review', model: 'opus' },
    { title: 'Suite', detail: 'authoritative full build + test (batched, all targets)' },
    { title: 'LiveE2E', detail: 'run OPENAI_API_KEY-gated LiveTests in batches' },
    { title: 'Severe', detail: 'adversarial/severe suites + final adversarial review of the whole remediation' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd = port root). JSON-RPC app-server-v2 fidelity port.
BUILD LOCK: only ONE swift build/test at a time — you are scheduled sequentially.
TEST-RUN DISCIPLINE (run is killed on 180s of no output): NEVER run the full unfiltered suite or LiveTests
as one command; ALWAYS use \`swift test --skip LiveTests --filter <Suite>\` scoped small, keep each invocation
under 3 minutes. The tree MUST stay green (\`swift build\` → "Build complete!").`

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['item', 'approach', 'filesChanged', 'buildGreen', 'testsNowPassing', 'summary', 'incomplete'],
  properties: {
    item: { type: 'string' },
    approach: { type: 'string', enum: ['fixed-source', 'updated-stale-test', 'implemented-feature', 'documented-divergence'] },
    filesChanged: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean' },
    testsNowPassing: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    incomplete: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['item', 'verdict', 'issues'],
  properties: {
    item: { type: 'string' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}

// The remaining failing clusters (pre-existing WIP that predates the audit waves).
const ITEMS = [
  {
    key: 'model-default-test',
    title: 'Stale model-catalog default assertion (gpt-5.1-codex → gpt-5.5)',
    detail: `TokenizerTests.testModelCatalogResolutionAndDerivation asserts defaultEntry().slug / listed().first?.slug
== "gpt-5.1-codex", but the source (Sources/Tokenizer/ModelCatalog.swift) deliberately marks "gpt-5.5" as
isDefault:true (the owner's intended default). Confirm "gpt-5.5" is the intended catalog default (it is the
only isDefault entry), then UPDATE the stale test assertions (Tests/TokenizerTests, lines ~84-85 and any
sibling) to expect "gpt-5.5". Do NOT revert the source default. Keep all other assertions in that test intact.`,
  },
  {
    key: 'approval-default-test',
    title: 'Stale approvalPolicy default assertion (never → on-request)',
    detail: `IntegrationTests.EndToEndTests.testFullStreamedTurnEndToEnd asserts the thread/start approvalPolicy
== "never", but the port's intended default is "on-request" (documented at Sources/Supervisor/RequestRouter.swift
~2315 "on-request is the port's intended default", and approvalPolicyFallback). Confirm on-request is the
intended faithful default (cross-check upstream AskForApproval default / thread-store parse_or_default →
OnRequest in ${UP}/thread-store/src/local/read_thread.rs:317), then UPDATE the stale test assertion to expect
"on-request". Do NOT change the runtime default. If the test also exercises other behavior, keep that intact.`,
  },
  {
    key: 'prompt-injection-snapshots',
    title: 'Prompt-injection byte-stability snapshots drifted from prompt refactor',
    detail: `The 4 failing AdversarialTests (FailureModeTests.testPromptInjectionIsTreatedAsDataOnly,
PromptInjectionAdversarialTests.testAgentsMdInjectionStaysEnveloped / testToolOutputMarkersDoNotForgeCompactionOrEscalate
/ testUserMarkerBreakoutIsInertData) assert byte-stable properties of the composed system prompt, which drifted
when the owner refactored Personality.swift / PromptComposer.swift / Templates.swift.
CRITICAL: these are SECURITY tests. First VERIFY the injection defense is still sound — that untrusted content
(AGENTS.md, tool output, user-marker text) is still safely enveloped as inert data and cannot forge system/
compaction/escalation markers. ONLY if the defense is genuinely intact, update the snapshot/expectation strings
to the current correct prompt text. If the refactor actually WEAKENED any envelope/escaping, FIX the prompt
composition instead of the test. Explain which path you took per test.`,
  },
  {
    key: 'remote-exec-data-path',
    title: 'Incomplete remote exec-server data-path feature',
    detail: `IntegrationTests.EndToEndTests.testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath
and testTurnStartAcceptsEnvironmentSwitchToRegisteredRemoteEnv fail on genuinely-incomplete behavior: the remote
exec-server should RECORD the turn's tool call over the exec-server data path, and the rollout env-binding rebind
count should be >=2 after an environment switch (got 1). This is a real unfinished feature, not a stale assertion.
Investigate the exec-server data-path wiring (Sources/Tools/RemoteExecServerTools.swift, the remote-env selection
in RequestRouter/SessionEngine, and the rollout env-rebind recording) and IMPLEMENT the missing behavior so both
tests pass — exec-server records the tool call, and the env switch produces the expected rebind count. If after
genuine effort a sub-part is architecturally infeasible without a large redesign, implement what you can, keep the
tree green, and document precisely what remains and why in incomplete.`,
  },
]

phase('Reconcile')
const reconciled = []
for (const it of ITEMS) {
  log(`reconcile: ${it.title}`)
  let impl = await agent(`Resolve ONE remaining failing cluster in the Swift port (cwd).
Item: ${it.title}
${it.detail}
${COMMON}
Default to upstream fidelity. Where the SOURCE already reflects the intended faithful state and only a TEST is
stale, update the test (approach=updated-stale-test). Where a feature is genuinely missing, implement it
(approach=implemented-feature). Build green; the named failing tests must now PASS (run them filtered). Return result.`,
    { label: `impl:${it.key}`, phase: 'Reconcile', schema: IMPL_SCHEMA })

  let review = await agent(`Opus 4.8 adversarial REVIEWER. Verify this reconciliation is correct and faithful — and for
the security item, that prompt-injection defense is genuinely intact (not just snapshot-rubber-stamped). Verify the
ACTUAL port code + that the named tests now pass (run them filtered). FAIL if a stale-test update masks a real
regression, if a security envelope was weakened, or if the build is not green.
Item: ${it.title}
${it.detail}
${COMMON}
Implementation report: ${JSON.stringify(impl)}
Return verdict + issues.`,
    { label: `review:${it.key}`, phase: 'Reconcile', schema: REVIEW_SCHEMA, model: 'opus' })

  let iter = 0
  while (review.verdict === 'FAIL' && iter < 2) {
    iter++
    log(`reconcile fix-loop ${iter}: ${it.key}`)
    impl = await agent(`Fix the issues the reviewer raised for this item. Keep the tree green; the named tests must pass.
Item: ${it.title}
${it.detail}
${COMMON}
Reviewer issues: ${JSON.stringify(review.issues)}
Prior report: ${JSON.stringify(impl)}
Return the impl result.`,
      { label: `fix:${it.key}:${iter}`, phase: 'Reconcile', schema: IMPL_SCHEMA })
    review = await agent(`Re-review (Opus, adversarial) after the fix. Verify the named tests pass + no regression/weakened
security. Item: ${it.title}. ${COMMON}\nReturn verdict + issues.`,
      { label: `re-review:${it.key}:${iter}`, phase: 'Reconcile', schema: REVIEW_SCHEMA, model: 'opus' })
  }
  log(`reconcile done: ${it.key} — ${review.verdict}`)
  reconciled.push({ item: it.key, approach: impl.approach, verdict: review.verdict,
                    testsNowPassing: impl.testsNowPassing || [], incomplete: impl.incomplete || '' })
}

phase('Suite')
const suite = await agent(`AUTHORITATIVE full regression (cwd = ${SW}). Run \`swift build -c release\` (confirm), then run
\`swift test --skip LiveTests\` across ALL targets in per-target filtered batches (each <3min): ProtocolModelTests,
HarnessCoreTests, ToolsTests, IntegrationTests, ConfigTests, ModelClientTests, PersistenceTests, AuthTests,
SandboxTests, PromptsTests, AdversarialTests, TokenizerTests, MCPTests, ChannelsTests, ExtensionsTests,
WireProtocolTests, SmallModelTests, WorkflowsTests, and any other test target present (enumerate via
\`swift test list\` or Package.swift). SUM totals. Report total tests, and the COMPLETE list of any remaining failing
test cases with their target. The goal is ZERO failures now (the prior pre-existing-WIP failures were just reconciled).
Classify any remaining failure as (a) genuinely-still-broken [must flag loudly] or (b) known parallel-flaky
(testRulesStoreReadLockedBlocksUntilWriterCompletes, testConcurrencyNoLeaks, testRemoteControlWebSocketReassembles...).`,
  { label: 'suite:full', phase: 'Suite' })

phase('LiveE2E')
const live = await agent(`Run the LIVE end-to-end suite with the real OPENAI_API_KEY (it IS set in env). cwd = ${SW}.
Run the LiveTests target in SMALL per-suite filtered batches (each well under 3 minutes — live calls are slow):
e.g. \`swift test --filter LiveTests.<SpecificSuite>\` for each suite under Tests/LiveTests (LiveTests, LiveDeepTests,
LiveRealWorldTests, LiveHarnessExecPatchTests, LiveHarnessCompactionApprovalsTests, LiveHarnessFileIoWebTests,
LiveHarnessMcpCodeModeToolSearchTests, LiveHarnessMultiAgentTests, LiveHarnessMemorySkillsTests,
LiveHarnessAdversarialSevereTests, LiveSmallModelTests, LiveChatCompletionsClientTests, LiveWorkflows* etc.).
Do a few suites at a time so output keeps flowing. Report per-suite pass/fail totals and any genuine failures
(distinguish real failures from rate-limit/network flakes — retry a flaky suite once). Summarize whether the live
turn lifecycle, exec/apply_patch, compaction, MCP, and multi-agent paths work end-to-end against the real API.`,
  { label: 'live:e2e', phase: 'LiveE2E' })

phase('Severe')
const severe = await agent(`Final SEVERE adversarial sweep of the whole remediation (cwd = ${SW}). (1) Run the adversarial/severe
test suites filtered: AdversarialTests (all), SecurityAdversarialTests, AuthGatingAdversarialTests, ToolsAdversarialTests,
PromptInjectionAdversarialTests, WireByteFaithfulTests, and LiveHarnessAdversarialSevereTests (live, small batches).
(2) Then act as an adversarial auditor: pick the 5 highest-risk changes from waves A–E (exec-policy dangerous-command
gate, apply_patch ordering, sandbox writable-root params, MCP tool-name hashing, codexErrorInfo enum, config projection,
auth refresh) and try to BREAK them — construct edge cases / malicious inputs and verify the port behaves safely and
upstream-faithfully. Report any real weakness found (with a repro), or confirm the surfaces are sound. Keep each test
invocation under 3 minutes.`,
  { label: 'severe:sweep', phase: 'Severe' })

return { reconciled, suite, live, severe }
