# Building extensions for codex-swift

*A practical guide for agents (and humans) adding features on top of the
codex-rs Swift port. Read `ARCHITECTURE.md` in this folder first for the "why";
this doc is the "how".*

---

## 0. The one rule

**The codex-rs core stays codex-rs.** Do not edit the bodies of the files that
track upstream — `PromptComposer`, `Templates`, `ContextManager` projection,
`ModelClient`, the `ToolRouter`/tool bodies, the wire-model types. Features
attach through *seams*. The only allowed core change is an additive, **guarded**
call-site (`if let registry { … }`) that is byte-identical when the feature is
absent — exactly how the existing `hooks` and `registry` fields work. This is
what keeps upstream merges cheap; breaking it is the cardinal sin.

If you find yourself editing a prompt template or the tool dispatch loop to add
a feature, stop — there is a seam for what you want (§2).

---

## 1. Where everything lives

| You contribute… | Use | Defined in | Wired at |
|---|---|---|---|
| Prompt/context, per-turn recall, lifecycle, approvals | `ExtensionRegistry` contributors | `Sources/ExtensionAPI` | `installAddons` → `SessionEngine(registry:)` |
| Swappable memory (one active) | `MemoryProvider` slot | `Sources/HarnessCore/MemoryProvider.swift` | `selectMemoryProvider` + `installAddons(memoryProvider:)` |
| A set of agent tools | `ToolPack` (or a `*Bus`) | `Sources/HarnessCore/ToolPack.swift` | composition root registers `tools()` on the router |
| Tool backed by host logic | `*Bus` + `installOnBus()` | `Sources/InfraPrimitives/*Bus.swift` | host installs the provider |
| Cheap local-LLM sub-tasks | `SmallModelService` | `Sources/SmallModel` | extension owns it; never the agent loop |
| Inbound/outbound messaging | `Channel`/`ChannelHost` | `Sources/Channels` | a transport drives `host.deliver` |
| An external, third-party, or untrusted capability | **MCP server** | `mcp.json` / `config.toml` | `McpManager.startAll` |
| Shell-out automation on lifecycle events | `HookEngine` (process hooks) | `Sources/HarnessCore/Hooks.swift` | `HookEngine.load` |

**Trust:** everything we build is **native + in-process + trusted**. MCP is the
boundary for **external services we did not build** (untrusted, isolated). Never
ship a first-party feature as MCP, and never run untrusted code in-process.

---

## 2. The seams, and when to reach for each

### 2.1 `ExtensionRegistry` — prompt / context / lifecycle / approvals
The spine (`ExtensionAPI`). A feature registers closures on an
`ExtensionRegistryBuilder<SessionConfig>`; `installAddons` builds the registry
and the engine invokes it at guarded call-sites.

- **`contextContributor { sessionStore, threadStore async -> [PromptFragment] }`** —
  inject text into *this turn's* prompt. The seam for memory recall, personas,
  project context. Runs under the **D6 timeout** (degrade-to-empty on slow/hang).
  It does **not** receive the turn text — read it from `threadStore.get(LatestUserInput.self)` (the engine stashes it).
- **`turnLifecycle(onStart/onStop/onAbort:)`** — per-turn hooks (e.g. capture).
- **`threadLifecycle`, `tokenUsageContributor`, `approvalReviewContributor`** — as named.

`PromptFragment.slot`: `.developer` = **trusted** operator framing (persona,
authority). `.contextualUser` = **untrusted/low-authority** (recalled memory).
**Never put untrusted content at `.developer`.**

### 2.2 `MemoryProvider` — the swappable memory slot
One provider active per session, chosen by `[memory].provider` (explicit
opt-in). Implement `recall`/`capture`/`tools`/`status`; wire with
`registerMemory(provider, into: builder)` (recall→fenced contextContributor,
capture→onStop). Existing impls: `CoreMemoriesProvider` (`.md` files, keyword
recall), `WikiMemoryProvider` (vector retriever). A new backend (RAG, mem0, …) =
a new `MemoryProvider`, registered as a candidate, selected by config.

### 2.3 `ToolPack` / `*Bus` — agent tools
- Pure tools → a `ToolPack` (`id` + `tools()`); register at the composition root.
- Tools that need host logic the `Tools` module can't own → a `*Bus` actor
  singleton in `InfraPrimitives` (installable provider closures) + a value-type
  `Tool` in `Tools` that calls `Bus.shared.op()`. Templates: `WorkflowBus`,
  `MultiAgentBus`. The host installs the provider; `Tools` stays core.

### 2.4 `SmallModelService` — the local-LLM utility
For cheap, frequent classification/labeling/scoring/routing. `json<T: Decodable>`
(Decodable *is* the schema; decode-or-retry) and `text`. Backed by any
`ModelClient` pointed at a local endpoint. **Addon-only — never wire it into the
agent loop.** "Escalation" = the extension spawns a real codex turn/subagent.

### 2.5 `Channel` / `ChannelHost` — messaging
Inbound external message → `InboundMessage` (identity **server-stamped** from the
authenticated transport id, never from message content; text **untrusted**) →
`host.deliver` runs a turn and returns `ChannelReply{text,status}`.
`EngineChannelHost` is the embeddable path; production wraps `SessionSupervisor`.
Consume `senderIsOwner` via `registerChannelAuthority` (a trusted authority
fragment) so privileged actions can be gated on it.

### 2.6 MCP — external/untrusted/tool-only
If the capability is an existing external service, or you want process isolation,
ship/consume it as an MCP server. MCP can contribute **tools only** — no prompt
fragments, lifecycle, or channel I/O.

### 2.7 `HookEngine` — process hooks
The existing codex hooks (`preToolUse`/`postToolUse`/`sessionStart`/`stop`/…)
exec external commands. Use for user shell automation, not in-process logic
(prefer 2.1 for native features).

---

## 3. Wiring a new extension

1. Put code in `Sources/<Feature>/` (a new target) or extend HarnessCore for
   spine-adjacent helpers.
2. Add a target to `Package.swift` (+ a `<Feature>Tests` target).
3. Declare an `ExtensionManifest` (id, displayName, capabilities, optional slot)
   — cheap metadata readable without running code.
4. Gate behind the `extensions` feature (`Config.isFeatureEnabled("extensions")`)
   plus your own `[extensions]`/`[<feature>]` config; default **off / opt-in**.
5. Wire in `installAddons` (HarnessCore/Extensions.swift) and/or the composition
   root (`Sources/codex-session/main.swift` + `Sources/codexd/main.swift`).
   **Adding a feature should touch `installAddons` + your folder, nothing else.**

---

## 4. Best practices (this project)

- **Guard every core seam.** `if let registry { … }`; nil ⇒ byte-identical. Add
  a test that no-registry output equals the baseline.
- **Degrade, never crash, on the hot path (D6).** Anything on the turn path
  (recall, contributors) runs under a strict timeout and returns empty on
  failure. Contributors that block/hang/loop must not stall the turn — the
  engine's `withExtensionTimeout` bounds them, but don't rely on cooperation.
- **Untrusted by default at boundaries.** Recalled memory and inbound channel
  text are untrusted: fence + escape (incl. newlines) recalled memory; keep it
  at `.contextualUser`; server-stamp channel identity; never let content forge
  authority.
- **Explicit opt-in.** Features default off. Don't auto-activate just because the
  `extensions` feature is on.
- **Reuse, one source of truth.** No third copy of SHA-256, no parallel config
  loaders. Adding a provider/tool touches one registry, not N files (the hermes
  "16-file built-in path" is the anti-pattern).
- **Manifest = cheap metadata.** Identity/config/capabilities decodable without
  importing the feature, so gating/validation/UI don't boot anything.
- **Self-bound async.** Off-thread best-effort work (capture) must self-bound and
  swallow errors; never block teardown.

---

## 5. Testing (this project)

- **Deterministic first.** Use `MockModelClient` (scenarios consumed FIFO; `.hello(text)`)
  — no network. Drive a `SessionEngine` with your registry; assert via
  `store.reconstruct(tid)` + context items. See `Tests/HarnessCoreTests/ExtensionsTests.swift`,
  `Tests/ChannelsTests`, `Tests/SmallModelTests` for patterns. Actors for thread-safe
  test doubles (NSLock is banned in `async`).
- **Adversarial review.** Before declaring done, have a skeptic try to refute it
  (cross-turn leaks, injection past fences, concurrency, byte-neutrality). These
  catch what green unit tests mask.
- **Live E2E (gated).** `Tests/LiveTests` with `try lxSkipUnlessLiveKey()` +
  `lxClient()`/`lxModel()`/`lxStore()`/`lxCollect()`. Prove the boundary with a
  real model in ONE focused, bounded turn.

### ⚠️ Build/test hazard — read this
- **Never run bare `swift test`** — it runs the ~41 `OPENAI_API_KEY`-gated live
  tests (real API calls, ~10 min) and can orphan a process. Always
  `swift test --filter <YourTests>`.
- **Never build/test the same checkout from parallel agents** — SwiftPM's
  `.build` lock serializes them and a hung/long run wedges the rest. Builds are
  single-lane. (Parallel agents are fine for *read-only* review.)
- The full daemon build (`codexd`/`codex-session`) pulls `Supervisor`; if those
  fail to compile from unrelated WIP, build your target directly
  (`swift build --target <Feature>`) and run `--filter`ed tests.

---

## 6. Worked example — a minimal "project facts" context extension

```swift
// Sources/HarnessCore/MemoryProvider.swift shows the full pattern; minimal:
import ExtensionAPI
import ProtocolModel

public func registerProjectFacts(_ facts: String,
                                 into b: ExtensionRegistryBuilder<SessionConfig>) {
    b.contextContributor { _, _ in
        facts.isEmpty ? [] : [PromptFragment(slot: .developer, text: "Project facts:\n\(facts)")]
    }
}
```
Wire it in `installAddons` behind config; test it with a `MockModelClient` turn
asserting the fragment reaches history; add a live test that the model uses a
fact. Done — zero core edits.

---

## 7. Reference (real types/files)

- Spine: `Sources/ExtensionAPI/ExtensionAPI.swift`, `Sources/HarnessCore/Extensions.swift` (`installAddons`, `ExtensionManifest`)
- Memory: `Sources/HarnessCore/MemoryProvider.swift`, `Sources/MemoryExtension/WikiMemoryProvider.swift`
- Tools: `Sources/HarnessCore/ToolPack.swift`, `Sources/InfraPrimitives/WorkflowBus.swift` (bus template)
- SmallModel: `Sources/SmallModel/SmallModel.swift`
- Channels: `Sources/Channels/Channel.swift`, `Sources/HarnessCore/Persona.swift`
- Engine seams: `Sources/HarnessCore/SessionEngine.swift` (`registry`, `withExtensionTimeout`, the guarded call-sites)
- Composition root: `Sources/codex-session/main.swift`, `Sources/codexd/main.swift`
- Design rationale + per-phase status/deferrals: `docs/extensions/ARCHITECTURE.md`
