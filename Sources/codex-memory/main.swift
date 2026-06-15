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

case "cycle":
    do {
        let cliArgs = Array(args.dropFirst())
        let dryRun = cliArgs.contains("--dry-run")
        let json = cliArgs.contains("--json")
        let report = try await CodexMemoryRun.cycleOnce(dryRun: dryRun)
        let out: String
        if json {
            let obj: [String: Any] = [
                "aborted": report.aborted,
                "total_touched": report.totalTouched,
                "phases": report.phases.map {
                    ["name": $0.name, "status": $0.status.rawValue,
                     "touched": $0.touched, "duration_ms": $0.durationMs]
                },
            ]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
                ?? Data("{}".utf8)
            out = String(decoding: d, as: UTF8.self) + "\n"
        } else {
            let body = report.phases
                .map { "\($0.name)=\($0.touched)(\($0.status.rawValue))" }
                .joined(separator: " ")
            out = "maintenance cycle: \(body)\(dryRun ? " [dry-run]" : "")\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cycle failed: \(error)\n".utf8))
        exit(2)
    }

case "import-claude":
    do {
        let report = try await CodexMemoryClaudeImport.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(report.utf8))
        exit(report.contains("FAIL ") ? 1 : 0)
    } catch {
        FileHandle.standardError.write(Data("import-claude failed: \(error)\n".utf8))
        exit(2)
    }

case "import-markdown":
    do {
        let result = try await CodexMemoryMarkdownImport.runDetailed(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.report.failed == 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("import-markdown failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-compile":
    do {
        let result = try await CodexMemoryWikiCompile.runDetailed(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.report.failed == 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-compile failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-lint":
    do {
        let result = try await CodexMemoryWikiLint.runDetailed(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.report.errorCount == 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-lint failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-ingest":
    do {
        let result = try await CodexMemoryWikiIngest.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-ingest failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-librarian":
    do {
        let result = try await CodexMemoryWikiLibrarian.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-librarian failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-status":
    do {
        let result = try await CodexMemoryWikiStatus.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-status failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-query":
    do {
        let result = try await CodexMemoryWikiQuery.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-query failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-watch":
    do {
        let result = try await CodexMemoryWikiWatch.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-watch failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-audit":
    do {
        let result = try await CodexMemoryWikiAudit.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-audit failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-contradictions":
    do {
        let result = try await CodexMemoryWikiContradictions.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-contradictions failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-refresh":
    do {
        let result = try await CodexMemoryWikiRefresh.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-refresh failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-inventory":
    do {
        let result = try await CodexMemoryWikiInventory.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-inventory failed: \(error)\n".utf8))
        exit(2)
    }

case "code-index":
    do {
        let result = try await CodexMemoryCodeIndex.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("code-index failed: \(error)\n".utf8))
        exit(2)
    }

case "wiki-research":
    do {
        let result = try await CodexMemoryWikiResearch.run(args: Array(args.dropFirst()))
        FileHandle.standardOutput.write(Data(result.output.utf8))
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("wiki-research failed: \(error)\n".utf8))
        exit(2)
    }

case "run":
    await CodexMemoryRun.runForever()

case "help", "--help", "-h":
    print("""
    codex-memory <subcommand>

      verify          Phase-0 self-check: probe deps, schema, pricing pins.
      tick            Run one ingest/process cycle then exit (useful in tests).
      import-claude   Import Claude transcript memory documents from JSONL.
      import-markdown Import local markdown roots into the Memory Wiki index.
      wiki-compile    Compile source/entity/claim pages and agent digests.
      wiki-lint       Lint markdown roots, compiled vault, and wiki index health.
      wiki-ingest     Ingest a URL/file/arXiv query/GitHub-owner URL into the wiki.
      wiki-librarian  Tier-1 staleness scan over compiled wiki pages (scan).
      wiki-status     Dashboard: doc/page counts, flagged-stale, recent ingest log.
      wiki-query      Query the knowledge (hybrid retrieval) and print ranked hits.
      wiki-watch      Register/list watched sources (add|list|pause|resume|remove|run-due).
      wiki-audit      Output-drift scan: pages compiled from since-changed claims.
      wiki-refresh    Re-fetch + re-verify due (stale) sources (--due); bump verified_at.
      wiki-inventory  Durable inventory CRUD (list|add|show|save-view|views) — compact table.
      wiki-research   Multi-round web research swarm → credibility filter → ingest.
      run             Long-running daemon: ingest → process → score, with MCP.

    See docs/codex-swift-memory-wiki.md for the full design.
    """)

default:
    FileHandle.standardError.write(Data("unknown subcommand: \(subcommand)\n".utf8))
    exit(64)
}
