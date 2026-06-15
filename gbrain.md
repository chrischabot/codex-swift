# gbrain → codex-swift: what to reuse, what to learn, and how to build it

> A deep teardown of `../gbrain` (a mature TypeScript/Bun "personal knowledge
> brain", v0.42.43.0) mapped against codex-swift's memory + wiki subsystems, with
> a grounded, prioritized implementation plan. Produced 2026-06-14.

## TL;DR

gbrain is the production-hardened ancestor of the system our own
[`docs/features/memory-systems.md`](docs/features/memory-systems.md) sketches —
it is literally the "OpenClaw memory-wiki" that doc cites as a reference point.
It is a 123-command, ~40-core-module knowledge runtime that has already shipped
the things our wiki plan describes as future work: a deterministic
anti-hallucination write layer, an evidence-weighted enrichment orchestrator, a
durable job queue with quiet-hours, a nightly self-maintenance "dream cycle", a
hybrid+graph retrieval stack, contradiction detection with auto-supersession,
and a calibration/forecasting loop.

**The single most important finding is not "port gbrain." It is that we already
built ~40% of gbrain's highest-value machinery and never wired it in.** An
adversarial review verified, against our own source, that:

| Primitive we shipped | State today | gbrain analog |
|---|---|---|
| `SpendGate` (USD ceiling, reserve/settle) | **zero instantiation sites** | budget-tracker / budget-meter |
| `WikiLinkLinter.lint()` | **zero production callsites** (only tests) | BrainWriter pre-commit validators |
| mem0 `getUpdateMemoryMessages` + `updateMemory` | update path exists, **decision pass never called** → mem0 is ADD-only | facts two-tier dedup |
| `Scorer` (4-signal interestingness) | `_ = scorer` — **dead-assigned** at `Run.swift:247` | salience / enrichment priority |
| `markContradiction` / `setClaimStatus` / `claimsByStatus(.draft)` | exist, **never called** | eval-contradictions auto-supersession |
| claim `confidence` | **hardcoded `0.7`, `status:.active`** at `LiveResearchPorts.swift:134` | integrity three-bucket policy |
| `WatchScheduler.dueSources()` | computes due work, **nothing executes it** | autopilot per-source fan-out |
| `WikiClaimExtractor` LLM call | raw `URLSession.shared` + static Bearer, **bypasses SpendGate + auth refresh** | resolver cost layer |
| `informationGain` signal | `logprob` is a `log2(tokenCount)` / hash stub → **always 0** | info-gain proxy |

So the plan front-loads **wiring** (cheap, high-leverage, low-risk), then ports a
focused set of gbrain patterns that genuinely don't exist here, and explicitly
**declines** the parts of gbrain that fight our architecture (single-writer Swift
actor + SQLite/sqlite-vec + MLX, vs gbrain's multi-process Postgres/PGLite +
markdown-as-system-of-record).

## How this analysis was produced

A multi-agent workflow deep-read both codebases in parallel: 14 gbrain capability
clusters + 8 codex-swift modules were mapped to structured capability maps, then
13 themed gap analyses produced grounded recommendations, then two adversarial
critics (a *completeness* lens and a *feasibility/grounding* lens) verified each
claim against actual source. ~88 recommendations survived. Every "we already
have X" / "X is dead code" assertion below was checked against the file and line.
The critique's corrections are folded in inline and collected in
[§11](#11-critique-driven-corrections-honest-gaps).

---

## 1. What gbrain actually is

gbrain is a **personal knowledge brain**: a markdown vault (`people/`,
`companies/`, `concepts/`, …) plus a derived database (PGLite by default,
Postgres+pgvector for scale). Its load-bearing ideas:

- **Markdown is the system of record; the DB is a rebuildable derived cache.**
  `gbrain rebuild` wipes the DB and regenerates it from the repo. User knowledge
  (facts, takes, links, timeline) lives in fenced markdown blocks
  (`<!--- gbrain:facts:begin -->`), each with a parser + a reconciler cycle phase
  + a byte-identical round-trip test, enforced by a CI gate. Multi-machine sync
  is just git. (`docs/architecture/system-of-record.md`)
- **The four-layer "Knowledge Runtime"** (`docs/designs/KNOWLEDGE_RUNTIME.md`):
  L1 Resolvers (uniform external-lookup interface with typed confidence/source),
  L2 Enrichment Orchestrator (completeness rubric + budget + cascade), L3
  Scheduler (durable jobs + quiet-hours), L4 Deterministic Output Builder
  (transactional `BrainWriter` + `Scaffolder` + `SlugRegistry` + pre-commit
  validators). The invariant: **"LLM picks WHAT to write; code guarantees WHERE
  and HOW."**
- **Schema packs**: typed page kinds (`person`, `company`, …) with per-type
  behavior defaults (`extractable`, `expert_routing`, path-prefix inference,
  completeness rubric). A closed *primitive* enum × an open *type-name* axis ×
  an *alias-closure* query-expansion graph, kept separate on purpose.
- **The dream cycle**: a nightly, lock-guarded, budget-metered maintenance loop
  that consolidates near-duplicate facts, synthesizes concepts, grades
  predictions, fixes citations, detects drift/anomalies — turning a pile of
  read-only scanners into autonomous state transitions.
- **Hybrid + graph retrieval**: vector + BM25 + RRF + **typed-edge graph
  traversal** + cross-encoder reranker, with intent classification, recency
  decay, source-boost, title/alias hops, an evidence/`create_safety` contract,
  and a floor-ratio gate. gbrain's own BrainBench numbers attribute **+31 P@5
  points to the graph arm** — "the graph isn't a marginal feature; it's the
  load-bearing wall."
- **Minions job queue**: a durable, token-fenced, lease-based SQL job state
  machine with quiet-hours, deterministic stagger, backpressure, circuit
  breaking, and an AIMD adaptive concurrency controller.
- **Calibration**: extract falsifiable predictions → grade them against later
  evidence → per-domain Brier scorecards ("your technology calls are 60%
  accurate — you tend to be ~18 months early"), plus a `voice-gate` that judges
  every user-visible string for tone.
- **Push context**: the brain proactively volunteers confidence-gated page
  pointers from a rolling conversation window (not auto-loading bodies).
- **Thin-harness / fat-skills + skillopt**: judgment lives in markdown skills;
  a three-tier resolver keeps 300+ skills affordable per turn; `skillopt` is a
  gradient-free LLM-as-optimizer with held-out scoring and regression gates.

## 2. Lineage: we are not starting from zero

Our `memory-systems.md` already adopted gbrain's conceptual frame: immutable raw
sources, a compiled wiki, claims with provenance/confidence/contradictions,
digests, and the Karpathy "LLM wiki" split. Our schema is in places **richer than
gbrain's**: `ClaimRow` has a real status lifecycle, `ClaimEvidenceRow` carries
`stance` (supports/opposes/nuances) + `relevance` + `strength`, `SynthesisRow`
has a full thesis mode (`coreClaim`/`falsification`/`verdict`/`evidenceFor`),
`SourceMetaRow` carries trust/credibility/volatility. We also **exceed** gbrain
on a few axes that matter:

- **Network safety**: `EgressGuard` blocks loopback/RFC1918/ULA/link-local for
  IPv4 *and* IPv6; `PinnedFetcher` connect-to-vetted-IP with re-vet-on-redirect.
  This is strictly stronger than gbrain's `url_reachable` DNS-rebinding check —
  **do not port that resolver; route any new network path through PinnedFetcher.**
- **Local-first inference**: MLX Qwen/Nomic + `BoundedInferenceProvider` caps +
  `MemoryPressureMonitor`. gbrain is cloud-API-only for embed/extract.
- **Architecture**: `MemoryStore` is a single-writer Swift `actor` over WAL
  SQLite. That actor *is* the serialization boundary, which means a large class
  of gbrain's machinery (`SELECT … FOR UPDATE SKIP LOCKED`,
  `pg_advisory_xact_lock`, the unix-socket IPC bridge for single-connection
  PGLite) collapses to a plain actor-isolated `UPDATE` — simpler and faster.

The job is therefore **selective**: wire what we built, port the algorithms that
are genuinely missing, adapt the storage-coupled patterns, and decline the rest.

## 3. Capability matrix

| Capability | gbrain | codex-swift today | Verdict |
|---|---|---|---|
| Personal memory extraction + dedup | facts: two-tier cosine+LLM, decay, forget, eligibility, notability | mem0 additive **ADD-only** (md5 dedup, no update pass), no decay | **Wire + adapt** |
| Anti-hallucination write layer | BrainWriter txn + validators + Scaffolder + SlugRegistry | `WikiLinkLinter` exists but **unwired**; writes are separate `try?` calls | **Wire (P0)** |
| Spend ceiling | budget-tracker + budget-meter (per-phase USD caps) | `SpendGate` exists, **zero callsites** | **Wire (P0)** |
| Enrichment orchestration | completeness rubric + budget + cascade + tier | none; `Scorer` dead-assigned | **Port + wire** |
| Durable job queue | minions (lease/fence/backpressure/quiet-hours) | `SnapshotScheduler`, `WatchScheduler` (cadence only, **no executor**), `Cron` | **Port (adapt to actor)** |
| Nightly self-maintenance | dream cycle (consolidate/synthesize/grade/drift) | none (ingest-only) | **Port (P0)** |
| Typed page kinds | schema packs (full manifest cathedral) | `category` is a free TEXT string | **Adapt (closed enum)** |
| Hybrid retrieval | vec+BM25+RRF+**graph**+rerank+intent+recency+boosts | vec+BM25+RRF+BGE rerank; **graph unused at search time** | **Port signals** |
| Contradiction detection | 6-verdict temporal judge + auto-supersession | schema exists, transitions **never called** | **Wire + port judge** |
| Calibration / forecasting | falsifiability → grade → Brier scorecards + voice-gate | thesis schema exists, **never graded** | **Port** |
| Proactive push context | entity-salience volunteer over rolling window | recall-on-demand only; single-turn input | **Port (needs window)** |
| Code-intelligence graph | symbol def/callers/callees/refs, AST chunkers | none | **Spike on existing graph** |
| Skill optimization | skillopt held-out scoring + regression gates | `BenchKit` (DeepSWE-coupled), prompts unversioned | **Generalize BenchKit** |

---

## 4. The reuse / learn taxonomy

Every recommendation is classed by how it crosses the architecture gap (gbrain is
TS / Postgres·PGLite / markdown-vault; we are Swift / SQLite·sqlite-vec / MLX):

- **direct-reuse** — pure algorithm, ports almost verbatim: completeness rubric,
  per-kind exponential decay (we already have the curve in `WikiFreshness`),
  weighted Brier, quiet-hours evaluation, FNV-1a stagger, intent classifier,
  evidence/`create_safety` contract, floor-ratio gate, three-bucket confidence
  policy, prompt-injection sanitizer.
- **adapt** — same idea, different substrate: the job queue (SKIP LOCKED →
  actor-isolated UPDATE), markdown forget-fence → SQLite soft-delete tombstone,
  schema-pack manifest → closed `WikiPageKind` enum, BrainWriter transaction →
  a `WikiWriteGate` over our existing `BEGIN IMMEDIATE`.
- **inspire-only** — concept worth knowing, not worth porting now: tier-routing
  swarm budgets, semantic Savitzky-Golay chunker, per-source pack federation,
  calibration-aware retrieval re-weighting.
- **deliberate-exclusion** — actively *do not* build (see [§10](#10-deliberate-non-ports)).

---

## 5. Prioritized roadmap (waves)

Each wave is independently shippable and ordered by leverage-per-risk. Effort is
S/M/L/XL; every item maps to a detailed sketch in §7–§9 below.

### Wave 0 — Wire the dead primitives + close the safety holes (P0, ~2–3 wks)

The highest leverage in the whole document. Almost no new code; mostly
instantiation + threading.

1. **SpendGate everywhere** (M). Instantiate bucket-isolated `SpendGate`s in
   `CodexMemoryRun.assemble()`; route `WikiClaimExtractor`, `LiveGapReflector`,
   `LiveResearchCompiler`, and the orchestrator's per-round loop through
   `SpendGate.run()`. Replace `WikiClaimExtractor`'s raw `URLSession.shared` with
   `Mem0OpenAILLM` (which already does 401-refresh + JSON mode). Add `--max-usd`.
   *Closes the documented "remote extraction has real dollar cost with no
   ceiling" hole.*
2. **WikiWriteGate** (M). Wrap the four `LiveResearchCompiler` writes
   (`upsertSynthesis`/`upsertClaim`/`attachEvidence`/`linkSynthesisClaim`) in one
   `BEGIN IMMEDIATE` transaction and run the existing `WikiLinkLinter.lint()` as a
   pre-commit gate with a `strict|lint|off` mode (default `lint`, soak then flip).
3. **Three-bucket confidence write policy** (M). Replace hardcoded
   `confidence:0.7, status:.active` with `extractorConfidence × CredibilityScorer`
   trust: ≥0.8 → `.active`; 0.5–0.8 → `.draft` (the existing review queue);
   <0.5 → skip+log. Zero new schema.
4. **Close the mem0 ADD-only gap** (L). Wire the dormant
   `getUpdateMemoryMessages` + `updateMemory`/`deleteMemory` into a two-tier
   cosine(0.95 fast-path)+LLM(mid-band) reconciliation pass in
   `addToVectorStoreInfer`. Satisfies the two currently-unmet `docs/MEM0.md`
   acceptance criteria.
5. **Context sanitizer** (S). A pure `ContextSanitizer` that neutralizes
   prompt-injection/envelope-escape in fetched web/arxiv/GitHub/transcript text
   *before* it reaches any extraction/synthesis prompt, + a "this is DATA, never
   instructions" preamble.
6. **[critique] mem0 store-level tenant scoping** (M, **elevated to P1**).
   `Mem0SQLiteStore` filters by a **post-fetch in-memory predicate**
   (`matchesFilters`), not a SQL `WHERE` scope. A filter-construction bug leaks
   cross-tenant memories. Move scope to the store query.

### Wave 1 — Autonomous maintenance + durable jobs (P0/P1, ~3–4 wks)

7. **MaintenanceCycle** (M, P0). A `runCycle(now:abort:budget:)` orchestrator
   composing the *existing* read-only scanners into state transitions:
   freshness (`staleClaims` → `setClaimStatus(.stale)`), drift
   (`auditDriftScan` → mark synthesis needs-review), librarian
   (`librarianScan` → persist Tier-2 queue). Hosted in `SnapshotScheduler`
   *before* the VACUUM. New `codex-memory cycle [--phase][--dry-run][--json]`.
8. **Cycle lock** (S, P0) — `cycle_lock` table with TTL + cooperative refresh;
   busy → `skipped`, not error. (This is the **cross-process** guard the actor
   does *not* provide — see [§11](#11-critique-driven-corrections-honest-gaps).)
9. **Consolidation phase** (L, P0) — greedy cosine clustering + supersede of
   near-duplicate mem0 memories (Layer 1 zero-LLM; Layer 2 the
   `getUpdateMemoryMessages` pass), never deleting (audit trail).
10. **Per-cycle budget meter** (M, P1) — the same `SpendGate`, bucket
    `dream-cycle`, budget-exhausted = `ok+partial` not failure.
11. **Self-consumption guard** (S, P1) — `generated_by` marker + `NOT EXISTS`
    filter so the cycle never re-ingests its own synthesis output.
12. **Durable `MemoryJobStore`** (L, P0) — a `job` SQLite state machine (lease
    token, atomic claim, idempotency partial index, exponential backoff via
    `InfraPrimitives.Backoff`, dead-letter). The actor collapses SKIP LOCKED.
13. **Quiet-hours gate at claim time** (S, P0) + **submission backpressure
    `maxWaiting`** (S, P1, filter by `(kind, queue)` not `kind` alone) +
    **FNV-1a stagger** (S, P2).
14. **Wire `WatchScheduler` into a poll loop** (M, P1) on the job substrate —
    `dueWatchSources` → enqueue → claim → fetch→SHA-gate→ingest → `advanceWatch`.
    *Closes the "computes due work, nothing executes it" gap.*

### Wave 2 — Retrieval & knowledge quality (P1/P2, ~3–4 wks)

15. **Graph-augmented retrieval** (L, P2) — finally use the entity/edge graph at
    search time (gbrain's +31 P@5 "load-bearing wall"). **Must batch** the
    entity lookups (the search path runs on the single-writer actor — N+1 would
    regress latency; see [§11](#11-critique-driven-corrections-honest-gaps)).
16. **Zero-LLM intent classifier** (M, P1) → per-intent weights, replacing the
    hardcoded `0.7/0.2/0.1` blend; wires the dead `time_window_days` param.
17. **Recency decay** (S, P1, reuse `WikiFreshness`) + **floor-ratio gate** (S,
    P1, the correctness guard that makes multiple boosts safe) + **source-boost**
    (S, P2).
18. **Evidence + `create_safety` contract** (M, P1) — stamp *why* each hit
    matched so page-creation tools key dedup off evidence, not a raw score.
19. **Autocut** (S, P2) + **title/alias-phrase boost + `page_alias` table** (M,
    P2).
20. **Typed `WikiPageKind` enum + per-kind defaults** (M, P1) and **per-kind
    completeness rubrics in `LibrarianScorer`** (M, P1) + **declarative per-kind
    lint table** (S, P2). The highest-value half of schema packs at our altitude.
21. **[critique] search telemetry + tune surface** (S, P2) — the new ~10 knobs
    are un-measurable without a feedback loop; `MemoryStore/Metrics.swift` has the
    ring substrate but emits nothing about recall quality.

### Wave 3 — Contradiction & calibration (P0/P1/P2, ~3–4 wks)

22. **6-verdict temporal contradiction judge** (M, P0) +
    **claim-pair probe runner** with date+cosine pre-filter (L, P0; requires a
    new `nearestClaims` KNN over claim-evidence chunk vectors — claims have no
    own embedding space) + **prompt-version verdict cache** (S, P1).
23. **Auto-supersession resolver** (M, P0) — convert verdicts into the
    *never-called* `setClaimStatus`/`markContradiction` transitions, gated behind
    `CODEXKIT_WIKI_AUTO_SUPERSEDE` + a ≥0.8 confidence bucket. We can go further
    than gbrain (which only prints paste-ready CLI strings) because we own a
    transactional store with an explicit lifecycle enum.
24. **`wiki-contradictions` CLI + `memory_contradictions` MCP tool** (M, P1) —
    reuse `BenchKit`'s existing `wilson()` (do **not** re-port Wilson CI).
25. **Facts decay + eligibility + soft-delete** (S/S/M, P1/P2) — per-kind decay
    (reuse `WikiFreshness`), pre-LLM eligibility gate, and a soft-delete tombstone
    that **propagates to the entity store's `linked_memory_ids`** (today deletes
    leave stale graph refs — a user-visible recall bug).
26. **Falsifiability grading + Brier scorecards** (L/M, P1) — a `ThesisGradeFilter`
    (≥0.7 falsifiability → ~93% volume reduction *before* any model cost) + a pure
    `CalibrationScorer` (scalar + weighted Brier, n≥5 floor) over the resolved
    theses our schema already supports but never grades. **Voice-gate** (M, P2).

### Wave 4 — Proactive push context (P1, ~2–3 wks, highest-risk edit)

27. **Rolling conversation window** (M, P1) — replace the single-turn
    `LatestUserInput` stash with a bounded N-turn window in `SessionEngine.swift`.
    **This is the riskiest edit in the plan**: `SessionEngine.swift` is a large,
    codex-rs-tracked harness file with delicate per-turn ordering
    (`LatestUserInput` is removed-and-re-stashed at 4279–4282; the window append
    must land in the same teardown block as `LatestAssistantOutput` at 4264).
28. **Entity-salience extractor + confidence-gated pointer resolver** (L, P1) —
    zero-LLM, three-arm ladder (alias 0.9 / title 0.8 / suffix 0.6, +0.05
    multi-turn, gate 0.7, resolve-2×-then-gate), pointers not bodies.
29. **Wire volunteering into `registerMemory`** (M, P1) as a second
    context-contributor with slug-only cross-turn suppression, config-gated.

### Wave 5 — New corpora & governance (P1/P2/P3, opportunistic)

30. **Code-intelligence spike on the existing graph** (M, P1) — index source
    files as `source='code'` documents, symbols as `kind='symbol'` entities,
    calls/imports as edges. `memory_graph_walk` *already* answers callers/callees.
    Zero new tables. Prove value before any tree-sitter dependency (XL, P2).
31. **Implement the stubbed `git` WikiIngest adapter** (M, P1) — ingest source
    *trees*, not just repo metadata; the missing ingest mouth for the code corpus.
32. **Generic held-out scoring harness over BenchKit** (L, P1) + **prompt
    version-stamping + regression gate** (M, P1). The measurement foundation that
    must precede any optimizer.
33. **Resolver `<I,O>` seam** (S, P1, optional) — only if/when we have ≥3 external
    lookups that benefit from a shared confidence/cost envelope. Not urgent.

### Things deferred / declined → [§10](#10-deliberate-non-ports)

---

## 6. Central finding: the dead-code wiring map

These are verified-against-source. Each is a near-zero-risk win because the hard
part (the primitive) already exists and is tested:

| File:symbol | Today | Wire it to |
|---|---|---|
| `MemoryScore/SpendGate.swift` | 0 instantiation sites | every live LLM/web call (Wave 0.1) |
| `MemoryStore/WikiLinkLinter.swift :: lint()` | 0 production callsites | `WikiWriteGate` (Wave 0.2) |
| `Mem0Core :: getUpdateMemoryMessages` / `updateMemory` | defined, decision pass never called | reconciliation pass (Wave 0.4) |
| `LiveResearchPorts.swift:134` `confidence:0.7,status:.active` | hardcoded | three-bucket policy (Wave 0.3) |
| `Run.swift:247` `_ = scorer` | dead-assigned | enrichment priority queue (Wave 2) |
| `MemoryStore+Wiki :: markContradiction/setClaimStatus` | never called | auto-supersession (Wave 3) |
| `claimsByStatus(.draft)` | never called | the `.draft` review queue (Wave 0.3) |
| `WatchScheduler.dueSources()` | computes, nothing executes | job-driven poll loop (Wave 1.14) |
| `HybridSearchTool.time_window_days` | schema-only, never decoded | temporal intent (Wave 2.16) |
| `MLXLocalProvider.logprob` / `ModelClientBridge.logprob` | `log2(tokenCount)` / hash stub → `informationGain`≡0 | **zero the weight** until a real perplexity path exists (Wave 2) |
| `entityKindBonus` (Scorer) | uncapped → `total` can exceed 1.0 | clamp when activating Scorer |

---

## 7. Detailed proposals — write integrity, resolvers, enrichment

### 7.1 Deterministic Output Builder (gbrain L4) → `WikiWriteGate`

**gbrain**: every mutation flows through `BrainWriter.transaction()`; pure
pre-commit `PageValidator`s read pending state and a `StrictMode` decides
rollback-vs-warn; a `Scaffolder` builds every URL/citation from *structured*
inputs (regex-validated, `ScaffoldError` before any string renders); a
`SlugRegistry` does collision detection + numeric disambiguation; a `validate:
false` grandfather opt-out + a lint-mode "post-write" soak make strict rollout
incremental.

**Us**: `LiveResearchCompiler` writes synthesis/claim/evidence/link as four
separate `try?` calls (a crash mid-loop strands a claim); `WikiLinkLinter`
*detects* broken links / ungrounded grounding-required pages / non-reciprocal
see-also but is **never called on a write path**; the `wiki-lint` CLI does
*different* checks (markdown structure + index health). Citations are raw string
interpolation; page slugs dedup only by content-SHA so two genuinely-different
pages that slugify the same silently collide.

**Recommendations**

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | `WikiWriteGate`: run `WikiLinkLinter.lint()` as a pre-commit gate, all four writes in one `BEGIN IMMEDIATE`, `strict/lint/off` mode via `wiki.lint_on_write` meta | adapt | M | **P0** |
| 2 | `WikiScaffold` pure builders for citations / source-list / entity-links, regex-validated, `ScaffoldError` before render | direct-reuse | S | P1 |
| 3 | `reserveSynthesisSlug` collision check + numeric disambiguator, **same-content = idempotent reuse** (no `-2` on re-run) | adapt | M | P1 |
| 4 | Three-bucket confidence write policy (see Wave 0.3) | direct-reuse | M | P1 |
| 5 | `WikiPromptSanitizer`/`ContextSanitizer` (mirror `Mem0SecretScanner` shape) | direct-reuse | S | P1 |
| 6 | See-also reciprocity as a write-time warning (`nonReciprocalSeeAlso` already detects) | adapt | S | P2 |

> Grounding note (from critique): WikiWriteGate is **additive to**, not duplicative
> of, the `wiki-lint` CLI — `CodexMemoryWikiLint` checks markdown structure +
> index health and does *not* call `WikiLinkLinter`'s broken-link/grounding rules.

### 7.2 Resolver SDK (gbrain L1)

gbrain's `Resolver<I,O>` gives every external lookup a uniform interface with
typed `confidence`/`source`/`cost`/`fetchedAt`, an `available(ctx)` readiness
probe, and a registry that dedups callsites. **For us this is mostly future-proofing**
— our highest-value items here are the *concrete* gbrain ideas (cost gating, auth
refresh, three-bucket confidence), not the abstraction. Recommendation:

- **P0**: route `WikiClaimExtractor`/`LiveGapReflector` through `SpendGate` +
  `Mem0AuthProvider` (this is Wave 0.1 — the resolver-SDK theme's headline).
- **P1, optional**: define a thin `Resolver<I,O>` + `ResolverResult<O>` envelope
  in a new `MemoryResolve` target reusing `Deadline`; map `confidence` to
  `CredibilityScorer`'s 0–1 output so a credibility-backed resolver is a one-line
  adapter. Add a `ResolverRegistry` actor only when ≥3 resolvers exist.
- **P3, inspire-only**: `FailImproveLoop` (deterministic-first with self-documenting
  logged LLM fallbacks → `generateTestCases`) — port only if the
  deterministic-credibility heuristics start needing a fallback ladder.
- **deliberate-exclusion**: `url_reachable` DNS-rebinding resolver — we exceed it
  via `EgressGuard`+`PinnedFetcher`. Mandate any new network resolver route
  through `PinnedFetcher`.

### 7.3 Enrichment orchestrator (gbrain L2)

gbrain replaced a `length > 500 chars` completeness stub with **evidence-weighted
per-type rubrics** (weights validated to sum to 1.0 at load), a two-layer budget
(`BudgetTracker` in-process + DB `BudgetLedger` reserve/settle with TTL), a
**grounding gate** (skip LLM entirely below 200 chars of source-tagged context),
inbound-link-count candidate ordering, and a bidirectional cascade.

**Us**: `LibrarianScorer` measures staleness/time-decay but has **no page-quality
signal**; `Scorer` (the 4-signal interestingness gate) is dead-assigned; there is
no completeness rubric, no enrichment priority queue, no grounding gate.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | Wire `SpendGate` into every frontier/research call (Wave 0.1) | adapt | M | **P0** |
| 2 | `CompletenessScorer` per-`EntityKind` rubric (weights sum-to-1.0 throwing init) + `enrichCandidates(limit:)` ordered by inbound-link count (lightweight projection, no bodies) | adapt | L | P1 |
| 3 | Char-count grounding gate before the local extractor (skip-without-spend) + `mem.extract.skipped_thin` metric | direct-reuse | S | P1 |
| 4 | `ContextSanitizer` over every extraction/synthesis prompt | direct-reuse | M | P1 |
| 5 | Activate `Scorer` to drive the priority queue; **clamp `entityKindBonus`** so `total ≤ 1.0`; **set `weightInformationGain = 0`** until a real logprob path exists | adapt | M | P2 |
| 6 | Bidirectional `EntityGraph` cross-reference cascade after compile | adapt | M | P2 |
| 7 | Op-checkpoint resume (content-hash fingerprint, flush every N) for import/research | adapt | M | P3 |
| 8 | Entity-importance tier routing for the research swarm | inspire-only | L | P2 |

## 8. Detailed proposals — scheduling, maintenance, retrieval, types

### 8.1 Durable scheduler + minions

gbrain's minions: a token-fenced lease lock (all writes validate `lock_token`),
heartbeat renewal at ½ lease, stall-detector reclaim, `SELECT … SKIP LOCKED`
atomic claim, quiet-hours evaluated **at claim time** (a job submitted before a
window becomes claimable during it; unknown tz fails *open*), submission
backpressure (`maxWaiting`, filter by `(name, queue)` — a cross-queue-bleed bug
they fixed), deterministic FNV-1a stagger, an AIMD adaptive concurrency
controller, and a wedge-watchdog (alive-but-no-progress → restart).

**Us**: `SnapshotScheduler` (daily VACUUM+git+prune) and `WatchScheduler`
(volatility cadence + exponential backoff) exist but there is **no durable job
substrate and no executor** — `WatchScheduler.dueSources()` is computed and
discarded. `Cron` (the codexd feature) is our one mature durable scheduler.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | `MemoryJobStore` SQLite state machine (lease/fence/idempotency/backoff/dead-letter); actor collapses SKIP LOCKED → plain `UPDATE … LIMIT 1 RETURNING` | adapt | L | **P0** |
| 2 | Quiet-hours gate at claim time (pure `evaluate(now:)`, fail-open on bad tz, midnight-wrap) | direct-reuse | S | **P0** |
| 3 | Wire `WatchScheduler` into a durable poll loop (enqueue→claim→ingest→`advanceWatch`) | adapt | M | P1 |
| 4 | `maxWaiting` backpressure (filter `(kind,queue)`; emit `mem.job.coalesced`) | adapt | S | P1 |
| 5 | FNV-1a deterministic stagger | direct-reuse | S | P2 |
| 6 | Promote `Cron` onto the job substrate (retry + dead-letter + quiet-hours) — **after** the substrate is independently proven; the locked-down `.never/.readOnly/no-network` SessionConfig must stay a hard-gated regression test | adapt | M | P2 |
| 7 | Wedge-watchdog for the `codex-memory` daemon | inspire-only | M | P3 |
| 8 | **[critique]** AIMD adaptive concurrency cap for the MLX lane — *adapt the existing* `BoundedInferenceProvider` fixed caps, don't build new | adapt | M | P2 |
| 9 | **[critique]** `Mem0HTTPServer` request admission — it spawns one detached task per connection, uncapped; reuse `InfraPrimitives/BoundedChannel` | adapt | S | P2 |

### 8.2 Nightly dream/cycle self-maintenance

The missing autonomous layer. gbrain's `runCycle` runs ordered phases (each
returns `ok|partial|skipped`), guarded by a DB advisory lock (5-min TTL +
cooperative refresh), budget-metered per phase (exhausted = `ok+partial`),
content-hash idempotent, with a self-consumption guard (`dream_generated` flag +
`NOT EXISTS` filter) preventing hallucination-amplification.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | `MaintenanceCycle` orchestrator composing existing scanners into transitions (freshness/drift/librarian phases) | adapt | M | **P0** |
| 2 | `cycle_lock` table (TTL + refresh; busy = `skipped`) — **cross-process** guard | adapt | S | **P0** |
| 3 | Consolidation phase (cosine cluster + supersede mem0 dups; never delete) | adapt | L | **P0** |
| 4 | Per-cycle `SpendGate` budget meter | direct-reuse | M | P1 |
| 5 | Self-consumption guard (`generated_by` marker) | direct-reuse | S | P1 |
| 6 | Host the cycle in `SnapshotScheduler.runOnce` *before* VACUUM; add `codex-memory cycle` | adapt | S | P1 |
| 7 | Synthesize-concepts phase (atom-tier clustering → concept pages) | adapt | L | P2 |
| 8 | Tier-2 escalation + claim-grading phase | adapt | XL | P2 |
| 9 | Zero-LLM anomaly diagnostic (mean+σ over ingest cohorts) | adapt | M | P3 |

### 8.3 Retrieval engine upgrades

Our `MemoryRetriever` is vec+BM25+RRF+BGE with a **hardcoded `0.7·rerank +
0.2·vec + 0.1·bm25` blend** and no graph, intent, recency, source, title, or
alias signals. gbrain's stack adds exactly those and attributes most of its
recall to the graph arm.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | Zero-LLM `QueryIntent.classify` → per-intent weights (replaces the fixed blend; wires `time_window_days`) | adapt | M | P1 |
| 2 | Recency decay post-fusion boost (reuse `WikiFreshness` `0.5^(age/halflife)`) | direct-reuse | S | P1 |
| 3 | Floor-ratio gate computed **once** before any boost (the correctness guard) | direct-reuse | S | P1 |
| 4 | Evidence + `create_safety` contract on every `RetrievedHit` (dedup signal for page-creation) | adapt | M | P1 |
| 5 | **Graph-signal boost** — use the entity/edge graph at search time; **batch the entity fetch (hard requirement, not a risk)** | adapt | L | P2 |
| 6 | Autocut on the reranker score cliff (gated on cross-encoder scores, not RRF) | direct-reuse | S | P2 |
| 7 | Source-aware ranking factors + hard excludes | adapt | S | P2 |
| 8 | Title/alias-phrase boost + `page_alias` table | adapt | M | P2 |
| 9 | Mode bundles + explain formatter + **[critique] telemetry/tune loop** (un-measurable knobs are a regression in disguise) | adapt | M | P2/P3 |
| 10 | Knobs-hash-versioned semantic result cache | adapt | L | P3 |

### 8.4 Schema packs → typed `WikiPageKind`

gbrain's full schema-pack "cathedral" (YAML manifest, `extends` chains, per-source
federation, 11-verb CLI, registry distribution) is **overkill** for our
single-ontology, author-fixed system. The high-value core ports cleanly:

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | Closed `WikiPageKind` enum + `WikiPageKindDefaults` (`groundingRequired`, `extractable`, `defaultVolatility`, `requiredFields`); keep `category` TEXT, parse at read boundary, unknown→`.note` with `legacy_type` stamp | adapt | M | P1 |
| 2 | Per-kind weighted completeness rubrics in `LibrarianScorer` (the highest-value port; surfaces the *specific* missing dimension) | adapt | M | P1 |
| 3 | Declarative per-kind lint table generalizing `WikiLinkLinter.groundingRequired` | adapt | S | P2 |
| 4 | Zero-LLM kind-drift detect (`categoryDistribution()` GROUP BY + unknown detection) | adapt | S | P2 |
| 5 | Per-kind extraction schemas (`[WikiPageKind: ExtractionSchema]`) | adapt | L | P3 |

> Keep the closed-enum collapse: gbrain split primitive/type/alias only because
> *pack authors* add open types. Our types are author-fixed, so one enum is the
> right altitude. The `legacy_type` rollback stamp is worth keeping.

## 9. Detailed proposals — facts, contradictions, calibration, push, code, skills

### 9.1 Facts lifecycle

mem0's add pipeline is **ADD-only** — md5-dedup-then-skip, no
update/supersede/forget decision (the `updateMemory` + `UPDATE` history row exist;
only the *decision* is missing). gbrain's facts layer adds: two-tier dedup
(cosine 0.95 fast-path / LLM classifier / 0.92 fallback, each with a reason
discriminator), per-kind exponential decay, an eligibility gate before LLM spend,
a notability tier at extraction, and markdown-fence forget.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | Two-tier cosine+LLM dedup with UPDATE/DELETE/NONE (wire `getUpdateMemoryMessages`) | direct-reuse | L | **P0** |
| 2 | Per-kind exponential confidence decay at recall (reuse `WikiFreshness`; 0.05 floor; `applyDecay` opt-in) | direct-reuse | S | P1 |
| 3 | Pre-LLM extraction-eligibility gate (system-only / <80 chars / `no_capture`) on the *automatic* capture path only | adapt | S | P1 |
| 4 | Soft-delete tombstone (forget that survives) **+ entity-store `linked_memory_ids` propagation** (today: stale refs surface deleted memories) | adapt | M | P2 |
| 5 | 6-verdict temporal contradiction probe at the `ClaimRow` layer (see 9.2) | adapt | L | P2 |

> Decay note: gbrain uses `confidence × exp(-age/halflife)`; our `WikiFreshness`
> uses the equivalent `0.5^(age/halflife)`. **Keep ours** for consistency — do not
> reimplement the curve, only the kind→halflife table is new (`event 7d`,
> `commitment/preference 90d`, `belief/fact 365d`).

### 9.2 Contradiction detection & auto-supersession

Our `ClaimStatus` lifecycle (`draft/active/stale/contradicted/archived`) and the
`markContradiction`/`setClaimStatus` transitions exist but are **never invoked**.
gbrain ships the producer: a 6-verdict temporal judge (`noContradiction`,
`contradiction`, `temporalSupersession`, `temporalRegression`, `temporalEvolution`,
`negationArtifact`) with a 0.7 confidence floor, a date+cosine pre-filter, a
prompt-version-keyed verdict cache, and a propose-then-transition resolver.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | `ContradictionJudge` 6-verdict (port the prompt; `ContradictionJudgeBackend` protocol for a mock; 0.7 floor) | adapt | M | **P0** |
| 2 | `ContradictionProbe` runner + `nearestClaims` KNN (claims ride evidence-chunk vectors — **new method, a prerequisite that raises this from M→L**) + date+cosine pre-filter | adapt | L | **P0** |
| 3 | Prompt-version verdict cache (`claim_judge_cache`, order-independent key) | direct-reuse | S | P1 |
| 4 | `SupersessionResolver` → the *real* `setClaimStatus`/`markContradiction` transitions, gated behind opt-in + ≥0.8 | adapt | M | **P0** |
| 5 | `wiki-contradictions` CLI + `memory_contradictions` MCP tool + run tracking — **reuse `BenchKit.wilson()`** | adapt | M | P1 |
| 6 | At-write conflict check in the claim producer — **sequence AFTER** the extractor emits non-`.supports` stances (today always `.supports`) | adapt | M | P2 |

### 9.3 Calibration, takes, forecasting

We produce falsifiable theses (`SynthesisRow.falsification`/`thesisStatus`) and
**never grade them**. gbrain closes the loop: falsifiability scoring at extraction
(≥0.7 + category≠`not_prediction` → 93% volume cut before model cost), evidence
retrieval for the eligible subset, then per-domain Brier scorecards (scalar +
*weighted* Brier where `conviction = |confidence−0.5|×2`). Plus a `voice-gate`
(generate→judge→retry→template-fallback) for every user-visible string.

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | `ThesisGradeFilter` (pure eligibility) + `ThesisGrader` (model-escalate the eligible subset only) + `resolveThesis`/`gradeableTheses` + `wiki-grade` CLI | adapt | L | P1 |
| 2 | Pure `CalibrationScorer` (scalar + weighted Brier, n≥5 cold-start floor, per-category) | direct-reuse | M | P1 |
| 3 | Voice-gate for LLM-authored copy | adapt | M | P2 |
| 4 | Zero-LLM "stale high-conviction" drift surfacing | adapt | S | P2 |
| 5 | Wave-versioned undo for batch grading runs | adapt | S | P3 |
| 6 | Calibration-aware retrieval re-weighting (feed the loop back) | inspire-only | M | P3 |

### 9.4 Proactive push context

gbrain volunteers confidence-gated *pointers* (name→slug→synopsis) from a rolling
window — push noise gated below pull silence. We recall on-demand only and have a
single-turn input. See Wave 4 for the (risk-flagged) `SessionEngine` window
prerequisite, the zero-LLM entity-salience extractor + three-arm pointer resolver,
and the `registerMemory` second-contributor wiring with slug-only suppression.
**deliberate-exclusion**: the unix-socket resolve-IPC bridge — our store is an
in-process actor, so there is no single-connection lock to work around.

### 9.5 Code-intelligence knowledge graph

codex-swift *is* a coding agent, so a code corpus is high-value. The cheapest
first cut reuses the existing entity/edge/mention tables **verbatim**: source
files → `source='code'` documents, top-level symbols → `kind='symbol'` entities
(qualified canonical name), calls/imports → edges. callers = `edges WHERE
dst=X AND relation='calls'`; `memory_graph_walk` already answers depth-N walks.
Then: the stubbed `git` WikiIngest adapter to ingest trees; thin
`code_def/code_refs/...` MCP tools; and *only after value is proven*, a native
tree-sitter AST chunker + receiver-type-resolving edge extractor (XL).

### 9.6 Skillpack / skillopt → measurement first

gbrain's `skillopt` is a gradient-free LLM-as-optimizer, but its **foundation** is
a held-out scoring harness with three judge kinds (rule/llm/qrels) and
SHA-keyed receipts + a regression gate. That foundation is what we lack and what
must come first:

| # | Rec | Port | Eff | Pri |
|---|---|---|---|---|
| 1 | Generic `SkillScorer` over `BenchKit` primitives (rule/llm/qrels judges, SHA-8 receipts) — decouple from DeepSWE | adapt | L | P1 |
| 2 | Version-stamp + regression-gate the hardcoded prompts (`additiveExtractionPrompt`, `ExtractionPrompt`, `WikiClaimExtractor` system prompt) | adapt | M | P1 |
| 3 | Three-tier skill resolver (enabled/disabled governance) | adapt | M | P2 |
| 4 | Skill reachability CI gate (`check-resolvable` analog) | adapt | S | P2 |
| 5 | Skillopt loop for extraction prompts | adapt | XL | P3 |
| 6 | Thin-harness audit: move judgment prose out of Swift constants into SKILL.md | inspire-only | S | P3 |

**deliberate-exclusion**: skillpack registry / TOFU / harvest marketplace — we are
single-operator; the distribution machinery is pure overhead.

---

## 10. Deliberate non-ports

Explicitly **do not build** these — each fights our architecture or our scope:

- **`pg_advisory_xact_lock` / `SELECT … FOR UPDATE SKIP LOCKED` TOCTOU machinery.**
  `MemoryStore` is a single-writer actor; the actor *is* the serialization. (The
  one exception is the **cross-process** `cycle_lock` — see §11.)
- **The full Resolver/`FailImproveLoop` registry, now.** Premature abstraction
  until ≥3 external lookups share a confidence/cost envelope.
- **`url_reachable` DNS-rebinding resolver.** `EgressGuard`+`PinnedFetcher`
  already exceed it.
- **Schema-pack manifest cathedral / per-source federation / 11-verb CLI.** Our
  additive `CREATE TABLE IF NOT EXISTS` discipline + a closed enum is the right
  altitude for a single, author-fixed ontology.
- **Unix-socket resolve-IPC bridge.** No single-connection lock to work around.
- **Skillpack registry / TOFU / harvest.** Single-operator; no marketplace.
- **Markdown-fence forget round-trip.** SQLite *is* our system of record (not
  markdown), so forget is a soft-delete tombstone column, not a fence rewrite.

---

## 11. Critique-driven corrections (honest gaps)

The adversarial review surfaced gaps in the recommendations themselves. Folded in:

1. **mem0 multi-tenant isolation → P1 (was omitted).** `matchesFilters` is a
   post-fetch in-memory predicate, not a SQL `WHERE` scope. A filter-construction
   bug leaks cross-tenant memories. This is a security/correctness item, ranked
   above several P1 quality items. (Added as Wave 0.6.)
2. **`informationGain` is permanently 0.** `logprob` is a `log2(tokenCount)` /
   hash stub on both backends. Any persona that activates `Scorer` with a 4-signal
   blend silently mis-normalizes. **Set `weightInformationGain = 0`** (or drop the
   term) until a real perplexity path exists.
3. **Cross-process cycle lock is real work the actor cannot do.** The actor
   serializes *in-process*; the `cycle_lock` table is specifically for CLI-vs-daemon
   mutual exclusion. State both plainly; don't conflate them.
4. **AIMD adaptive concurrency cap** for the MLX lane is omitted — *adapt the
   existing* `BoundedInferenceProvider` fixed caps. (Added as Wave 8.1.8.)
5. **Search telemetry/tune loop** is a hard dependency of the mode-bundles rec,
   not an optional extra — adding ~10 knobs with no measurement violates the
   plan's own discipline.
6. **`Mem0HTTPServer` admission control** — one detached task per connection,
   uncapped; reuse `BoundedChannel`. (Added as Wave 8.1.9.)
7. **Entity-store deletion propagation** — promote from a buried sub-bullet to a
   standalone correctness fix (stale `linked_memory_ids` surface deleted memories).
8. **Don't re-port what exists**: `BenchKit.wilson(success:n:z:)` (use it),
   `BoundedChannel` (HTTP/ingress admission), `BoundedInferenceProvider` (extend,
   don't rebuild), `WikiFreshness` decay curve (reuse).
9. **Dual-backend schema parity**: schema added only to the sqlite `MemoryStore`
   (wiki layer) is single-backend and safe; anything touching the **mem0** store
   (`Mem0SQLiteStore`/`Mem0PgVectorStore`) must land in *both* backends per the
   lockstep rule, or be sqlite-vec-gated.
10. **Sequencing**: the at-write contradiction check needs the extractor to emit
    `.opposes`/`.nuances` stances first (today always `.supports`); the facts
    "stale high-conviction" detector is a no-op until real claim confidence exists
    (gate behind the three-bucket policy).
11. **Also unaddressed-but-noted**: mem0's wired-but-dead per-entity `summary`
    field; cross-store migration / export-to-jsonl tooling.

---

## 12. Risk register & verification

| Risk | Where | Mitigation |
|---|---|---|
| `SessionEngine.swift` window edit (upstream-tracked, delicate per-turn ordering) | Wave 4.27 | smallest possible diff; append in the `LatestAssistantOutput` teardown block; test "turn N+1 window includes turn N assistant reply"; the riskiest edit — schedule alone |
| Graph-boost N+1 on the single-writer actor search path | Wave 2.15 | **batch entity fetch is mandatory**, not optional; benchmark p99 under load before enabling |
| `Cron` promotion touches a live, owner-gated, codex-rs-adjacent path | Wave 8.1.6 | land *after* the job substrate is independently proven; keep `.never/.readOnly/no-network` SessionConfig a hard-gated regression test |
| Auto-supersession mutating claims | Wave 3.23 | opt-in env flag + ≥0.8 confidence; mid-confidence → review queue; adversarial "low-confidence must not mutate" test |
| Unbounded autonomous spend | Waves 0/1 | per-cycle `SpendGate`; budget-exhausted = `ok+partial`; `spend` ledger reconciles to ±$0.01 |
| Dual-backend drift | mem0 schema changes | parity check or sqlite-vec gate (§11.9) |

**Verification discipline** (mirrors gbrain's): every pure function gets a
unit test (rubric weight-sum traps, Brier fixtures, quiet-hours midnight-wrap,
intent classification, salience formula); every wired primitive gets an
integration test proving the dead path now fires (SpendGate stops at ceiling;
WikiWriteGate rolls back an ungrounded page; consolidate produces SUPERSEDE
history); crash-safety tests for the job store + cycle lock (kill mid-claim →
`sweepStalled` reclaims); and the existing `Tests/LiveTests` OPENAI-gated suite
for the end-to-end agent behaviors (volunteered page opened, not hallucinated).

---

## 13. The one-paragraph recommendation

Do **Wave 0** first and almost nothing else matters yet: wiring `SpendGate`,
`WikiLinkLinter`, the mem0 update pass, the three-bucket confidence policy, the
context sanitizer, and mem0 tenant scoping is a few weeks of low-risk work that
closes every open *safety* hole and turns ~40% of gbrain's value on with code we
already wrote and tested. Then **Wave 1** (the dream cycle + durable job queue)
gives the system the autonomous-maintenance spine it currently lacks. Everything
after that — graph retrieval, contradiction auto-supersession, calibration,
push context, code-intel — is genuine new capability, ported from a system that
already proved it works, adapted honestly to our Swift-actor / SQLite / MLX
reality, and explicitly declining the parts of gbrain that were only ever there
to cope with multi-process Postgres and a markdown system of record.
