import Foundation
import Tools

// Phase 2 of the extension layer (docs/extensions/ARCHITECTURE.md §7.2): the
// `ToolPack` contract — a feature that contributes a set of agent tools, with
// optional bus/provider wiring. This is the "additive tools" extension shape
// (distinct from the exclusive `MemoryProvider` slot). The existing Workflows
// feature is reclassified as a `ToolPack` (`WorkflowsToolPack`) — it was already
// an extension in spirit (deferred tools + the `WorkflowBus` install seam); this
// just gives it the formal contract + manifest without disturbing its working
// composition-root wiring.

/// A feature that contributes agent tools. `install()` optionally wires any
/// bus/provider the tools delegate to (default no-op for pure tool packs).
public protocol ToolPack: Sendable {
    /// Stable id; also the `[features]`/`[extensions]` gate key.
    var id: String { get }
    /// The agent tools this pack contributes.
    func tools() -> [any Tool]
    /// Optional runtime wiring (e.g. installing a `*Bus` provider). Pure tool
    /// packs leave this as the default no-op.
    func install() async
}

public extension ToolPack {
    func install() async {}
}

/// Workflows reclassified as a `ToolPack` (Phase 2). `tools()` is the canonical
/// workflow tool surface; the heavy orchestrator is still wired at the
/// composition root via `WorkflowOrchestrator.installOnBus()` (it needs runtime
/// deps — a subagent runner + store — that a stateless ToolPack can't own), so
/// `install()` stays the default no-op. This documents the boundary: a
/// bus-backed feature = a ToolPack (its tool surface) + a host-installed bus
/// provider (its backing), exactly the `WorkflowBus`/`MultiAgentBus` pattern.
public struct WorkflowsToolPack: ToolPack, Sendable {
    public let id = "workflows"
    public init() {}
    /// NOTE: do NOT route this pack through `ToolPackRegistry`. That seam
    /// `register`s (advertises) every returned tool, but the real composition
    /// root wires `WorkflowTool` via `registerDeferred` — it stays hidden until
    /// the `/workflow` command or the "workflow" trigger word activates it
    /// (keyword opt-in). `tools()` lists all four for manifest/introspection
    /// fidelity; the deferred/advertised split is the composition root's job.
    public func tools() -> [any Tool] {
        [WorkflowTool(), WorkflowStopTool(), WorkflowListTool(), WorkflowStatusTool()]
    }
    /// Cheap, declarable manifest (principle 4 / lesson L6) for the
    /// `[extensions]` table + future settings UI.
    public static let manifest = ExtensionManifest(
        id: "workflows", displayName: "Workflows",
        capabilities: ["tools"], slot: nil, enabled: true)
}
