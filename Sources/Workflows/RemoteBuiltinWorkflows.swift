import Foundation

// AUTO-PORTED from Claude Code's built-in workflow scripts (autopilot/bugfix/
// dashboard/docs), GPT-translated. Bodies are faithful to the originals; the
// PR phases use the agent's shell/git/`gh` tools and self-degrade when a
// github tool is unavailable. Registered only when CODEX_WORKFLOWS_REMOTE is
// truthy. See docs/workflows/IMPLEMENTATION_NOTES.md.

public enum RemoteBuiltinWorkflows {
    public static let autopilot = ##"""
export const meta = {"name": "autopilot", "description": "An end-to-end task runner. Builds a plan with a 5-angle adversarial critique, adjusts the plan, implements, uses a bughunt-lite review + feature completeness check, fixes issues, then opens a PR.", "whenToUse": "When the user gives a self-contained coding task they want completed end-to-end without supervision. Best for long-running tasks that require some or large amounts of planning and verification. This workflow scopes the problem, hardens its plan using 5 critics, implements it, runs a bug hunting sweep and a feature completeness check, fixes issues, and then opens a PR.", "phases": [{"title": "Plan", "detail": "Scope + draft, 5 critics (scope/simplicity/reuse/verification/correctness), harden"}, {"title": "Implement", "detail": "Single agent executes the hardened plan"}, {"title": "Review", "detail": "3 rapid + 2 deep finders, 5-vote pigeonhole verify, + completeness vs task"}, {"title": "Fix", "detail": "Address confirmed issues (skipped if clean)"}, {"title": "PR", "detail": "Lint, typecheck, open PR, subscribe to auto-fix"}]};

const TASK = (typeof args === 'string' && args.trim()) ? args.trim() : ''
if (!TASK) return { error: 'No task provided. Pass the task description as args.' }

// \u2550\u2550\u2550 Schemas \u2550\u2550\u2550
const PLAN_SCHEMA = {
  type: 'object', required: ['summary', 'files', 'steps', 'risks'],
  properties: {
    summary: { type: 'string' },
    files: { type: 'array', items: { type: 'string' } },
    steps: { type: 'array', items: { type: 'string' } },
    risks: { type: 'array', items: { type: 'string' } },
    reuse: { type: 'array', items: { type: 'string' }, description: 'Existing utilities/functions to reuse (file:line)' },
    verification: { type: 'string' },
  },
}
const CRITIQUE_SCHEMA = {
  type: 'object', required: ['verdict', 'holes'],
  properties: {
    verdict: { enum: ['PASS', 'REVISE'] },
    holes: { type: 'array', items: {
      type: 'object', required: ['issue', 'severity'],
      properties: {
        issue: { type: 'string' },
        severity: { enum: ['blocker', 'major', 'minor'] },
        suggestion: { type: 'string' },
      },
    }},
  },
}
const IMPL_SCHEMA = {
  type: 'object', required: ['done', 'filesChanged', 'notes'],
  properties: {
    done: { type: 'boolean' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
}
const BUGS_SCHEMA = {
  type: 'object', required: ['bugs'],
  properties: {
    bugs: { type: 'array', items: {
      type: 'object', required: ['file', 'title', 'description', 'severity'],
      properties: {
        file: { type: 'string' }, line: { type: 'number' },
        title: { type: 'string' }, description: { type: 'string' },
        severity: { enum: ['critical', 'high', 'medium', 'low', 'nit'] },
      },
    }},
  },
}
const VERDICT_SCHEMA = {
  type: 'object', required: ['refuted', 'evidence'],
  properties: { refuted: { type: 'boolean' }, evidence: { type: 'string' } },
}
const COMPLETENESS_SCHEMA = {
  type: 'object', required: ['covered', 'gaps'],
  properties: {
    covered: { type: 'boolean' },
    gaps: { type: 'array', items: {
      type: 'object', required: ['what', 'where'],
      properties: { what: { type: 'string' }, where: { type: 'string' } },
    }},
  },
}
const PR_SCHEMA = {
  type: 'object', required: ['prUrl', 'branch', 'summary'],
  properties: {
    prUrl: { type: 'string' }, branch: { type: 'string' },
    summary: { type: 'string', description: '2-3 sentence summary of what changed and why' },
    lintPassed: { type: 'boolean' }, typecheckPassed: { type: 'boolean' },
    autoFixSubscribed: { type: 'boolean' },
    notes: { type: 'string' },
  },
}

// \u2550\u2550\u2550 Phase 1: Plan \u2550\u2550\u2550
phase('Plan')

const draft = await agent(
  "Scope this task against the codebase and draft an implementation plan.\n\n" +
  "## Task\n" + TASK + "\n\n" +
  "## Instructions\n" +
  "1. Explore \u2014 find relevant files, existing patterns, utilities to reuse. " +
  "Actively search for existing functions and utilities that can be reused; " +
  "avoid proposing new code when suitable implementations already exist.\n" +
  "2. Read CLAUDE.md at project root and in parent dirs of relevant files.\n" +
  "3. Draft a concrete plan: files to touch, what edits, in what order.\n" +
  "4. Call out existing code to reuse with file:line.\n" +
  "5. List risks and describe verification (test command, manual check).\n\n" +
  "Be concrete \u2014 file paths and function names, not vague intentions.",
  { label: 'plan:draft', schema: PLAN_SCHEMA }
)
if (!draft) return { error: 'Plan draft skipped.' }
log('Draft: ' + draft.files.length + ' files, ' + draft.steps.length + ' steps')

const PLAN_BLOCK =
  "## Task\n" + TASK + "\n\n" +
  "## Proposed plan\n" + draft.summary + "\n\n" +
  "**Files:** " + draft.files.join(', ') + "\n\n" +
  "**Steps:**\n" + draft.steps.map((s, i) => (i + 1) + ". " + s).join("\n") + "\n\n" +
  "**Reuse:** " + (draft.reuse && draft.reuse.length ? draft.reuse.join('; ') : '(none listed)') + "\n\n" +
  "**Risks:** " + (draft.risks.length ? draft.risks.join('; ') : '(none)') + "\n\n" +
  "**Verification:** " + (draft.verification || '(not specified)') + "\n"

// Angle menu from autoPlan (cli#23382) plus a correctness angle.
// Consistency folded into reuse; security/performance/blast-radius left for
// a future conditional pass.
const CRITICS = [
  { key: 'scope', lens: 'Is the plan over- or under-scoped vs the ask? Does it do more than needed, or miss part of the request? Is this a spot fix where the underlying problem should be addressed more broadly, or the right-sized change?' },
  { key: 'simplicity', lens: 'Could this be simpler? Unnecessary abstractions, files that do not need touching, steps that could merge. What is the minimal diff?' },
  { key: 'reuse', lens: 'Does it call out existing code to reuse with file paths? Grep for similar utilities \u2014 is it reinventing something that exists? Does the approach match how neighboring code does similar things?' },
  { key: 'verification', lens: 'Are the test/verify steps concrete enough to catch a regression? Is there a runnable command, or is it hand-wavy?' },
  { key: 'correctness', lens: 'Will this plan actually solve the stated problem? Trace the logic \u2014 does the proposed change address the root cause? Grep for other code paths with the same pattern \u2014 are there sibling call sites that need the same fix?' },
]

const critiques = await parallel(CRITICS.map(c => () =>
  agent(
    PLAN_BLOCK + "\n## Your angle: " + c.key + "\n" + c.lens + "\n\n" +
    "## Instructions\n" +
    "Review this plan from the " + c.key + " angle ONLY. Other reviewers cover the rest.\n" +
    "Read the actual files it references. Verify claims against the codebase.\n" +
    "Verdict PASS if the plan is good enough to proceed from your angle.\n" +
    "Verdict REVISE with concrete holes otherwise \u2014 'step 3 will not work because X', not 'might have issues'.\n" +
    "Severity: blocker = plan will fail; major = works but poorly; minor = nit.",
    { label: 'plan:critic-' + c.key, phase: 'Plan', schema: CRITIQUE_SCHEMA }
  )
))

const holes = critiques.flatMap((c, i) =>
  c ? c.holes.map(h => ({ ...h, critic: CRITICS[i].key })) : []
)
const needsRevise = critiques.filter(Boolean).some(c => c.verdict === 'REVISE')
log(holes.length + ' holes (' + holes.filter(h => h.severity === 'blocker').length + ' blockers), ' +
  (needsRevise ? 'REVISE' : 'PASS'))

const plan = !needsRevise ? draft : await agent(
  PLAN_BLOCK + "\n## Critique (" + holes.length + " holes from " + CRITICS.length + " critics)\n" +
  holes.map(h => "- [" + h.severity + ", " + h.critic + "] " + h.issue +
    (h.suggestion ? " \u2192 " + h.suggestion : "")).join("\n") + "\n\n" +
  "## Instructions\n" +
  "Revise the plan. Blockers MUST be resolved. Majors addressed or explicitly acknowledged as tradeoffs. " +
  "Minors optional. Output the revised plan in the same schema.",
  { label: 'plan:harden', phase: 'Plan', schema: PLAN_SCHEMA }
)
if (!plan) return { error: 'Plan hardening skipped.', draft, holes }

// \u2550\u2550\u2550 Phase 2: Implement \u2550\u2550\u2550
phase('Implement')

const HARDENED_BLOCK =
  "## Task\n" + TASK + "\n\n" +
  "## Plan\n" + plan.summary + "\n\n" +
  "**Files:** " + plan.files.join(', ') + "\n\n" +
  "**Steps:**\n" + plan.steps.map((s, i) => (i + 1) + ". " + s).join("\n") + "\n\n" +
  "**Reuse:** " + (plan.reuse && plan.reuse.length ? plan.reuse.join('; ') : '(none)') + "\n\n" +
  "**Risks:** " + (plan.risks.length ? plan.risks.join('; ') : '(none)') + "\n\n" +
  "**Verification:** " + (plan.verification || '(not specified)') + "\n"

const impl = await agent(
  HARDENED_BLOCK + "\n## Instructions\n" +
  "Execute this plan. Make the edits. Run the verification step.\n" +
  "Adapt if you hit something the plan missed \u2014 but note it.\n" +
  "Return done=false with blockers if you cannot proceed.",
  { label: 'implement', schema: IMPL_SCHEMA }
)
if (!impl || !impl.done) {
  return { error: 'Implementation incomplete.', plan, blockers: impl ? impl.blockers : ['skipped'] }
}
log('Implemented: ' + impl.filesChanged.length + ' files changed')

// \u2550\u2550\u2550 Phase 3: Review (bughunt-lite + completeness) \u2550\u2550\u2550
phase('Review')

const VOTES = 5
const REFUTE_KILL = 2
const MAX_VERIFY = 20
const sevRank = { critical: 0, high: 1, medium: 2, low: 3, nit: 4 }
const dedupKey = b => b.file + ':' + (b.line != null ? Math.round(b.line / 5) * 5 : 'x')

const DIFF_INSTR = "Run 'git diff $(git merge-base HEAD origin/main)' to see all changes (committed + uncommitted). If origin/main doesn't exist, try 'main' or 'origin/HEAD'."

const RAPID = i =>
  "## Rapid scanner " + (i + 1) + "/3\n" + DIFF_INSTR + "\n\n" +
  "Quick surface scan. Report 5-10 obvious issues: logic errors, null derefs, " +
  "CLAUDE.md violations, missing awaits. Breadth over depth. " +
  "Bias toward the " + ['first', 'middle', 'last'][i] + " third of the diff.\nStructured output only."

const DEEP = i =>
  "## Deep analyst " + (i + 1) + "/2\n" + DIFF_INSTR + "\n\n" +
  "Find subtle issues. Read full files, grep callers, trace data flow. " +
  "Invariant violations, races, edge cases (empty/null/concurrent). " +
  "Pick " + (i === 0 ? 'the most significant change' : 'a DIFFERENT area') + ". 1-3 findings.\nStructured output only."

const VERIFY = (b, v) =>
  "## Adversarial verifier " + (v + 1) + "/" + VOTES + "\n" +
  "Be SKEPTICAL. Try to REFUTE. \u2265" + REFUTE_KILL + " refutes kill it.\n\n" +
  "**Candidate:** " + b.file + (b.line != null ? ":" + b.line : "") + " \u2014 " + b.title + "\n" + b.description + "\n\n" +
  DIFF_INSTR + " Read the file. Check callers, error handling, conventions.\n" +
  "refuted=true if: unreachable, handled, intentional, pre-existing, wrong.\n" +
  "refuted=false ONLY if real, new, material. Default refuted=true when uncertain.\n" +
  "Evidence must cite file:line."

const seen = new Map()
let slots = MAX_VERIFY

function verifyBug(b) {
  const short = b.file.split('/').pop()
  const vote = v => () => agent(VERIFY(b, v), { label: 'v' + v + ':' + short, phase: 'Review', schema: VERDICT_SCHEMA })
  return parallel([0, 1].map(vote)).then(first2 => {
    const r2 = first2.filter(Boolean).filter(v => v.refuted).length
    if (r2 >= REFUTE_KILL) return { ...b, votes: first2, refuted: r2, survives: false }
    return parallel([2, 3, 4].map(vote)).then(rest => {
      const all = first2.concat(rest).filter(Boolean)
      const r = all.filter(v => v.refuted).length
      return { ...b, votes: all, refuted: r, survives: r < REFUTE_KILL }
    })
  })
}

const FINDERS = [
  { kind: 'rapid', i: 0 }, { kind: 'rapid', i: 1 }, { kind: 'rapid', i: 2 },
  { kind: 'deep', i: 0 }, { kind: 'deep', i: 1 },
]

// Completeness check runs in parallel with the bughunt pipeline \u2014 it's
// independent of diff-local findings.
const [bugResults, completeness] = await Promise.all([
  pipeline(
    FINDERS,
    f => agent(f.kind === 'rapid' ? RAPID(f.i) : DEEP(f.i),
      { label: f.kind + '-' + f.i, phase: 'Review', schema: BUGS_SCHEMA }),
    r => {
      if (!r) return []
      const sorted = r.bugs.slice().sort((a, b) => sevRank[a.severity] - sevRank[b.severity])
      const novel = sorted.filter(b => {
        const k = dedupKey(b)
        if (seen.has(k)) return false
        if (slots <= 0 && sevRank[b.severity] >= 2) return false
        seen.set(k, true); slots--; return true
      })
      return parallel(novel.map(b => () => verifyBug(b)))
    }
  ),
  agent(
    "## Completeness check\n\n" +
    "## Original task\n" + TASK + "\n\n" +
    "## Plan that was executed\n" + plan.summary + "\n" +
    "Files planned: " + plan.files.join(', ') + "\n\n" +
    "## Instructions\n" + DIFF_INSTR + "\n" +
    "Compare the diff against the task. Did the implementation cover everything?\n" +
    "Look for: callers that should have been updated, tests that should exist, " +
    "docs/types that should have changed, parts of the ask that were missed.\n" +
    "covered=true if the task is fully addressed. Otherwise list concrete gaps with file paths.",
    { label: 'review:completeness', phase: 'Review', schema: COMPLETENESS_SCHEMA }
  ),
])

const voted = bugResults.flat().filter(Boolean)
const confirmed = voted.filter(b => b.survives)
const gaps = completeness && !completeness.covered ? completeness.gaps : []
log('Review: ' + voted.length + ' voted \u2192 ' + confirmed.length + ' confirmed, ' + gaps.length + ' completeness gaps')

// \u2550\u2550\u2550 Phase 4: Fix \u2550\u2550\u2550
let fixNotes = '(clean \u2014 no fixes needed)'
if (confirmed.length > 0 || gaps.length > 0) {
  phase('Fix')
  const bugBlock = confirmed.map((b, i) => (i + 1) + ". [" + b.severity + "] " + b.file +
    (b.line != null ? ":" + b.line : "") + " \u2014 " + b.title + "\n   " + b.description).join("\n")
  const gapBlock = gaps.map((g, i) => (i + 1) + ". " + g.what + " (at " + g.where + ")").join("\n")
  const fixResult = await agent(
    "Address confirmed review findings.\n\n" +
    (confirmed.length ? "## Bugs (" + confirmed.length + ", survived adversarial verify)\n" + bugBlock + "\n\n" : "") +
    (gaps.length ? "## Completeness gaps (" + gaps.length + ")\n" + gapBlock + "\n\n" : "") +
    "## Instructions\n" +
    "Fix each item. If one turns out to be a false positive, note why and skip. " +
    "Summarize what you changed.",
    { label: 'fix', schema: IMPL_SCHEMA }
  )
  fixNotes = !fixResult ? '(fix skipped)'
    : !fixResult.done ? 'INCOMPLETE \u2014 ' + (fixResult.blockers || []).join('; ') + '. ' + fixResult.notes
    : fixResult.notes
}

// \u2550\u2550\u2550 Phase 5: PR \u2550\u2550\u2550
phase('PR')

const pr = await agent(
  "Finalize and open a PR.\n\n" +
  "## Task\n" + TASK + "\n\n## What was done\n" + plan.summary + "\n\n" +
  "## Instructions\n" +
  "1. Run lint and typecheck. Fix any failures.\n" +
  "2. If on main, create a kebab-case branch from the task.\n" +
  "3. Commit with a clear message. Push. Open a PR (use template if present). Assign reviewers based on CODEOWNERS or recent git blame against the base branch for the touched files.\n" +
  "4. After the PR is created, enable auto-fix by calling the " +
  "mcp__github__subscribe_pr_activity tool with {owner, repo, pullNumber} " +
  "parsed from the PR URL. This subscribes the session to CI failures and " +
  "review comments so they can be addressed automatically. Set " +
  "autoFixSubscribed=true if the call succeeds. If that tool is not " +
  "available in this environment, skip this step and set autoFixSubscribed=false.\n" +
  "5. Return the PR URL, branch name, autoFixSubscribed, and a 2-3 sentence summary of what changed and why.",
  { label: 'pr', schema: PR_SCHEMA }
)

return {
  summary: pr ? pr.summary : 'PR step incomplete. ' + (impl.notes || plan.summary),
  prUrl: pr ? pr.prUrl : null,
  branch: pr ? pr.branch : null,
  autoFixSubscribed: pr ? (pr.autoFixSubscribed ?? null) : null,
  plan: { summary: plan.summary, files: plan.files },
  critique: { holes: holes.length, blockers: holes.filter(h => h.severity === 'blocker').length },
  review: { voted: voted.length, confirmed: confirmed.length, gaps: gaps.length },
  fixNotes,
}
"""##

    public static let bugfix = ##"""
export const meta = {"name": "bugfix", "description": "Reproduce-first bug fixer. Writes a failing repro, root-causes the fault, applies the minimal fix, converts the repro into a regression test, then opens a PR.", "whenToUse": "When the user reports a specific bug to fix. Best when the bug is concrete enough to reproduce. This workflow writes a failing repro first, traces the root cause, applies the smallest fix that makes the repro pass, locks it in as a regression test, and opens a PR.", "phases": [{"title": "Reproduce", "detail": "Write a failing script or test that demonstrates the bug"}, {"title": "Root-cause", "detail": "Trace the fault, grep callers, identify the minimal culprit"}, {"title": "Fix", "detail": "Smallest diff that makes the repro pass"}, {"title": "Regress", "detail": "Convert repro into a permanent test, run the touched suite"}, {"title": "PR", "detail": "Lint, typecheck, open PR"}]};

const TASK = (typeof args === 'string' && args.trim()) ? args.trim() : ''
if (!TASK) return { error: 'No bug description provided. Pass the bug report as args.' }

// \u2550\u2550\u2550 Schemas \u2550\u2550\u2550
const REPRO_SCHEMA = {
  type: 'object', required: ['reproduced', 'reproPath', 'expected', 'actual', 'notes'],
  properties: {
    reproduced: { type: 'boolean' },
    reproPath: { type: 'string', description: 'Path to the failing test or repro script' },
    reproCommand: { type: 'string', description: 'Command that runs the repro and fails' },
    expected: { type: 'string' },
    actual: { type: 'string' },
    notes: { type: 'string' },
  },
}
const ROOT_CAUSE_SCHEMA = {
  type: 'object', required: ['rootCause', 'culprit', 'callers'],
  properties: {
    rootCause: { type: 'string' },
    culprit: { type: 'string', description: 'file:line of the minimal fault' },
    callers: { type: 'array', items: { type: 'string' } },
    fixApproach: { type: 'string' },
  },
}
const IMPL_SCHEMA = {
  type: 'object', required: ['done', 'filesChanged', 'notes'],
  properties: {
    done: { type: 'boolean' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
}
const REGRESS_SCHEMA = {
  type: 'object', required: ['testPath', 'testPassed', 'suitePassed', 'notes'],
  properties: {
    testPath: { type: 'string' },
    testPassed: { type: 'boolean' },
    suitePassed: { type: 'boolean' },
    notes: { type: 'string' },
  },
}
const PR_SCHEMA = {
  type: 'object', required: ['prUrl', 'branch', 'summary'],
  properties: {
    prUrl: { type: 'string' }, branch: { type: 'string' },
    summary: { type: 'string' },
    lintPassed: { type: 'boolean' }, typecheckPassed: { type: 'boolean' },
    notes: { type: 'string' },
  },
}

// \u2550\u2550\u2550 Phase 1: Reproduce \u2550\u2550\u2550
phase('Reproduce')

const repro = await agent(
  "Reproduce this bug with a failing test or script.\n\n" +
  "## Bug report\n" + TASK + "\n\n" +
  "## Instructions\n" +
  "1. Read the relevant code and any linked traces/logs to understand the claimed behavior.\n" +
  "2. Write the SMALLEST failing test or standalone script that demonstrates the bug. " +
  "Prefer a test in the existing test framework; fall back to a script if no framework fits.\n" +
  "3. Run it. Confirm it FAILS with the expected vs actual mismatch.\n" +
  "4. If you cannot reproduce after a genuine attempt, set reproduced=false and explain why in notes.\n\n" +
  "Do NOT fix the bug yet \u2014 only reproduce it.",
  { label: 'reproduce', schema: REPRO_SCHEMA }
)
if (!repro) return { error: 'Reproduce step skipped.' }
if (!repro.reproduced) {
  return {
    summary: 'Could not reproduce the bug. ' + repro.notes,
    reproduced: false,
    repro,
  }
}
log('Reproduced: ' + repro.reproPath + ' (expected ' + repro.expected + ', got ' + repro.actual + ')')

const REPRO_BLOCK =
  "## Bug report\n" + TASK + "\n\n" +
  "## Repro\n" +
  "Path: " + repro.reproPath + "\n" +
  (repro.reproCommand ? "Command: " + repro.reproCommand + "\n" : "") +
  "Expected: " + repro.expected + "\n" +
  "Actual: " + repro.actual + "\n" +
  "Notes: " + repro.notes + "\n"

// \u2550\u2550\u2550 Phase 2: Root-cause \u2550\u2550\u2550
phase('Root-cause')

const rc = await agent(
  REPRO_BLOCK + "\n## Instructions\n" +
  "Find the ROOT cause \u2014 not the first place the symptom appears.\n" +
  "1. Trace backwards from the failure point. Read the code paths the repro exercises.\n" +
  "2. Grep for callers and sibling code paths that touch the same state \u2014 note any that share the fault.\n" +
  "3. Identify the minimal culprit (file:line). Distinguish the root cause from downstream symptoms.\n" +
  "4. Propose the smallest fix approach that addresses the root cause, not a patch over the symptom.",
  { label: 'root-cause', schema: ROOT_CAUSE_SCHEMA }
)
if (!rc) return { error: 'Root-cause step skipped.', repro }
log('Root cause: ' + rc.culprit + ' \u2014 ' + rc.rootCause)

// \u2550\u2550\u2550 Phase 3: Fix \u2550\u2550\u2550
phase('Fix')

const fix = await agent(
  REPRO_BLOCK + "\n## Root cause\n" + rc.rootCause + "\n" +
  "Culprit: " + rc.culprit + "\n" +
  "Callers sharing the fault: " + (rc.callers.length ? rc.callers.join(', ') : '(none)') + "\n" +
  "Approach: " + (rc.fixApproach || '(not specified)') + "\n\n" +
  "## Instructions\n" +
  "Apply the minimal fix at the root cause. Update sibling callers if they share the fault.\n" +
  "Re-run the repro" + (repro.reproCommand ? " (" + repro.reproCommand + ")" : "") + " \u2014 it MUST now pass.\n" +
  "Return done=false with blockers if the repro still fails after your fix.",
  { label: 'fix', schema: IMPL_SCHEMA }
)
if (!fix || !fix.done) {
  return { error: 'Fix incomplete.', repro, rootCause: rc, blockers: fix ? fix.blockers : ['skipped'] }
}
log('Fixed: ' + fix.filesChanged.length + ' files changed')

// \u2550\u2550\u2550 Phase 4: Regress \u2550\u2550\u2550
phase('Regress')

const regress = await agent(
  REPRO_BLOCK + "\n## Fix applied\n" + fix.notes + "\n" +
  "Files changed: " + fix.filesChanged.join(', ') + "\n\n" +
  "## Instructions\n" +
  "1. Convert the repro at " + repro.reproPath + " into a permanent regression test in the " +
  "right location for this codebase. If it is already a proper test, tighten the assertion " +
  "and naming so it clearly describes the bug it guards against.\n" +
  "2. Run the regression test \u2014 it must PASS.\n" +
  "3. Run the full test suite for the touched module(s) \u2014 flag any new failures.\n" +
  "Return testPassed and suitePassed honestly.",
  { label: 'regress', schema: REGRESS_SCHEMA }
)
if (!regress) return { error: 'Regression step skipped.', repro, rootCause: rc, fix }
log('Regression test: ' + regress.testPath + ' (test ' + (regress.testPassed ? 'PASS' : 'FAIL') +
  ', suite ' + (regress.suitePassed ? 'PASS' : 'FAIL') + ')')

// \u2550\u2550\u2550 Phase 5: PR \u2550\u2550\u2550
phase('PR')

const pr = await agent(
  "Finalize and open a PR for this bug fix.\n\n" +
  "## Bug\n" + TASK + "\n\n" +
  "## Root cause\n" + rc.rootCause + " (at " + rc.culprit + ")\n\n" +
  "## Regression test\n" + regress.testPath +
  (regress.suitePassed ? "" : "\n\nNOTE: suite had failures \u2014 investigate before merging: " + regress.notes) + "\n\n" +
  "## Instructions\n" +
  "1. Run lint and typecheck. Fix any failures.\n" +
  "2. If on main, create a kebab-case branch from the bug.\n" +
  "3. Commit with a clear message referencing the symptom and root cause. Push. Open a PR. " +
  "Include the repro steps and regression test path in the PR body.\n" +
  "4. Return the PR URL, branch, and a 2-3 sentence summary.",
  { label: 'pr', schema: PR_SCHEMA }
)

return {
  summary: pr ? pr.summary : 'PR step incomplete. Fix applied: ' + fix.notes,
  prUrl: pr ? pr.prUrl : null,
  branch: pr ? pr.branch : null,
  reproduced: true,
  rootCause: { summary: rc.rootCause, culprit: rc.culprit },
  regressionTest: regress.testPath,
  testPassed: regress.testPassed,
  suitePassed: regress.suitePassed,
}
"""##

    public static let dashboard = ##"""
export const meta = {"name": "dashboard", "description": "Dashboard generator. Discovers data sources and existing dashboard conventions in the repo, designs a panel layout, implements it, dry-runs queries and render-checks the result, then opens a PR.", "whenToUse": "When the user wants a dashboard, monitoring view, or metrics page built. This workflow finds the available data and existing dashboard patterns, specs out panels and layout, implements them, validates queries and rendering, and opens a PR.", "phases": [{"title": "Discover", "detail": "Data sources, existing dashboard libs/patterns in repo"}, {"title": "Design", "detail": "Panels, metrics, layout spec"}, {"title": "Implement", "detail": "Build the dashboard"}, {"title": "Verify", "detail": "Query dry-run, render/screenshot if possible"}, {"title": "PR", "detail": "Open PR"}]};

const TASK = (typeof args === 'string' && args.trim()) ? args.trim() : ''
if (!TASK) return { error: 'No dashboard description provided. Pass what to build as args.' }

const DISCOVER_SCHEMA = {
  type: 'object', required: ['dataSources', 'framework', 'examplePath', 'targetPath'],
  properties: {
    dataSources: { type: 'array', items: { type: 'string' }, description: 'Tables, metrics, APIs, or log streams available' },
    framework: { type: 'string', description: 'Dashboard system in use (Grafana JSON, Hex, React+charts lib, Streamlit, etc.)' },
    examplePath: { type: 'string', description: 'Path to an existing dashboard to pattern-match' },
    targetPath: { type: 'string' },
    conventions: { type: 'string' },
  },
}
const DESIGN_SCHEMA = {
  type: 'object', required: ['title', 'panels'],
  properties: {
    title: { type: 'string' },
    panels: { type: 'array', items: {
      type: 'object', required: ['name', 'metric', 'viz'],
      properties: {
        name: { type: 'string' },
        metric: { type: 'string', description: 'Query or metric expression' },
        viz: { type: 'string', description: 'timeseries, stat, table, bar, etc.' },
        why: { type: 'string' },
      },
    }},
    layout: { type: 'string' },
  },
}
const IMPL_SCHEMA = {
  type: 'object', required: ['done', 'filesChanged', 'notes'],
  properties: {
    done: { type: 'boolean' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
}
const VERIFY_SCHEMA = {
  type: 'object', required: ['queriesOk', 'rendered', 'issues'],
  properties: {
    queriesOk: { type: 'boolean' },
    rendered: { type: 'boolean' },
    screenshotPath: { type: 'string' },
    issues: { type: 'array', items: { type: 'string' } },
  },
}
const PR_SCHEMA = {
  type: 'object', required: ['prUrl', 'branch', 'summary'],
  properties: {
    prUrl: { type: 'string' }, branch: { type: 'string' },
    summary: { type: 'string' }, notes: { type: 'string' },
  },
}

// \u2550\u2550\u2550 Phase 1: Discover \u2550\u2550\u2550
phase('Discover')

const disc = await agent(
  "Discover the dashboard stack and available data for this request.\n\n" +
  "## Request\n" + TASK + "\n\n" +
  "## Instructions\n" +
  "1. Identify the dashboard framework this repo uses: Grafana-as-code, Hex, Datadog JSON, " +
  "Streamlit, a React page with a charting library, or similar. Grep for existing dashboards.\n" +
  "2. Find an existing dashboard file to pattern-match against (examplePath).\n" +
  "3. List concrete data sources relevant to the request: table names, metric names, API " +
  "endpoints, or log queries. Verify they exist where possible.\n" +
  "4. Decide where the new dashboard file(s) should live (targetPath) and note conventions.",
  { label: 'discover', schema: DISCOVER_SCHEMA }
)
if (!disc) return { error: 'Discover step skipped.' }
log('Framework: ' + disc.framework + ', ' + disc.dataSources.length + ' data sources, target: ' + disc.targetPath)

const CONTEXT =
  "## Request\n" + TASK + "\n\n" +
  "## Framework\n" + disc.framework + " (pattern: " + disc.examplePath + ")\n\n" +
  "## Data sources\n" + disc.dataSources.map(d => "- " + d).join("\n") + "\n\n" +
  "## Conventions\n" + (disc.conventions || '(none noted)') + "\n"

// \u2550\u2550\u2550 Phase 2: Design \u2550\u2550\u2550
phase('Design')

const design = await agent(
  CONTEXT + "\n## Instructions\n" +
  "Design the dashboard. For each panel specify: name, the exact metric/query expression, " +
  "visualization type, and a one-line reason it earns a spot.\n\n" +
  "Best practices:\n" +
  "- Top row = the headline numbers (what is the state right now). Below = breakdowns and trends.\n" +
  "- Prefer rates and percentiles over raw counts. Pair every latency panel with a volume panel.\n" +
  "- Every panel should answer a question someone would actually ask. Cut anything that does not.\n" +
  "- 6-12 panels is usually right. More than that and nothing gets looked at.\n" +
  "Describe layout as a brief grid spec.",
  { label: 'design', schema: DESIGN_SCHEMA }
)
if (!design) return { error: 'Design step skipped.', discover: disc }
log('Design: ' + design.panels.length + ' panels')

// \u2550\u2550\u2550 Phase 3: Implement \u2550\u2550\u2550
phase('Implement')

const impl = await agent(
  CONTEXT + "\n## Design\n" +
  "Title: " + design.title + "\n" +
  "Layout: " + (design.layout || '(default grid)') + "\n" +
  "Panels:\n" + design.panels.map((p, i) =>
    (i + 1) + ". " + p.name + " [" + p.viz + "] \u2014 " + p.metric).join("\n") + "\n\n" +
  "## Instructions\n" +
  "Implement the dashboard at " + disc.targetPath + " using " + disc.framework + ".\n" +
  "Match the structure of " + disc.examplePath + " exactly \u2014 same JSON schema, component " +
  "patterns, or DSL. Wire up each panel to its data source.\n" +
  "Register the dashboard in any index/nav file the framework requires.",
  { label: 'implement', schema: IMPL_SCHEMA }
)
if (!impl || !impl.done) {
  return { error: 'Implementation incomplete.', discover: disc, design, blockers: impl ? impl.blockers : ['skipped'] }
}
log('Implemented: ' + impl.filesChanged.length + ' files')

// \u2550\u2550\u2550 Phase 4: Verify \u2550\u2550\u2550
phase('Verify')

const verify = await agent(
  "Verify the dashboard.\n\n" +
  "Files: " + impl.filesChanged.join(', ') + "\n" +
  "Framework: " + disc.framework + "\n\n" +
  "## Instructions\n" +
  "1. Dry-run or validate every query/metric expression \u2014 confirm syntax and that the " +
  "referenced tables/metrics exist. Set queriesOk accordingly.\n" +
  "2. If the framework supports local rendering, render the dashboard and screenshot it. " +
  "Otherwise validate the file against its schema/linter. Set rendered accordingly.\n" +
  "3. List concrete issues (empty if clean).",
  { label: 'verify', schema: VERIFY_SCHEMA }
)
const issues = verify ? verify.issues : []
log('Verify: queries ' + (verify && verify.queriesOk ? 'OK' : 'FAIL') +
  ', rendered ' + (verify && verify.rendered ? 'yes' : 'no') + ', ' + issues.length + ' issues')

let fixNotes = '(clean)'
if (issues.length > 0) {
  const fixed = await agent(
    "Fix these dashboard issues:\n" + issues.map((i, n) => (n + 1) + ". " + i).join("\n") +
    "\n\nFiles: " + impl.filesChanged.join(', '),
    { label: 'verify:fix', phase: 'Verify', schema: IMPL_SCHEMA }
  )
  fixNotes = fixed ? fixed.notes : '(fix skipped)'
}

// \u2550\u2550\u2550 Phase 5: PR \u2550\u2550\u2550
phase('PR')

const pr = await agent(
  "Open a PR for this dashboard.\n\n" +
  "## Request\n" + TASK + "\n\n" +
  "Files: " + impl.filesChanged.join(', ') + "\n" +
  (verify && verify.screenshotPath ? "Screenshot: " + verify.screenshotPath + "\n" : "") + "\n" +
  "## Instructions\n" +
  "1. Run any repo lint/format on the dashboard files.\n" +
  "2. Commit, push, open a PR. Include the panel list and screenshot (if any) in the body.\n" +
  "3. Return PR URL, branch, and a 2-3 sentence summary.",
  { label: 'pr', schema: PR_SCHEMA }
)

return {
  summary: pr ? pr.summary : 'PR step incomplete. Dashboard at ' + disc.targetPath,
  prUrl: pr ? pr.prUrl : null,
  branch: pr ? pr.branch : null,
  framework: disc.framework,
  targetPath: disc.targetPath,
  panels: design.panels.map(p => p.name),
  filesChanged: impl.filesChanged,
  verify: verify ? { queriesOk: verify.queriesOk, rendered: verify.rendered, screenshot: verify.screenshotPath || null } : null,
  fixNotes,
}
"""##

    public static let docs = ##"""
export const meta = {"name": "docs", "description": "Documentation generator. Discovers the feature surface and existing doc conventions, outlines for the target audience, writes or updates the docs, verifies code examples and links, then opens a PR.", "whenToUse": "When the user wants documentation written or updated for a feature, API, or module. This workflow finds the relevant code and existing doc patterns, drafts an outline, writes the content, checks that examples run and links resolve, and opens a PR.", "phases": [{"title": "Discover", "detail": "Feature surface, existing docs, location conventions"}, {"title": "Outline", "detail": "Structure and audience"}, {"title": "Write", "detail": "Create or update doc files"}, {"title": "Verify", "detail": "Examples compile/run, links resolve, accuracy vs code"}, {"title": "PR", "detail": "Open PR"}]};

const TASK = (typeof args === 'string' && args.trim()) ? args.trim() : ''
if (!TASK) return { error: 'No subject provided. Pass what to document as args.' }

const DISCOVER_SCHEMA = {
  type: 'object', required: ['surface', 'existingDocs', 'targetPath', 'audience', 'conventions'],
  properties: {
    surface: { type: 'array', items: { type: 'string' }, description: 'file:symbol entries that make up the public surface' },
    existingDocs: { type: 'array', items: { type: 'string' } },
    targetPath: { type: 'string', description: 'Where the new/updated doc should live' },
    audience: { type: 'string' },
    conventions: { type: 'string', description: 'Tone, format, and structure conventions from sibling docs' },
  },
}
const OUTLINE_SCHEMA = {
  type: 'object', required: ['title', 'sections'],
  properties: {
    title: { type: 'string' },
    sections: { type: 'array', items: {
      type: 'object', required: ['heading', 'covers'],
      properties: { heading: { type: 'string' }, covers: { type: 'string' } },
    }},
  },
}
const IMPL_SCHEMA = {
  type: 'object', required: ['done', 'filesChanged', 'notes'],
  properties: {
    done: { type: 'boolean' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
    blockers: { type: 'array', items: { type: 'string' } },
  },
}
const VERIFY_SCHEMA = {
  type: 'object', required: ['examplesOk', 'linksOk', 'accurate', 'issues'],
  properties: {
    examplesOk: { type: 'boolean' },
    linksOk: { type: 'boolean' },
    accurate: { type: 'boolean' },
    issues: { type: 'array', items: { type: 'string' } },
  },
}
const PR_SCHEMA = {
  type: 'object', required: ['prUrl', 'branch', 'summary'],
  properties: {
    prUrl: { type: 'string' }, branch: { type: 'string' },
    summary: { type: 'string' }, notes: { type: 'string' },
  },
}

// \u2550\u2550\u2550 Phase 1: Discover \u2550\u2550\u2550
phase('Discover')

const disc = await agent(
  "Discover what needs documenting and where it should live.\n\n" +
  "## Subject\n" + TASK + "\n\n" +
  "## Instructions\n" +
  "1. Grep/read the code to map the public surface: exported functions, types, CLI flags, " +
  "config keys \u2014 whatever a user of this feature touches. List as file:symbol.\n" +
  "2. Find existing docs for this or adjacent features (README, docs/, CLAUDE.md, mdx). " +
  "Note their location, format, and tone.\n" +
  "3. Decide the target path: update an existing doc if one covers this area, otherwise " +
  "pick a path that matches the existing doc layout.\n" +
  "4. Identify the audience (end user, API consumer, contributor) and the conventions to follow.",
  { label: 'discover', schema: DISCOVER_SCHEMA }
)
if (!disc) return { error: 'Discover step skipped.' }
log('Surface: ' + disc.surface.length + ' items, target: ' + disc.targetPath + ' (' + disc.audience + ')')

const CONTEXT =
  "## Subject\n" + TASK + "\n\n" +
  "## Surface\n" + disc.surface.map(s => "- " + s).join("\n") + "\n\n" +
  "## Target\n" + disc.targetPath + " (audience: " + disc.audience + ")\n\n" +
  "## Conventions\n" + disc.conventions + "\n"

// \u2550\u2550\u2550 Phase 2: Outline \u2550\u2550\u2550
phase('Outline')

const outline = await agent(
  CONTEXT + "\n## Instructions\n" +
  "Draft a section outline for " + disc.targetPath + ".\n" +
  "Match the structure of sibling docs. Cover: what it is, when to use it, how to use it " +
  "(with at least one runnable example), key options/API, and gotchas. Keep it lean \u2014 " +
  "no section that does not earn its place.",
  { label: 'outline', schema: OUTLINE_SCHEMA }
)
if (!outline) return { error: 'Outline step skipped.', discover: disc }
log('Outline: ' + outline.sections.length + ' sections')

// \u2550\u2550\u2550 Phase 3: Write \u2550\u2550\u2550
phase('Write')

const impl = await agent(
  CONTEXT + "\n## Outline\n" +
  outline.sections.map((s, i) => (i + 1) + ". " + s.heading + " \u2014 " + s.covers).join("\n") + "\n\n" +
  "## Existing docs to reference\n" + (disc.existingDocs.length ? disc.existingDocs.join(', ') : '(none)') + "\n\n" +
  "## Instructions\n" +
  "Write the documentation at " + disc.targetPath + " following the outline.\n" +
  "- Code examples must be REAL \u2014 copy from working code or tests, not invented.\n" +
  "- Match the tone and format of sibling docs.\n" +
  "- If updating an existing file, preserve unrelated sections.\n" +
  "- Update any nav/index files if the doc layout requires it.",
  { label: 'write', schema: IMPL_SCHEMA }
)
if (!impl || !impl.done) {
  return { error: 'Write incomplete.', discover: disc, outline, blockers: impl ? impl.blockers : ['skipped'] }
}
log('Wrote: ' + impl.filesChanged.join(', '))

// \u2550\u2550\u2550 Phase 4: Verify \u2550\u2550\u2550
phase('Verify')

const verify = await agent(
  "Verify the documentation just written.\n\n" +
  "Files: " + impl.filesChanged.join(', ') + "\n\n" +
  "## Instructions\n" +
  "1. Extract every code example and run/compile it (or typecheck it). Flag any that fail.\n" +
  "2. Check every relative link and cross-reference resolves to a real file or anchor.\n" +
  "3. Spot-check accuracy: pick 3 claims about behavior and verify them against the code at\n" +
  disc.surface.slice(0, 5).map(s => "   - " + s).join("\n") + "\n" +
  "4. List concrete issues found (empty if clean).",
  { label: 'verify', schema: VERIFY_SCHEMA }
)
const issues = verify ? verify.issues : []
log('Verify: examples ' + (verify && verify.examplesOk ? 'OK' : 'FAIL') +
  ', links ' + (verify && verify.linksOk ? 'OK' : 'FAIL') + ', ' + issues.length + ' issues')

let fixNotes = '(clean)'
if (issues.length > 0) {
  const fixed = await agent(
    "Fix these documentation issues:\n" + issues.map((i, n) => (n + 1) + ". " + i).join("\n") +
    "\n\nFiles: " + impl.filesChanged.join(', '),
    { label: 'verify:fix', phase: 'Verify', schema: IMPL_SCHEMA }
  )
  fixNotes = fixed ? fixed.notes : '(fix skipped)'
}

// \u2550\u2550\u2550 Phase 5: PR \u2550\u2550\u2550
phase('PR')

const pr = await agent(
  "Open a PR for this documentation change.\n\n" +
  "## Subject\n" + TASK + "\n\n" +
  "Files: " + impl.filesChanged.join(', ') + "\n\n" +
  "## Instructions\n" +
  "1. Run lint/format on the doc files if the repo has a docs linter.\n" +
  "2. Commit, push, open a PR. Summarize what was documented and why.\n" +
  "3. Return PR URL, branch, and a 2-3 sentence summary.",
  { label: 'pr', schema: PR_SCHEMA }
)

return {
  summary: pr ? pr.summary : 'PR step incomplete. Docs written to ' + impl.filesChanged.join(', '),
  prUrl: pr ? pr.prUrl : null,
  branch: pr ? pr.branch : null,
  targetPath: disc.targetPath,
  filesChanged: impl.filesChanged,
  outline: outline.sections.map(s => s.heading),
  verify: verify ? { examplesOk: verify.examplesOk, linksOk: verify.linksOk, issues: issues.length } : null,
  fixNotes,
}
"""##

    public static var all: [String] { [autopilot, bugfix, dashboard, docs] }
}
