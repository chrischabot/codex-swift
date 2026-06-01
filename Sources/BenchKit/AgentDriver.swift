import Foundation

/// Drives an agent to solve a task inside its prepared container. The container
/// already has the (host-cloned) workspace bind-mounted at `/app`. Implementations
/// edit `/app` and may run commands in the container; they return run telemetry.
public protocol AgentDriving: Sendable {
    func solve(task: TaskSpec,
               workspace: URL,
               containerId: String,
               runtime: any ContainerRuntime,
               model: String,
               timeout: Duration,
               log: @escaping @Sendable (String) -> Void) async -> AgentRunInfo
}

/// Used by the `reference`/`empty` self-test modes (no agent runs).
public struct NullAgentDriver: AgentDriving {
    public init() {}
    public func solve(task: TaskSpec, workspace: URL, containerId: String,
                      runtime: any ContainerRuntime, model: String, timeout: Duration,
                      log: @escaping @Sendable (String) -> Void) async -> AgentRunInfo {
        AgentRunInfo(model: model, completed: true)
    }
}
