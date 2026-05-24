import Foundation
import IPC
import ProtocolModel

/// Generic worker-side bridge for server→client requests that need structured
/// JSON responses, such as MCP elicitation. Approval decisions still use the
/// narrower `ApprovalCoordinator` API; this broker preserves arbitrary result
/// payloads and lets `WorkerRuntime` resolve them from client JSON-RPC
/// responses on the same correlated request-id path.
public actor WorkerServerRequestBroker {
    private let timeout: Duration
    private var pending: [String: CheckedContinuation<WorkerServerResponse, Never>] = [:]

    public init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

    public func request(_ request: ServerRequest, link: WorkerLink) async -> WorkerServerResponse {
        let requestId = request.id.description
        let timeout = self.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(WorkerServerResponse(requestId: requestId,
                                                     result: nil,
                                                     failed: true))
        }
        let response = await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkerServerResponse, Never>) in
            pending[requestId] = continuation
            link.sendToSupervisor(.serverRequest(request))
        }
        timeoutTask.cancel()
        return response
    }

    @discardableResult
    public func resolve(_ response: WorkerServerResponse) -> Bool {
        guard let continuation = pending.removeValue(forKey: response.requestId) else {
            return false
        }
        continuation.resume(returning: response)
        return true
    }
}
