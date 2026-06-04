import Foundation
import HarnessCore
import Tools

/// ADDONS Phase 0 #2 seam for #7: contributes `push_send` to the router at the
/// composition root. Gated by `[features].push`; self-prunes (no tools) until a
/// router is wired, so an unconfigured daemon advertises nothing.
public struct PushToolPack: ToolPack {
    public let id = "push"
    private let router: PushRouter?
    private let allowedTargets: Set<String>?

    public init(router: PushRouter?, allowedTargets: Set<String>? = nil) {
        self.router = router
        self.allowedTargets = allowedTargets
    }

    public func tools() -> [any Tool] {
        guard let router else { return [] }   // self-prune when the backend isn't configured
        return [PushSendTool(router: router, allowedTargets: allowedTargets)]
    }
}
