import Foundation
import EgressGuard

public extension PushRouter {
    /// Composition-root convenience: a router wired with the default ntfy +
    /// webhook sinks behind the #5 egress chokepoint (HTTPS-only, public-host,
    /// IP-block), with any crash-pending deliveries recovered. `codexd` calls
    /// this when `[features].push` is enabled.
    static func makeDefault(directory: String, ntfyBase: String = "https://ntfy.sh") async -> PushRouter {
        let egress = EgressGuard(EgressPolicy())
        let http = URLSessionPushHTTPClient()
        let router = PushRouter(directory: directory)
        await router.register(scheme: "ntfy", sink: NtfySink(baseURL: ntfyBase, egress: egress, http: http))
        await router.register(scheme: "webhook", sink: WebhookSink(egress: egress, http: http))
        await router.recover()
        return router
    }
}
