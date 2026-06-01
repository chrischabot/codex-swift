import Foundation
import ProtocolModel
import ExtensionAPI

// Phase 4 (docs/extensions/ARCHITECTURE.md §7.3 / use-case table): an agent
// "persona" as pure composition on the extension spine. The fashion agent =
// this persona contributor + a ToolPack + a Channel — no new core surface.
//
// Unlike recalled memory (UNTRUSTED → low-authority, fenced), a persona is
// OPERATOR configuration (TRUSTED), so it is injected at `.developer` authority.

/// Register a trusted persona that frames every turn (e.g. "You are Vesper, a
/// concise fashion advisor…").
public func registerPersona(name: String, instructions: String,
                            into builder: ExtensionRegistryBuilder<SessionConfig>) {
    let text = "You are \(name). \(instructions)"
    builder.contextContributor { _, _ in [PromptFragment(slot: .developer, text: text)] }
}
