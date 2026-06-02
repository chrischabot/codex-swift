import Foundation
import Tools
import Config

// ADDONS.md Phase 0 #2: the tool-pack → ToolRouter composition seam.
//
// Before this, a worker's tool set was wired either by the hardcoded
// `DefaultTools.register(on:...)` or by feature-specific special-cases
// (the memory provider's `tools()`, the workflows deferred tool). There was no
// GENERIC path for an addon (#4 Google Workspace, #7 Push, #8 Media) to
// contribute advertised tools at the composition root — `ToolPack` existed as a
// protocol but nothing registered an arbitrary pack. This registry is that
// path: the composition root builds `[any ToolPack]` (each constructed with its
// runtime deps) and calls `install`, which registers every ENABLED pack's
// `tools()` into the `ToolRouter` after running its `install()` side-wiring.
//
// Scope: this is for ADVERTISED tools (`ToolRouter.register`). Trigger-gated /
// deferred tools (the `workflow` tool) keep their own `registerDeferred` path —
// routing them here would advertise them unconditionally and break the
// keyword-opt-in UX. Packs are expected to SELF-PRUNE (`tools()` returns `[]`
// when their backend isn't configured), so gating here is a coarse feature
// switch, not the fine-grained "is this capability available" decision.

/// Registers a set of `ToolPack`s' tools into a `ToolRouter` at the composition
/// root. Construct with the packs (built with their deps); call `install` with
/// a gate that decides per-pack inclusion.
///
/// Two-stage availability model (document this for pack authors):
/// 1. The `gate` is the COARSE switch — a pack whose `id` fails the gate is
///    skipped entirely (its `install()` does NOT run). The gate is supplied by
///    the caller, so a pack can be gated by a `[features].<id>` flag (the
///    `install(on:config:)` convenience) OR by any other signal — e.g. #4 may
///    gate on "is `[connectors.google]` configured" rather than a separate flag.
/// 2. SELF-PRUNE is the FINE switch — a gated-ON pack's `tools()` returns `[]`
///    when its backend isn't actually usable (no granted scope / no key). Since
///    `install()` runs for ANY gated-on pack regardless of `tools()` emptiness,
///    put the "is my backend configured" early-return in `install()` too (not
///    only in `tools()`) so side-wiring is skipped when unused.
public struct ToolPackRegistry: Sendable {
    private let packs: [any ToolPack]

    public init(_ packs: [any ToolPack]) { self.packs = packs }

    /// Register every pack whose `id` passes `gate`. For each included pack:
    /// run `install()` (bus/provider side-wiring) FIRST, then register its
    /// `tools()`.
    ///
    /// COLLISIONS: a pack tool whose name already exists in the router (a
    /// built-in, an MCP tool, the deferred `workflow` tool, or an earlier pack's
    /// tool) is SKIPPED with a stderr warning — first registration wins. This
    /// prevents a pack from silently shadowing `apply_patch`/`memory`/etc.
    /// (`ToolRouter.register` is last-writer-wins by name). So the registry MUST
    /// run AFTER the built-ins are registered (it does — see the composition
    /// roots), and pack authors must avoid built-in names (e.g. #7 uses
    /// `push_send`, not the already-taken `send_message`).
    ///
    /// Duplicate pack ids install once (first enabled occurrence wins). Gated-off
    /// packs never consume their id, so a later same-id enabled pack can install.
    ///
    /// - Returns: the ids actually installed (gate passed + `install()` ran), in
    ///   order — even if a pack contributed zero tools (self-pruned). For tests
    ///   / composition-root logging.
    @discardableResult
    public func install(on router: ToolRouter,
                        gate: @Sendable (String) -> Bool) async -> [String] {
        var installed: [String] = []
        var seenPackIds = Set<String>()
        var taken = await router.knownToolNames()   // built-ins / MCP / earlier packs
        for pack in packs {
            guard gate(pack.id) else { continue }
            guard seenPackIds.insert(pack.id).inserted else { continue }   // dedupe enabled ids (first wins)
            await pack.install()
            for tool in pack.tools() {
                guard taken.insert(tool.name).inserted else {
                    // Name already taken — do NOT overwrite the existing handler.
                    FileHandle.standardError.write(Data(
                        "ToolPackRegistry: pack '\(pack.id)' tool '\(tool.name)' collides with an existing tool; skipped (first registration wins)\n".utf8))
                    continue
                }
                await router.register(tool)
            }
            installed.append(pack.id)
        }
        return installed
    }

    /// Standard composition-root wiring: gate each pack by
    /// `config.isFeatureEnabled(pack.id)` (opt-in / deny-default, matching every
    /// other `[features].<id>` switch). A pack ships ON only when configured.
    @discardableResult
    public func install(on router: ToolRouter, config: Config) async -> [String] {
        await install(on: router) { config.isFeatureEnabled($0) }
    }
}
