// swift-tools-version: 6.1
//
// CodexKit — native Swift/macOS 26 reimplementation of the OpenAI Codex
// agent harness as a long-running, multi-session, wire-compatible daemon.
//
// See ../evaluation/*.md for the design suite and ./STATUS.md for the
// authoritative per-module completion map.
//
// Deployment target is macOS 14 so the package builds with current
// toolchains; macOS-26-only APIs are gated (`#if canImport(Network)` /
// `if #available(macOS 26,*)`). Raise to .macOS("26.0") on the macOS 26 SDK
// (STATUS.md P6-3). The portable core builds/tests on Linux and macOS.

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

// MLX Swift LM is gated on macOS (Apple Silicon). Linux builds skip the
// dependency entirely. Enable by setting `CODEXKIT_MLX=1` in the environment
// when invoking SwiftPM so CI builds without it stay fast.
let mlxEnabled = (Context.environment["CODEXKIT_MLX"] == "1")

let mlxDependencies: [Package.Dependency] = mlxEnabled ? [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
] : []

// We only enable MLX when the user explicitly opts in via CODEXKIT_MLX=1,
// which is only valid on macOS. Linux ignores the flag.
func makeMLXProducts() -> [Target.Dependency] {
    guard mlxEnabled else { return [] }
    var deps: [Target.Dependency] = []
    deps.append(.product(name: "MLXLLM", package: "mlx-swift-lm"))
    deps.append(.product(name: "MLXLMCommon", package: "mlx-swift-lm"))
    deps.append(.product(name: "MLXEmbedders", package: "mlx-swift-lm"))
    deps.append(.product(name: "MLX", package: "mlx-swift"))
    deps.append(.product(name: "MLXNN", package: "mlx-swift"))
    return deps
}
let mlxProducts: [Target.Dependency] = makeMLXProducts()

let mlxSwiftSettings: [SwiftSetting] = mlxEnabled
    ? [.define("CODEXKIT_MLX")]
    : []

// Precompute MemoryInfer dependencies and settings so the big Package(...)
// expression below stays inside the compiler's type-checking budget. (Swift
// 6.1's manifest checker chokes on a too-rich nested expression otherwise.)
var memoryInferDeps: [Target.Dependency] = [
    "InfraPrimitives", "Observability", "Config", "ModelClient",
]
memoryInferDeps.append(contentsOf: mlxProducts)
let memoryInferSettings: [SwiftSetting] = strict + mlxSwiftSettings

let package = Package(
    name: "CodexKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "InfraPrimitives", targets: ["InfraPrimitives"]),
        .library(name: "Observability", targets: ["Observability"]),
        .library(name: "WireProtocol", targets: ["WireProtocol"]),
        .library(name: "ProtocolModel", targets: ["ProtocolModel"]),
        .library(name: "Prompts", targets: ["Prompts"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "ModelClient", targets: ["ModelClient"]),
        .library(name: "Sandbox", targets: ["Sandbox"]),
        .library(name: "Tools", targets: ["Tools"]),
        .library(name: "MCP", targets: ["MCP"]),
        .library(name: "Skills", targets: ["Skills"]),
        .library(name: "Connectors", targets: ["Connectors"]),
        .library(name: "ExtensionAPI", targets: ["ExtensionAPI"]),
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .library(name: "IPC", targets: ["IPC"]),
        .library(name: "Transport", targets: ["Transport"]),
        .library(name: "Supervisor", targets: ["Supervisor"]),
        .library(name: "Broker", targets: ["Broker"]),
        .library(name: "Auth", targets: ["Auth"]),
        .library(name: "Tokenizer", targets: ["Tokenizer"]),
        .library(name: "Config", targets: ["Config"]),
        .library(name: "SessionWorkerCore", targets: ["SessionWorkerCore"]),
        .library(name: "MemoryStore", targets: ["MemoryStore"]),
        .library(name: "MemoryInfer", targets: ["MemoryInfer"]),
        .library(name: "MemoryIngest", targets: ["MemoryIngest"]),
        .library(name: "MemoryProcess", targets: ["MemoryProcess"]),
        .library(name: "MemoryScore", targets: ["MemoryScore"]),
        .library(name: "MemoryRetrieve", targets: ["MemoryRetrieve"]),
        .library(name: "MemoryMCP", targets: ["MemoryMCP"]),
        .executable(name: "codexd", targets: ["codexd"]),
        .executable(name: "codex-broker", targets: ["codex-broker"]),
        .executable(name: "codex-session", targets: ["codex-session"]),
        .executable(name: "codex-memory", targets: ["codex-memory"]),
        .executable(name: "mock-responses", targets: ["mock-responses"]),
    ],
    dependencies: mlxDependencies,
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "CSQLiteVec",
            path: "Sources/CSQLiteVec",
            sources: ["sqlite_vec_shim.c", "sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .headerSearchPath("include"),
                .headerSearchPath("."),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "CPTY"),

        .target(name: "InfraPrimitives", swiftSettings: strict),
        .target(name: "Observability", dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "WireProtocol", dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "ProtocolModel", dependencies: ["WireProtocol", "InfraPrimitives"], swiftSettings: strict),

        .target(name: "Prompts", swiftSettings: strict),

        .target(name: "Persistence",
                dependencies: ["ProtocolModel", "WireProtocol", "InfraPrimitives", "CSQLite"], swiftSettings: strict),
        .target(name: "ModelClient",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "Sandbox",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "Tools",
                dependencies: ["ProtocolModel", "ModelClient", "InfraPrimitives", "Sandbox", "CPTY"], swiftSettings: strict),
        .target(name: "MCP",
                dependencies: ["Tools", "InfraPrimitives", "ProtocolModel", "Config"], swiftSettings: strict),
        .target(name: "Skills", swiftSettings: strict),
        .target(name: "Connectors", swiftSettings: strict),
        .target(name: "ExtensionAPI", swiftSettings: strict),
        .target(name: "HarnessCore",
                dependencies: ["ProtocolModel", "WireProtocol", "ModelClient", "Persistence", "Tools", "InfraPrimitives", "Observability", "Prompts", "Sandbox", "Skills", "Connectors", "Config", "Tokenizer"],
                swiftSettings: strict),

        .target(name: "IPC", dependencies: ["ProtocolModel"], swiftSettings: strict),
        .target(name: "Transport",
                dependencies: ["WireProtocol", "ProtocolModel", "InfraPrimitives"], swiftSettings: strict),

        .target(name: "SessionWorkerCore",
                dependencies: ["HarnessCore", "IPC", "ProtocolModel"], swiftSettings: strict),
        .target(name: "Supervisor",
                dependencies: ["WireProtocol", "ProtocolModel", "Persistence", "IPC", "InfraPrimitives", "Skills", "MCP", "Connectors", "Auth", "Tokenizer", "Config", "Observability", "Tools"],
                swiftSettings: strict),
        .target(name: "Broker",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "Auth",
                dependencies: ["InfraPrimitives", "Broker"], swiftSettings: strict),
        .target(name: "Tokenizer",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "Config",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),

        .executableTarget(name: "codexd",
                dependencies: ["InfraPrimitives", "WireProtocol", "ProtocolModel", "Persistence",
                               "ModelClient", "Tools", "Sandbox", "Prompts", "MCP", "Skills",
                               "Connectors", "HarnessCore", "IPC", "SessionWorkerCore",
                               "Supervisor", "Transport", "Observability", "Auth", "Tokenizer", "Config"],
                swiftSettings: strict),
        .executableTarget(name: "codex-broker",
                dependencies: ["Broker", "Auth", "Observability"], swiftSettings: strict),
        .executableTarget(name: "codex-session",
                dependencies: ["InfraPrimitives", "WireProtocol", "ProtocolModel", "Persistence",
                               "ModelClient", "Tools", "Sandbox", "Prompts", "MCP", "Skills",
                               "Connectors", "HarnessCore", "IPC", "SessionWorkerCore",
                               "Observability", "Auth", "Tokenizer"], swiftSettings: strict),
        .executableTarget(name: "mock-responses",
                dependencies: ["ModelClient", "InfraPrimitives"], swiftSettings: strict),

        // -----------------------------------------------------------------
        // Memory Wiki — see docs/codex-swift-memory-wiki.md
        // -----------------------------------------------------------------
        .target(name: "MemoryStore",
                dependencies: ["InfraPrimitives", "Observability", "CSQLite", "CSQLiteVec"],
                swiftSettings: strict),
        .target(name: "MemoryInfer",
                dependencies: memoryInferDeps,
                swiftSettings: memoryInferSettings),
        .target(name: "MemoryIngest",
                dependencies: ["InfraPrimitives", "Observability", "Config",
                               "Sandbox", "MemoryStore"],
                swiftSettings: strict),
        .target(name: "MemoryProcess",
                dependencies: ["MemoryIngest", "MemoryInfer", "MemoryStore", "InfraPrimitives", "Observability"],
                swiftSettings: strict),
        .target(name: "MemoryScore",
                dependencies: ["MemoryStore", "MemoryInfer", "Observability", "InfraPrimitives", "Config", "ModelClient"],
                swiftSettings: strict),
        .target(name: "MemoryRetrieve",
                dependencies: ["MemoryStore", "MemoryInfer", "Config", "InfraPrimitives"],
                swiftSettings: strict),
        .target(name: "MemoryMCP",
                dependencies: ["MCP", "Tools", "MemoryRetrieve", "MemoryScore", "MemoryStore", "MemoryInfer",
                               "ModelClient", "ProtocolModel", "Config"],
                swiftSettings: strict),

        .executableTarget(name: "codex-memory",
                dependencies: ["MemoryStore", "MemoryInfer", "MemoryIngest", "MemoryProcess",
                               "MemoryScore", "MemoryRetrieve", "MemoryMCP",
                               "Config", "Observability", "InfraPrimitives", "ModelClient"],
                swiftSettings: strict),

        .testTarget(name: "MemoryStoreTests",
                dependencies: ["MemoryStore", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "MemoryInferTests",
                dependencies: ["MemoryInfer", "ModelClient", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "MemoryIngestTests",
                dependencies: ["MemoryIngest", "MemoryStore", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "MemoryProcessTests",
                dependencies: ["MemoryProcess", "MemoryInfer", "MemoryStore", "InfraPrimitives"],
                swiftSettings: strict),
        .testTarget(name: "MemoryScoreTests",
                dependencies: ["MemoryScore", "MemoryStore", "MemoryInfer", "InfraPrimitives"],
                swiftSettings: strict),
        .testTarget(name: "MemoryRetrieveTests",
                dependencies: ["MemoryRetrieve", "MemoryStore", "MemoryInfer", "InfraPrimitives"],
                swiftSettings: strict),
        .testTarget(name: "MemoryMCPTests",
                dependencies: ["MemoryMCP", "MemoryStore", "MemoryInfer", "Tools", "InfraPrimitives"],
                swiftSettings: strict),
        .testTarget(name: "MemoryE2ETests",
                dependencies: ["MemoryStore", "MemoryInfer", "MemoryIngest", "MemoryProcess",
                               "MemoryScore", "MemoryRetrieve", "MemoryMCP",
                               "Tools", "InfraPrimitives"],
                swiftSettings: strict),

        .testTarget(name: "InfraPrimitivesTests",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "WireProtocolTests",
                dependencies: ["WireProtocol", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "ProtocolModelTests",
                dependencies: ["ProtocolModel", "WireProtocol"], swiftSettings: strict),
        .testTarget(name: "PromptsTests",
                dependencies: ["Prompts"], swiftSettings: strict),
        .testTarget(name: "PersistenceTests",
                dependencies: ["Persistence", "ProtocolModel", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "ModelClientTests",
                dependencies: ["ModelClient", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "HarnessCoreTests",
                dependencies: ["HarnessCore", "ModelClient", "Persistence", "Tools",
                               "Sandbox", "ProtocolModel", "WireProtocol", "InfraPrimitives", "Prompts", "Config"], swiftSettings: strict),
        .testTarget(name: "ToolsTests",
                dependencies: ["Tools", "Sandbox", "ProtocolModel", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "SandboxTests",
                dependencies: ["Sandbox", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "MCPTests",
                dependencies: ["MCP", "Tools", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "SkillsTests",
                dependencies: ["Skills"], swiftSettings: strict),
        .testTarget(name: "ConnectorsTests",
                dependencies: ["Connectors"], swiftSettings: strict),
        .testTarget(name: "ExtensionAPITests",
                dependencies: ["ExtensionAPI"], swiftSettings: strict),
        .testTarget(name: "BrokerTests",
                dependencies: ["Broker", "Auth", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "AuthTests",
                dependencies: ["Auth", "Broker", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "TokenizerTests",
                dependencies: ["Tokenizer", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "ConfigTests",
                dependencies: ["Config", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "ObservabilityTests",
                dependencies: ["Observability", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "AdversarialTests",
                dependencies: ["InfraPrimitives", "WireProtocol", "ProtocolModel",
                               "ModelClient", "Tools", "Persistence", "HarnessCore",
                               "Sandbox", "Prompts"],
                swiftSettings: strict),
        .testTarget(name: "IntegrationTests",
                dependencies: ["Supervisor", "SessionWorkerCore", "HarnessCore", "ModelClient",
                               "Persistence", "Tools", "IPC", "ProtocolModel", "WireProtocol",
                               "InfraPrimitives", "Observability"],
                swiftSettings: strict),
        .testTarget(name: "LiveTests",
                dependencies: ["HarnessCore", "ModelClient", "Persistence", "Tools",
                               "Sandbox", "ProtocolModel", "InfraPrimitives", "Prompts", "MCP",
                               "Supervisor", "SessionWorkerCore", "IPC", "WireProtocol"],
                swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
