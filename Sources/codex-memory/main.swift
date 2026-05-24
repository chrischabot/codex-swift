import Foundation
import InfraPrimitives
import MemoryIngest
import MemoryInfer
import MemoryMCP
import MemoryProcess
import MemoryRetrieve
import MemoryScore
import MemoryStore

// Unbuffer stdout/stderr so daemon-style background invocations surface
// progress lines immediately rather than after a 4-KB pipe fill.
setbuf(stdout, nil); setbuf(stderr, nil)

// codex-memory — host-wide CodexKit Memory Wiki daemon. See
// docs/codex-swift-memory-wiki.md and STATUS.md for the contract. This binary
// is intentionally tiny: it threads the seven Memory* modules together,
// registers them with the existing MCP toolset, and exposes a `verify`
// subcommand for the Phase-0 check.

let args = Array(CommandLine.arguments.dropFirst())
let subcommand = args.first ?? "help"

switch subcommand {
case "verify":
    do {
        let report = try await CodexMemoryVerify.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(report.utf8))
        exit(report.contains("FAIL") ? 1 : 0)
    } catch {
        FileHandle.standardError.write(Data("verify failed: \(error)\n".utf8))
        exit(2)
    }

case "tick":
    do {
        try await CodexMemoryRun.tickOnce()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("tick failed: \(error)\n".utf8))
        exit(2)
    }

case "snapshot":
    do {
        try await CodexMemoryRun.snapshotOnce()
        FileHandle.standardOutput.write(Data("snapshot ok\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(2)
    }

case "run":
    await CodexMemoryRun.runForever()

case "help", "--help", "-h":
    print("""
    codex-memory <subcommand>

      verify          Phase-0 self-check: probe deps, schema, pricing pins.
      tick            Run one ingest/process cycle then exit (useful in tests).
      run             Long-running daemon: ingest → process → score, with MCP.

    See docs/codex-swift-memory-wiki.md for the full design.
    """)

default:
    FileHandle.standardError.write(Data("unknown subcommand: \(subcommand)\n".utf8))
    exit(64)
}
