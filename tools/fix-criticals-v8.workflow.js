export const meta = {
  name: 'fix-criticals-v8',
  description: 'Fix the 3 re-ranked criticals from the post-waves validation audit (rollout response_item dual-write, config profiles projection, auth nested plan_type claim) with Opus reviewers',
  phases: [
    { title: 'Implement', detail: 'sequential, tree-green-gated implementation per critical' },
    { title: 'Review', detail: 'Opus 4.8 high-effort fidelity reviewer per critical', model: 'opus' },
    { title: 'Gate', detail: 'build + targeted tests' },
  ],
}

const UP = '/Users/chabotc/Projects/codex/codex-rs'
const SW = '/Users/chabotc/Projects/codex-swift'

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'filesChanged', 'buildGreen', 'testsAdded', 'summary', 'incomplete'],
  properties: {
    feature: { type: 'string' }, filesChanged: { type: 'array', items: { type: 'string' } },
    buildGreen: { type: 'boolean' }, testsAdded: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' }, incomplete: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['feature', 'verdict', 'issues'],
  properties: {
    feature: { type: 'string' }, verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    issues: { type: 'array', items: { type: 'string' } },
  },
}

const COMMON = `
Repos: upstream Rust = ${UP} ; Swift port = ${SW} (cwd = port root). JSON-RPC app-server-v2 fidelity port.
BUILD LOCK: only ONE swift build/test at a time (you run sequentially). TEST DISCIPLINE (run killed on 180s no
output): NEVER run the full unfiltered suite or LiveTests as one command; use \`swift test --skip LiveTests
--filter <Suite>\` scoped small, each under 3 min. Keep \`swift build\` green. Do NOT touch the untracked
BenchKit/codex-bench/Benchmarks WIP (another worker's). Match existing port idioms; reproduce wire/serde exactly.`

const FEATURES = [
  {
    key: 'rollout-response-item',
    title: 'Rollout: persist user/assistant text as RolloutItem::ResponseItem (cross-impl resume)',
    detail: `BUG: upstream durably persists each turn's user-input and assistant messages as RolloutItem::ResponseItem
lines and reconstructs history EXCLUSIVELY from those (+ Compacted). The Swift port writes user/assistant TEXT only
as event_msg/user_message and event_msg/agent_message lines, so an upstream codex CLI/app-server opening a Swift
rollout (resume/fork, list preview via extract_metadata, truncation) rebuilds EMPTY model history and detects zero
user-turn boundaries. Assistant REASONING is correctly written as response_item, but assistant TEXT is not.
UPSTREAM: ${UP}/core/src/session/turn.rs:314-332 builds user input as a ResponseItem; record_conversation_items →
persist_rollout_response_items (mod.rs:2598-2604) writes a \`response_item\` rollout line, SEPARATELY emitting the
TurnItem event (the event_msg). So upstream dual-writes BOTH lines.
PORT: ${SW}/Sources/Persistence/Rollout.swift:568-579 serializes \`.userInput\` as event_msg/user_message; 580-587
serializes \`.item(.agentMessage)\` as event_msg/agent_message; the response_item branch at 697-714 only reaches
\`.reasoning\` (the .agentMessage arm at ~709 is dead code, matched earlier at 580). SessionEngine persists user
input via \`.userInput\` (1812/1947) and assistant text via \`.item(.agentMessage)\` (1626,2145-2146,2392).
FIX: in Rollout.swift rustRolloutLine, ALSO emit a RolloutItem::ResponseItem line (via threadItemToResponseItem) for
\`.userInput\` (role:user, input_text/input_image content) and for \`.item(.agentMessage)\` (role:assistant,
output_text), IN ADDITION TO the event_msg sidecar — matching upstream persist_rollout_response_items + event dual
write. Remove the dead .agentMessage arm once the primary path emits it. CRITICAL: ensure the Swift READER does not
double-count when both a response_item and its event_msg sidecar are present — prefer response_item for history,
treat event_msg as UI-only. Port/extend persistence tests (assert a Swift rollout now contains response_item lines
for user + assistant text, and that round-trip reconstruction is not double-counted).`,
  },
  {
    key: 'config-profiles',
    title: 'Config: surface [profiles] in config/read + stop folding profile overlay into base layer',
    detail: `BUG: upstream surfaces the user's [profiles] map in config/read.config.profiles and keeps the base config
un-overlaid; Swift always returns profiles:{} AND folds the active profile's keys into the top-level effective config
(so config.model reflects a profile override upstream would not show here).
UPSTREAM: base user config layer is loaded RAW — load_user_config_layer (config/src/loader/mod.rs:386-414) for the
BASE layer is called with profile=None and does NOT strip [profiles] nor apply any inline [profiles.<name>] overlay;
effective_config() (state.rs:455-464) merges layers retaining [profiles]; profile resolution is separate.
PORT: ${SW}/Sources/Config/Config.swift:825 \`values["profiles"] = nil\` removes the profiles table from the user
layer; 826-832 merge the selected inline profile's keys INTO the top-level values; configProjectionJSON (Config.swift:307)
therefore always falls back to profiles={}.
FIX: in Config.swift load(): KEEP the [profiles] table in the user layer (do not nil it), and do NOT merge the inline
[profiles.<name>] overlay into the base user-layer values for the config-layer/effective view. Apply the profile
overlay ONLY at thread/session resolution (separate effective_config() from profile resolution, matching upstream).
config/read.config.profiles must now reflect the user's [profiles] map. Add/adjust ConfigTests to assert profiles is
surfaced and the base config is not profile-overlaid in the projection, while session-time resolution still applies
the profile. Watch for regressions in existing profile-resolution tests.`,
  },
  {
    key: 'auth-nested-plan-type',
    title: 'Auth: read ChatGPT plan_type from nested JWT claim https://api.openai.com/auth.chatgpt_plan_type',
    detail: `BUG: real OpenAI ChatGPT id_tokens carry the plan type at NESTED path \`https://api.openai.com/auth\` ->
\`chatgpt_plan_type\`, not a flat top-level key. Swift reads only flat keys, so planType resolves to nil for genuine
tokens — breaking account/read (throws instead of defaulting to unknown) and account/updated (planType emitted null).
UPSTREAM: reads chatgpt_plan_type ONLY from the nested \`https://api.openai.com/auth\` claim object (AuthClaims /
parse_chatgpt_jwt_claims / account_plan_type derivation; unit tests place the plan exclusively under the nested key),
then applies PlanType::from_raw_value normalization.
PORT: ${SW}/Sources/Supervisor/RequestRouter.swift:3827-3829 (tokenClaims) reads flat
\`https://api.openai.com/plan_type\` ?? \`plan_type\` ?? \`planType\`; RequestRouter.swift:1300-1302/1340-1342
(jwtStringClaim) flat keys; OAuthPKCE.swift:347-348 same. None descend into the nested auth object.
FIX: in RequestRouter.swift tokenClaims/jwtStringClaim and OAuthPKCE.swift JWTClaims.decode, parse the nested object:
read \`object["https://api.openai.com/auth"] as? [String:Any]\` then \`["chatgpt_plan_type"]\`, applying
PlanType.from_raw_value-style normalization. Keep a fallback to the legacy flat keys for resilience. Also ensure the
related account/read path defaults to "unknown" rather than throwing when the claim is absent. Add an auth test with a
realistic nested-claim id_token asserting planType resolves (and account/updated emits it).`,
  },
]

phase('Implement')
const impls = []
for (const f of FEATURES) {
  log(`implement: ${f.title}`)
  const r = await agent(`Implement ONE critical fix faithfully (cwd = port root).
Feature: ${f.title}
${f.detail}
${COMMON}
Add focused tests. Ensure \`swift build\` is green + run the targeted suites. Return the structured result.`,
    { label: `impl:${f.key}`, phase: 'Implement', schema: IMPL_SCHEMA })
  impls.push(r)
  log(`done: ${f.key} — build ${r && r.buildGreen ? 'GREEN' : 'NOT GREEN'}`)
}

phase('Review')
const reviews = await parallel(FEATURES.map((f, i) => () =>
  agent(`Opus 4.8 adversarial fidelity REVIEWER. Verify this critical fix is faithful to upstream codex-rs and the
build is green. Verify the ACTUAL port code (don't trust the report); for rollout, confirm a Swift-written rollout now
contains response_item lines for user+assistant text AND the reader doesn't double-count; for config, confirm profiles
is surfaced and the base layer isn't profile-overlaid while session resolution still applies the profile; for auth,
confirm the nested claim path is parsed. Run targeted tests. FAIL on any divergence or non-green build.
Feature: ${f.title}
${f.detail}
${COMMON}
Implementation report: ${JSON.stringify(impls[i])}
Return verdict + issues.`,
    { label: `review:${f.key}`, phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' })
)).then(rs => rs.filter(Boolean))

phase('Gate')
const gate = await agent(`Gate (cwd = ${SW}). \`swift build -c release\` (confirm), then run the directly-affected
targets in filtered batches (each <3min): PersistenceTests, ConfigTests, AuthTests, HarnessCoreTests, ProtocolModelTests,
IntegrationTests. Do NOT run LiveTests or the full unfiltered suite. Report build status + totals + any failing test
names, classifying each as pre-existing/known-flaky or REGRESSION (new). Known flaky: testRulesStoreReadLockedBlocksUntilWriterCompletes,
testConcurrencyNoLeaks, testRemoteControlWebSocketReassembles...`,
  { label: 'gate', phase: 'Gate' })

return { impls, reviews, reviewSummary: reviews.map(r => `${r.feature}: ${r.verdict}`), gate }
