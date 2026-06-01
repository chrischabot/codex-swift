import Foundation

/// Best-effort detection of how a repo runs its tests, from the workspace
/// contents. Injected into the agent prompt so it doesn't waste turns
/// discovering the toolchain. Heuristic — the agent can adjust.
public enum TestCommandDetector {
    public static func detect(workspace: URL, language: BenchLanguage) -> String {
        let fm = FileManager.default
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: workspace.appendingPathComponent(rel).path) }

        switch language {
        case .go:
            return "go test -timeout 120s ./...   (build first: go build ./...)"
        case .rust:
            return "cargo test --   (a single crate: cargo test -p <crate>)"
        case .python:
            let py = has("venv/bin/python") ? "./venv/bin/python -m pytest" : "pytest"
            return "\(py) -q --timeout=120   (set PYTHONPATH=src if imports fail)"
        case .typescript, .javascript:
            return nodeTestCommand(workspace: workspace) + "   (pass a test timeout, e.g. --testTimeout=120000)"
        }
    }

    private static func nodeTestCommand(workspace: URL) -> String {
        let pkgURL = workspace.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkgURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let scripts = obj["scripts"] as? [String: Any] ?? [:]
            let deps = (obj["devDependencies"] as? [String: Any] ?? [:])
                .merging(obj["dependencies"] as? [String: Any] ?? [:]) { a, _ in a }
            // Prefer a dedicated test runner over the (often slow / lint-heavy) `npm test` script.
            if deps["vitest"] != nil { return "npx vitest run" }
            if deps["jest"] != nil { return "npx jest" }
            if deps["mocha"] != nil { return "npx mocha" }
            if scripts["test"] != nil { return "npm test" }
        }
        return "npx vitest run  (or npx jest / npx mocha — check package.json)"
    }
}
