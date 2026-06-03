# Addons & Plugins

*How codex-swift turns a hardened agent daemon into an extensible one: a thin set of plug-in surfaces and a single composition root, so a new capability is one file — not a fork.*

## Why it matters

You have a capable agent. Now you want it to do something the base doesn't ship: read your Google Drive, reply to you on Telegram, run a job every morning, push a notification when a long task finishes. The naive way is to reach into the core — edit the prompt composer, special-case the tool router, touch `main.swift` in five places. Do that a few times and two things break: the core stops tracking upstream codex-rs (so every merge is a fight), and each new feature is a sprawling, risky diff.

codex-swift's addon model exists so that *adding a capability never touches the core*. The base layer — the multi-process daemon, the Responses client, the sandbox, the approval engine, durable persistence — stays codex-rs-faithful and pristine. Everything you add attaches through a **seam** that already exists, lives in its own folder, and is wired in *one* place. The cardinal rule, from `docs/extensions/BUILDING_EXTENSIONS.md`: if you find yourself editing a prompt template or the tool dispatch loop to add a feature, stop — there is a seam for what you want.

## What it is

A small, disciplined extension layer with a clear philosophy and exactly five plug-in surfaces.

The philosophy is **"reverse the pyramid."** Multi-channel agent platforms like openclaw and hermes are *shells first*: a thin agent core whose identity is the plug surface around it — you bring the channels, the tools, the providers, and the shell routes between them. The base is light so the ecosystem can be heavy. codex-swift is the **inverse**: the base is the heavy, hardened part, and value accretes on top as addons that layer onto seams the core already has. You capture what makes those agents *feel* capable without inheriting their architecture or letting the port drift.

A capability is a **choice of surface** — pick the lightest one that fits:

| Surface | What it gives the agent | Where it attaches |
|---|---|---|
| **Module** (extension/context) | Prompt fragments, per-turn recall, lifecycle hooks, approval review, a tool-dispatch gate | `ExtensionRegistry` contributors (`Sources/ExtensionAPI`), wired by `installAddons` |
| **Skill** / **ToolPack** | A set of model-facing tools | `ToolPack` (`Sources/HarnessCore/ToolPack.swift`) → `ToolRouter` via `ToolPackRegistry` |
| **MCP** | An *external, untrusted, third-party* tool surface, out-of-process | `mcp.json` / `config.toml` → `McpManager.startAll` |
| **Channel** | An inbound↔outbound transport (Telegram, Gmail, …) that turns messages into turns | `Channel`/`ChannelHost` (`Sources/Channels`) |
| **Provider** | A pluggable backend selected by config/keys (e.g. the realtime-voice backend, a local small model) | `ModelClient`/`SmallModel` patterns, gated by `isConfigured` |

The trust line is sharp: **everything we build is native, in-process, trusted; MCP is the boundary for code we did not build** — untrusted by design, isolated, tool-surface only. "Native vs MCP" is not a packaging preference, it tracks "ours vs theirs."

## How it works

Three mechanisms carry almost everything.

**1. The `ExtensionAPI` registry — prompt/context/lifecycle/gate.** `ExtensionRegistry<Config>` (in `Sources/ExtensionAPI/ExtensionAPI.swift`) is a set of typed subscriber lists built through an `ExtensionRegistryBuilder`. A feature registers closures:

- `contextContributor` → `[PromptFragment]` — inject text into *this turn's* prompt (the recall→prompt seam). Fragments carry a `PromptSlot`: `.developer` is **trusted** operator framing; `.contextualUser` is **untrusted/low-authority** (recalled memory, never instructions).
- `turnLifecycle` / `threadLifecycle` / `tokenUsageContributor` — per-turn and per-thread hooks.
- `approvalReviewContributor` — an *optional reviewer* that can approve or deny on the request-approval branches.
- `toolDispatchGateContributor` → a **deny-only gate** consulted in front of *every* tool dispatch.

The engine touches the registry only through `if let registry { … }` guards at ~5 call-sites, so when nothing is installed the hot path is byte-identical to the no-extension baseline. Hot-path contributors run under a strict timeout (`withExtensionTimeout`) and **degrade to empty** — a slow or hung extension slows nothing.

**2. `installAddons` — the one composition root.** `installAddons(config:sessionConfig:memoryProvider:)` in `Sources/HarnessCore/Extensions.swift` is the single place per-session extensions are wired. It is gated behind the `extensions` feature (off by default), parses the `[extensions]` table into cheap `ExtensionManifest` values, builds an `ExtensionRegistry<SessionConfig>`, and returns it (or `nil` when nothing is enabled — keeping the engine baseline-identical). Adding a module-surface feature means appending one `register(into: builder)` call here.

**3. The ToolPack → ToolRouter seam.** A `ToolPack` is just `{ id; tools() -> [any Tool]; install() }`. The injection seam is `ToolPackRegistry` (`Sources/HarnessCore/ToolPackRegistry.swift`): the composition root builds `[any ToolPack]`, then `install(on: router, config:)` registers each *enabled* pack's tools into the `ToolRouter`. Two-stage availability:

- **Coarse gate** — `config.isFeatureEnabled(pack.id)`; a pack that fails is skipped entirely (its `install()` never runs).
- **Self-prune (fine)** — a gated-on pack's `tools()` returns `[]` when its backend isn't usable (no key, no granted scope). Name collisions are skipped with a warning (first registration wins), so a pack can never silently shadow `apply_patch` or `memory`.

```
   one feature folder (Sources/<Feature>/)
            │  registers a contributor / a ToolPack / a Channel
            ▼
   installAddons(...)  ── builds ──►  ExtensionRegistry<SessionConfig>
   ToolPackRegistry(...).install ──►  ToolRouter (tools advertised)
            │                                    │
            └────────────► SessionEngine ◄───────┘   (guarded `if let registry`)
                              core stays codex-rs-pristine
```

### The Phase-0 foundations that make addons safe and reliable

Several addons assumed guarantees the seams didn't yet enforce. The "reverse the pyramid" work is building these load-bearing pieces **once, on the base**, so capabilities that stand on them are safe by construction:

- **Tool-approval / dispatch-gate contract.** The old approval engine only classified shell/apply_patch/computer-use; the channel dispatch-gate could *abstain* for an owner, leaving a confused-deputy path (owner forwards a malicious email → destructive action, no human in the loop). The fix is the `toolDispatchGateContributor` seam: a **deny-only gate** in front of every dispatch (`SessionEngine.toolDispatchGate`, before the approval policy branch). It can only `.deny` or `.abstain` — never grant — so it cannot weaken existing policy, and it **fails closed** (timeout → deny). The channel owner-gate (`installChannelGate` in `Sources/Channels/Channel.swift`) uses it to hard-block a non-owner's privileged verbs regardless of policy.
- **Durable-outbound core (`DeliveryCore`).** A reply or push lost between turn-completion and transport-send (a crash, a restart) is unfixable without a send-intent-before-I/O record. `DurableDeliveryQueue` (`Sources/DeliveryCore/DeliveryCore.swift`) is that record: each state transition (`enqueued → send_attempt_started → {acked | unknown_after_send | failed}`) is fsync'd to a JSONL log *before* the side effect, `recover()` re-drives non-terminal jobs in order (at-least-once; receiver idempotency dedups), and a per-attempt timeout means a hung sink can't wedge the queue. One queue serves both the inbound reply path and outbound push sinks.
- **Egress chokepoint (`EgressGuard`).** Every model-/cron-driven outbound HTTP target is screened *before* the request (`Sources/EgressGuard/EgressGuard.swift`): HTTPS-only, an explicit host allowlist, and — critically — a check of the **resolved IPs**, blocking loopback, RFC1918, link-local incl. the cloud-metadata `169.254.169.254`, CGNAT, and v4-embedded-in-v6 forms. It is connect-*bound*, not just pre-flight: `vet()` returns the vetted IPs the caller must pin (defeating DNS rebinding), and the caller must disable redirect-following. HMAC body-signing is receiver auth, *not* egress control — this is the real SSRF defense.
- **Supervisor turn-collector.** The daemon's `SessionSupervisor.submit` is fire-and-forget; turn output arrives asynchronously through a per-thread `NotificationSink`. `collectTurn(_:input:turnId:timeout:)` (`Sources/Supervisor/SupervisorTurnCollector.swift`) folds that broadcast notification stream into a `CollectedTurn{text,status}`, correlated on `(threadId, turnId)` so two concurrent collects never cross-wire. This is the supervisor-backed analog of `EngineChannelHost.deliver` — the adapter that lets a channel "run one turn and get the reply" against the real multi-session daemon.

## Using it

**Enable the subsystem.** The whole spine is opt-in. Turn it on with `CODEX_FEATURE_EXTENSIONS=1` or `[features].extensions = true` in `config.toml`. With it off, `installAddons` returns `nil` and the engine is byte-identical to stock.

**Add a capability as one file.** The full worked example from `BUILDING_EXTENSIONS.md` — a context module that injects project facts every turn:

```swift
// Sources/HarnessCore/... or your own Sources/<Feature>/
import ExtensionAPI
import ProtocolModel

public func registerProjectFacts(_ facts: String,
                                 into b: ExtensionRegistryBuilder<SessionConfig>) {
    b.contextContributor { _, _ in
        facts.isEmpty ? [] : [PromptFragment(slot: .developer, text: "Project facts:\n\(facts)")]
    }
}
```

Wire it with one line in `installAddons`, behind config; that's the whole change. The checklist for any new surface:

1. Put code in `Sources/<Feature>/` (a new target) or extend HarnessCore for spine-adjacent helpers.
2. Add the target to `Package.swift` (+ a `<Feature>Tests` target).
3. Declare an `ExtensionManifest` (`id`, `displayName`, `capabilities`, optional `slot`) — cheap metadata readable without running the feature.
4. Gate behind the `extensions` feature **plus** your own `[features].<id>`/`[extensions]` config; default **off / opt-in**.
5. Wire in `installAddons` (modules) and/or register a `ToolPack` via `ToolPackRegistry` at the composition root (`Sources/codexd/main.swift`, `Sources/codex-session/main.swift`). Adding a feature should touch that wiring **plus your folder, nothing else.**

**Contributing tools** is a `ToolPack`. The reference is `WorkflowsToolPack` (`ToolPack.swift`) — it advertises its four workflow tools for manifest fidelity. At the composition root, packs go in the `toolPacks` array and `ToolPackRegistry(toolPacks).install(on: router, config: addonConfig)` registers them — run *after* the built-ins so a pack can never overwrite one. Avoid built-in names (e.g. the push addon must use `push_send`, not the already-taken `send_message`).

**Build/test hazards** worth knowing up front: never run bare `swift test` (it runs the ~41 `OPENAI_API_KEY`-gated live tests); always `swift test --filter <YourTests>`. Never build/test the same checkout from parallel agents — SwiftPM's `.build` lock serializes them and a hung run wedges the rest. Build your target directly with `swift build --target <Feature>` if the daemon targets fail from unrelated WIP.

## What it enables

The five surfaces compose into the addon portfolio in `ADDONS.md`: a Channels framework and Telegram/Gmail channels, a native Google OAuth connector and a discovery-driven Workspace tool suite, a cron scheduler, an outbound push primitive, and a generative/inbound media suite. Each is "a choice of surface, not an invitation to edit the core," and each stands on the Phase-0 foundations: channels and cron on the **turn-collector** and **durable-outbound core**; push/cron/media/Google on the **egress chokepoint**; every channel- and cron-originated turn on the **tool-dispatch gate**.

Because the base stays codex-rs-faithful, upstream merges stay cheap while your capabilities accrete on top — and because each addon is one folder behind one wired seam, a feature is something one engineer ships in a file, not a fork you maintain forever.

Related pages: the existing memory and persona modules (`Sources/HarnessCore/MemoryProvider.swift`, `Persona.swift`) are reference `ExtensionRegistry` consumers; the Workflows feature is the reference `ToolPack` + bus; the realtime-voice backend (`Sources/Supervisor/RealtimeBackend.swift`) is the reference *provider* surface.

## Status

The extension **spine** is implemented and live (Phases 0–4 of the architecture doc: `ExtensionAPI` activated, `installAddons`, `ToolPack`/`ToolPackRegistry`, `MemoryProvider` slot, `Channel`/`ChannelHost` contracts, the four named Phase-0 foundations). What is **planned/partial**: the eight-addon portfolio in `ADDONS.md` is largely design + foundations — the `Connectors` module is still a 63-line discovery stub (no OAuth yet), no `Channel` is wired into the daemon (`toolPacks` is currently an empty array at both composition roots), and the production `SupervisorChannelHost`/`ChannelManager` are not yet built on top of `collectTurn`. Treat `ADDONS.md` as the roadmap and the seams above as the shipped, tested base they attach to.

## Go deeper

Internals, locked decisions, the core delta, and per-phase status/deferrals: `docs/extensions/ARCHITECTURE.md` (the "how to add one" companion is `docs/extensions/BUILDING_EXTENSIONS.md`; the capability roadmap is `ADDONS.md`).
