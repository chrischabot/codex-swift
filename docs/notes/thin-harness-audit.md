# Thin-harness audit (gbrain.md §9.6 #6, inspire-only)

> **Status:** advisory. gbrain's "thin-harness / fat-skills" principle says *judgment
> belongs in editable markdown skills, not compiled Swift string constants*. This is
> an `inspire-only` item — a direction to bias toward, not a refactor to land wholesale.
> The measurement foundation that makes such a move *safe* now exists (the held-out
> [`SkillScorer`](../../Sources/BenchKit/SkillScorer.swift), the
> [skill-score CLI](../../Sources/codex-bench/main.swift) regression gate, the
> [skillopt loop](../../Sources/BenchKit/Skillopt.swift), and the per-prompt
> [version-stamp gates](../../Tests/MemoryInferTests/PromptVersionGateTests.swift)).

## The principle

A **thin harness** carries control flow, budgets, I/O, and safety rails in code; the
**fat skill** carries the *judgment* — the instructions, rubrics, and worked examples
— in markdown a human can edit without a rebuild. The payoff:

- **Iterate without recompiling.** A prompt tweak is a markdown edit + a re-score, not
  a Swift change + a full build + a release.
- **Reviewability.** Judgment prose in `SKILL.md` reads as prose; the same text inside
  a `#"""…"""#` Swift literal is invisible to non-engineers and easy to break (escapes,
  interpolation, indentation).
- **Versioning is natural.** A markdown skill has a path + frontmatter; the scorer can
  stamp a receipt with its `tier` and content hash.

## Where judgment currently lives in Swift constants

These are the high-value "fat-skill in a Swift literal" sites today (now each
version-stamped + gated, so any drift is a reviewed event):

| Prompt (judgment text) | Location | Notes |
|---|---|---|
| `additiveExtractionPrompt` | `Sources/Mem0Core/Prompts+Constants.swift` | **Generated** from mem0-rs — leave generated; the gate pins its hash so an upstream regen is visible. |
| `defaultUpdateMemoryPrompt` | `Sources/Mem0Core/Prompts+Constants.swift` | Generated; the ADD/UPDATE/DELETE decision rubric. Pinned. |
| `ExtractionPrompt.render` | `Sources/MemoryInfer/RemoteOpenAICompatibleProvider.swift` | Entity/edge extraction instructions, hand-written. `promptVersion = extract-graph-v1`. |
| `ContextualisePrompt.render` | `Sources/MemoryInfer/RemoteOpenAICompatibleProvider.swift` | The "situate this chunk" instruction. `promptVersion = contextualise-v1`. |
| `WikiClaimExtractor.systemPrompt` | `Sources/codex-memory/LiveResearchPorts.swift` | Atomic-claim extraction rubric. `promptVersion = wiki-claim-v1`. |
| `proceduralMemorySystemPrompt`, `memoryAnswerPrompt` | `Sources/Mem0Core/Prompts+Constants.swift` | Generated; not yet stamped (lower traffic). |

The `ContradictionJudge` / `SkillRuleJudge` / research prompts are similar candidates.

## Recommendation (bias, not mandate)

1. **Keep generated mem0 prompts in Swift.** They are a faithful port of upstream and
   must track it; the *gate* (hash pin) is the right control, not extraction to markdown.
   Moving them would fork from upstream and break the regen workflow.
2. **For hand-authored, frequently-tuned prompts** (`ExtractionPrompt`,
   `ContextualisePrompt`, `WikiClaimExtractor.systemPrompt`): when the next change is
   needed, prefer moving the *instruction scaffold* into a `SKILL.md` (frontmatter
   `tier:` + body) loaded at startup, leaving only the dynamic interpolation
   (`schema.allowedEntityKinds`, `maxClaims`, sanitized inputs) in Swift. The
   `promptVersion` constant becomes the skill's content hash; the scorer already
   accepts it.
3. **Gate every such move with the harness.** Before/after: capture a baseline receipt
   (`codex-bench skill-score --out baseline.json`), make the change, re-score with
   `--baseline baseline.json`. A non-regressing move is safe to land; a regression
   exits 3 and blocks it. Use `skillopt` to *propose* the markdown rewrite and keep only
   a held-out-validated winner.
4. **Do NOT** build a skill marketplace / registry / TOFU distribution (gbrain's
   explicit non-port — single-operator, no marketplace). The thin-harness move is about
   *locality of judgment*, not distribution machinery.

## Why this is safe now (and wasn't before)

Before this milestone, "move the prompt to markdown" was a vibes-based edit with no
safety net. Now there is a closed loop: **stamp** (version + hash gate) → **score**
(rule/llm/qrels over held-out cases) → **gate** (regression exit code) → **optimize**
(skillopt with a held-out anti-overfit gate). Any judgment relocation can be proven
non-regressing before it ships. That measurement-first foundation was the actual
prerequisite; the markdown relocation is incremental and can happen prompt-by-prompt
on demand.
