import Foundation
import ProtocolModel
import WireProtocol

/// Debounced workflow-progress notifier (port of Claude's 16ms-debounced
/// `updateWorkflowProgressBatch`). Coalesces `WorkflowProgress` events per run
/// and flushes them as a single `workflow/progress` `ServerNotification` no more
/// than once per `WF.progressDebounceMs`.
public actor WorkflowProgressNotifier {
    public typealias Sink = @Sendable (ServerNotification) -> Void

    private let runId: String
    private let taskId: String
    private let sink: Sink
    private var buffer: [WorkflowProgress] = []
    private var flushScheduled = false

    public init(runId: String, taskId: String, sink: @escaping Sink) {
        self.runId = runId; self.taskId = taskId; self.sink = sink
    }

    public func enqueue(_ p: WorkflowProgress) {
        buffer.append(p)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(WF.progressDebounceMs))
            await self?.flush()
        }
    }

    /// Flush immediately (e.g. on completion) so the final batch isn't lost.
    public func flushNow() { flush() }

    private func flush() {
        flushScheduled = false
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        sink(.raw(method: "workflow/progress",
                  params: .object([
                    "runId": .string(runId),
                    "taskId": .string(taskId),
                    "events": .array(batch.map(Self.encode)),
                  ])))
    }

    static func encode(_ p: WorkflowProgress) -> JSONValue {
        switch p {
        case .log(let message):
            return .object(["type": .string("workflow_log"), "message": .string(message)])
        case .phase(let index, let title, let kind):
            var o: [String: JSONValue] = ["type": .string("workflow_phase"),
                                          "index": .int(Int64(index)), "title": .string(title)]
            if let k = kind { o["kind"] = .string(k) }
            return .object(o)
        case .agent(let index, let label, let phaseIndex, let phaseTitle, let state,
                    let cached, let skipped, let error, let tokens, let toolCalls,
                    let durationMs, let model, let attempt, let promptPreview):
            var o: [String: JSONValue] = [
                "type": .string("workflow_agent"),
                "index": .int(Int64(index)), "label": .string(label),
                "phaseIndex": .int(Int64(phaseIndex)), "phaseTitle": .string(phaseTitle),
                "state": .string(state.rawValue), "cached": .bool(cached),
                "skipped": .bool(skipped), "tokens": .int(Int64(tokens)),
                "toolCalls": .int(Int64(toolCalls)), "durationMs": .int(Int64(durationMs)),
                "attempt": .int(Int64(attempt)), "promptPreview": .string(promptPreview),
            ]
            if let e = error { o["error"] = .string(e) }
            if let m = model { o["model"] = .string(m) }
            return .object(o)
        }
    }
}
