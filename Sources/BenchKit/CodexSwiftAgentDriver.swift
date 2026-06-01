import Foundation

/// Drives **codex-swift** as the agent inside the task container via the
/// `ContainerExecServer` bridge (codex-swift's `remoteEnvironment.execServerUrl`
/// remote tool surface → fs on the host clone, process on `container exec`).
///
/// NOTE: real session-driving is implemented in `ContainerExecServer.swift` +
/// the wiring below; this type is the public entry point.
public struct CodexSwiftAgentDriver: AgentDriving {
    public init() {}

    public func solve(task: TaskSpec, workspace: URL, containerId: String,
                      runtime: any ContainerRuntime, model: String, timeout: Duration,
                      log: @escaping @Sendable (String) -> Void) async -> AgentRunInfo {
        await CodexSwiftSession.run(task: task, workspace: workspace, containerId: containerId,
                                    runtime: runtime, model: model, timeout: timeout, log: log)
    }
}
