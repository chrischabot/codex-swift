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

// WebGateway — the user-facing web server / WebSocket gateway (docs/webgateway/).
// Hummingbird 2.x + SwiftNIO is the repo's first networking dependency (the
// portable core and existing transports are hand-rolled POSIX/Network.framework).
// `traits: []` on hummingbird drops the default ConfigurationSupport trait so we
// don't pull apple/swift-configuration transitively. Pins are point-in-time —
// re-reconcile against Swift Package Index on bump. See docs/webgateway/.
let webDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    // Already in the graph transitively (NIO/Hummingbird); declared so
    // WebGateway can `import Crypto` (HMAC media-token signing) on macOS+Linux.
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
]

let webGatewayDeps: [Target.Dependency] = [
    .product(name: "Hummingbird", package: "hummingbird"),
    .product(name: "HummingbirdCore", package: "hummingbird"),
    .product(name: "HummingbirdTLS", package: "hummingbird"),
    .product(name: "HummingbirdHTTP2", package: "hummingbird"),
    .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
    .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
    .product(name: "Crypto", package: "swift-crypto"),
    "Supervisor", "Persistence", "Auth", "Config",
    "WireProtocol", "ProtocolModel", "InfraPrimitives", "Observability",
]

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
        .library(name: "Workflows", targets: ["Workflows"]),
        .library(name: "WebGateway", targets: ["WebGateway"]),
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
        .library(name: "BenchKit", targets: ["BenchKit"]),
        .library(name: "ComputerUse", targets: ["ComputerUse"]),
        .executable(name: "codexd", targets: ["codexd"]),
        .executable(name: "codex-broker", targets: ["codex-broker"]),
        .executable(name: "codex-session", targets: ["codex-session"]),
        .executable(name: "codex-memory", targets: ["codex-memory"]),
        .executable(name: "mock-responses", targets: ["mock-responses"]),
        .executable(name: "codex-bench", targets: ["codex-bench"]),
        .executable(name: "codex-computer", targets: ["codex-computer"]),
    ],
    dependencies: mlxDependencies + webDependencies,
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
        // Computer-use (OpenAI `computer` tool): macOS desktop control executor.
        // System frameworks only (AppKit/CoreGraphics/ApplicationServices/ImageIO).
        .target(name: "ComputerUse", swiftSettings: strict),
        .target(name: "Observability", dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "WireProtocol", dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "ProtocolModel", dependencies: ["WireProtocol", "InfraPrimitives"], swiftSettings: strict),

        .target(name: "Prompts",
                resources: [.copy("Resources/models.json")],
                swiftSettings: strict),

        .target(name: "Persistence",
                dependencies: ["ProtocolModel", "WireProtocol", "InfraPrimitives", "CSQLite"], swiftSettings: strict),
        .target(name: "ModelClient",
                dependencies: ["InfraPrimitives", "WireProtocol"], swiftSettings: strict),
        .target(name: "Sandbox",
                dependencies: ["InfraPrimitives"], swiftSettings: strict),
        .target(name: "Tools",
                dependencies: ["ProtocolModel", "ModelClient", "InfraPrimitives", "Sandbox", "CPTY", "ComputerUse"], swiftSettings: strict),
        .target(name: "MCP",
                dependencies: ["Tools", "InfraPrimitives", "ProtocolModel", "Config"], swiftSettings: strict),
        .target(name: "Skills", swiftSettings: strict),
        .target(name: "Connectors", swiftSettings: strict),
        .target(name: "ExtensionAPI", swiftSettings: strict),
        .target(name: "HarnessCore",
                dependencies: ["ProtocolModel", "WireProtocol", "ModelClient", "Persistence", "Tools", "InfraPrimitives", "Observability", "Prompts", "Sandbox", "Skills", "Connectors", "Config", "Tokenizer", "ExtensionAPI"],
                swiftSettings: strict),

        // Dynamic Workflows — JS-scripted multi-agent orchestration engine.
        // See docs/workflows/PORT_DESIGN.md.
        .target(name: "Workflows",
                dependencies: ["HarnessCore", "Tools", "ModelClient", "Persistence", "ProtocolModel", "WireProtocol", "Prompts", "InfraPrimitives", "Sandbox", "Config"],
                swiftSettings: strict),

        // WebGateway — Hummingbird/NIO web server + WebSocket gateway that
        // serves the compiled shadcn UI (www/dist) over TLS and bridges browser
        // WebSocket sessions into per-connection RequestRouters over the shared
        // SessionSupervisor, in-process (no external RPC). See docs/webgateway/.
        .target(name: "WebGateway",
                dependencies: webGatewayDeps,
                swiftSettings: strict),

        .target(name: "IPC", dependencies: ["ProtocolModel"], swiftSettings: strict),
        .target(name: "Transport",
                dependencies: ["WireProtocol", "ProtocolModel", "InfraPrimitives"], swiftSettings: strict),

        .target(name: "SessionWorkerCore",
                dependencies: ["HarnessCore", "IPC", "ProtocolModel"], swiftSettings: strict),
        .target(name: "Supervisor",
                dependencies: ["WireProtocol", "ProtocolModel", "Persistence", "IPC", "InfraPrimitives", "Skills", "MCP", "Connectors", "Auth", "Tokenizer", "Config", "Observability", "Tools", "Prompts"],
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
                               "Supervisor", "Transport", "Observability", "Auth", "Tokenizer", "Config", "Workflows",
                               "MemoryExtension", "WebGateway"],
                swiftSettings: strict),
        .executableTarget(name: "codex-broker",
                dependencies: ["Broker", "Auth", "Observability"], swiftSettings: strict),
        .executableTarget(name: "codex-session",
                dependencies: ["InfraPrimitives", "WireProtocol", "ProtocolModel", "Persistence",
                               "ModelClient", "Tools", "Sandbox", "Prompts", "MCP", "Skills",
                               "Connectors", "HarnessCore", "IPC", "SessionWorkerCore",
                               "Observability", "Auth", "Tokenizer", "Config", "Workflows",
                               "MemoryExtension"], swiftSettings: strict),
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
        // Phase 1 extension: the Memory Wiki as a MemoryProvider (impl #1).
        // The composition factory (`makeWikiMemoryProvider`) builds the full
        // read stack (store + inference + retriever + gate + toolset), so it
        // pulls the Memory* read modules + ModelClient/Config — but NOT the
        // curation modules (Ingest/Process), which live in `codex-memory`.
        .target(name: "MemoryExtension",
                dependencies: ["HarnessCore", "MemoryRetrieve", "MemoryStore",
                               "MemoryInfer", "MemoryScore", "MemoryMCP",
                               "ModelClient", "Config", "Tools"],
                swiftSettings: strict),
        // Phase 3 extension: the local-LLM SmallModel utility (addon-only).
        .target(name: "SmallModel",
                dependencies: ["ModelClient", "InfraPrimitives"],
                swiftSettings: strict),
        // Phase 4 extension: the Channel contract + engine-backed host.
        .target(name: "Channels",
                dependencies: ["HarnessCore", "ProtocolModel", "ExtensionAPI"],
                swiftSettings: strict),

        .executableTarget(name: "codex-memory",
                dependencies: ["MemoryStore", "MemoryInfer", "MemoryIngest", "MemoryProcess",
                               "MemoryScore", "MemoryRetrieve", "MemoryMCP",
                               "Config", "Observability", "InfraPrimitives", "ModelClient"],
                swiftSettings: strict),

        // -----------------------------------------------------------------
        // DeepSWE benchmark runner — see docs/benchmarks/DEEP_SWE_RUNNER.md
        // Runs the vendored deep-swe suite with codex-swift as the agent,
        // isolating each task in an apple/container arm64 VM and scoring a
        // Pass@1 comparable to deepswe.datacurve.ai.
        // -----------------------------------------------------------------
        .target(name: "BenchKit",
                dependencies: ["InfraPrimitives", "Observability", "ProtocolModel",
                               "WireProtocol", "ModelClient", "Persistence", "Tools",
                               "Sandbox", "Prompts", "HarnessCore", "Config", "Tokenizer",
                               "MCP", "Skills", "Connectors", "ExtensionAPI",
                               "Supervisor", "SessionWorkerCore", "IPC"],
                swiftSettings: strict),
        .executableTarget(name: "codex-bench",
                dependencies: ["BenchKit", "InfraPrimitives", "Observability"],
                swiftSettings: strict),
        .executableTarget(name: "codex-computer",
                dependencies: ["ComputerUse"],
                swiftSettings: strict),

        .testTarget(name: "WorkflowsTests",
                dependencies: ["Workflows", "Tools", "ModelClient", "Persistence", "InfraPrimitives", "HarnessCore"], swiftSettings: strict),
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
                dependencies: ["Persistence", "ProtocolModel", "InfraPrimitives", "WireProtocol"], swiftSettings: strict),
        .testTarget(name: "ModelClientTests",
                dependencies: ["ModelClient", "InfraPrimitives", "Prompts"], swiftSettings: strict),
        .testTarget(name: "HarnessCoreTests",
                dependencies: ["HarnessCore", "ModelClient", "Persistence", "Tools",
                               "Sandbox", "ProtocolModel", "WireProtocol", "InfraPrimitives", "Prompts", "Config", "Tokenizer", "ExtensionAPI"], swiftSettings: strict),
        .testTarget(name: "MemoryExtensionTests",
                dependencies: ["MemoryExtension", "MemoryRetrieve", "MemoryStore", "MemoryInfer",
                               "HarnessCore", "Tools", "InfraPrimitives", "ModelClient", "Config"],
                swiftSettings: strict),
        .testTarget(name: "SmallModelTests",
                dependencies: ["SmallModel", "ModelClient", "InfraPrimitives"], swiftSettings: strict),
        .testTarget(name: "ChannelsTests",
                dependencies: ["Channels", "HarnessCore", "ModelClient", "Persistence",
                               "Tools", "ProtocolModel", "InfraPrimitives", "ExtensionAPI"], swiftSettings: strict),
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
                               "Sandbox", "Prompts", "MCP"],
                swiftSettings: strict),
        .testTarget(name: "IntegrationTests",
                dependencies: ["Supervisor", "SessionWorkerCore", "HarnessCore", "ModelClient",
                               "Persistence", "Tools", "IPC", "ProtocolModel", "WireProtocol",
                               "InfraPrimitives", "Observability"],
                swiftSettings: strict),
        .testTarget(name: "LiveTests",
                dependencies: ["HarnessCore", "ModelClient", "Persistence", "Tools",
                               "Sandbox", "ProtocolModel", "InfraPrimitives", "Prompts", "MCP",
                               "Supervisor", "SessionWorkerCore", "IPC", "WireProtocol",
                               "Workflows", "Config", "Connectors", "Skills",
                               "ExtensionAPI", "MemoryExtension", "SmallModel", "Channels"],
                swiftSettings: strict),
        .testTarget(name: "BenchKitTests",
                dependencies: ["BenchKit", "InfraPrimitives", "ProtocolModel",
                               "ModelClient", "Tools", "HarnessCore"],
                swiftSettings: strict),
        .testTarget(name: "WebGatewayTests",
                dependencies: ["WebGateway"],
                swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
