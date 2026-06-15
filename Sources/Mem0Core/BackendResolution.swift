import Foundation

public enum Mem0BackendRequest: String, Sendable, Equatable {
    case auto
    case local
    case remote
    case mock

    public static func parse(_ raw: String?) -> Mem0BackendRequest {
        guard let raw else { return .auto }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local", "mlx", "mlx_local": return .local
        case "remote", "openai": return .remote
        case "mock", "offline": return .mock
        default: return .auto
        }
    }
}

public enum Mem0ResolvedBackend: String, Sendable, Equatable {
    case local
    case remote
    case mock
}

public enum Mem0BackendResolver {
    public static func resolve(_ requested: Mem0BackendRequest,
                               localAvailable: Bool,
                               remoteAvailable: Bool) -> Mem0ResolvedBackend {
        switch requested {
        case .mock:
            return .mock
        case .remote:
            if remoteAvailable { return .remote }
            return localAvailable ? .local : .mock
        case .local:
            if localAvailable { return .local }
            return .mock
        case .auto:
            if localAvailable { return .local }
            return remoteAvailable ? .remote : .mock
        }
    }
}
