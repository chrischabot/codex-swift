import Foundation
#if canImport(AppKit)
import ComputerUse

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: stream progress immediately

// codex-computer — let gpt-5.5 drive THIS Mac's desktop via the OpenAI `computer`
// tool. Requires OPENAI_API_KEY + Screen Recording & Accessibility permissions.
//
// Usage:
//   codex-computer "open Safari and go to apple.com"
//   codex-computer --check                      # permission preflight only
//   codex-computer --width 1440 --max-steps 60 --effort low "..."
//   codex-computer --no-confirm "..."           # don't pause on safety checks

let raw = Array(CommandLine.arguments.dropFirst())

func optValue(_ name: String) -> String? {
    // `--name value`
    if let i = raw.firstIndex(of: name), i + 1 < raw.count { return raw[i + 1] }
    // `--name=value`
    if let tok = raw.first(where: { $0.hasPrefix(name + "=") }) {
        return String(tok.dropFirst(name.count + 1))
    }
    return nil
}
// Was the flag supplied at all (either `--name value` or `--name=value`)? Used
// so a present-but-valueless flag fails fast instead of silently defaulting.
func optPresent(_ name: String) -> Bool {
    raw.contains(name) || raw.contains(where: { $0.hasPrefix(name + "=") })
}
let hasFlag: (String) -> Bool = { raw.contains($0) }
let isOpt: (String) -> Bool = { ["--width", "--max-steps", "--effort"].contains($0) }
// Task = all non-flag, non-flag-value tokens joined.
var task = ""
var skip = false
for (i, tok) in raw.enumerated() {
    if skip { skip = false; continue }
    if tok.hasPrefix("--") { if isOpt(tok) { skip = true }; continue }
    task += (task.isEmpty ? "" : " ") + tok
}

var execOpts = ComputerUseExecutor(targetWidth: Int(optValue("--width") ?? "") ?? 1280)
var opts = ComputerUseLoop.Options()
if optPresent("--effort") {
    // Validate up front: the value is sent verbatim as reasoning.effort, and an
    // unknown value makes EVERY Responses request 400 (an opaque mid-run failure).
    // The set matches gpt-5.5's `supported_reasoning_levels` in the model catalog
    // (models.json) — {low, medium, high, xhigh}. NOTE: `minimal` is NOT valid for
    // gpt-5.5 and `xhigh` IS; keep this in sync if the CLI ever targets another model.
    let allowed = ["low", "medium", "high", "xhigh"]
    guard let m = optValue("--effort") else {
        FileHandle.standardError.write(Data(
            "error: --effort requires a value (\(allowed.joined(separator: "|")))\n".utf8))
        exit(2)
    }
    guard allowed.contains(m.lowercased()) else {
        FileHandle.standardError.write(Data(
            "error: --effort must be one of \(allowed.joined(separator: ", ")); got \"\(m)\"\n".utf8))
        exit(2)
    }
    opts.reasoningEffort = m.lowercased()
}
if optPresent("--max-steps") {
    guard let v = optValue("--max-steps"), let s = Int(v), s > 0 else {
        FileHandle.standardError.write(Data(
            "error: --max-steps requires a positive integer\n".utf8))
        exit(2)
    }
    opts.maxSteps = s
}
if hasFlag("--no-confirm") { opts.confirmRiskyActions = false }
if hasFlag("--dry-run") { opts.dryRun = true }

// --screenshot FILE : capture only (verifies Screen Recording + capture path).
if let file = optValue("--screenshot") {
    let p = execOpts.checkPermissions(prompt: true)
    guard let png = execOpts.screenshotPNG() else {
        FileHandle.standardError.write(Data("screenshot failed (Screen Recording: \(p.screenRecording))\n".utf8)); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: file))
    print("captured \(png.count) bytes → \(file) (\(execOpts.targetWidth)×\(execOpts.targetHeight))")
    exit(0)
}

if hasFlag("--check") || hasFlag("-h") || hasFlag("--help") {
    let p = execOpts.checkPermissions(prompt: true)
    print("Display: \(execOpts.targetWidth)×\(execOpts.targetHeight) (model image space)")
    print("Screen Recording permission: \(p.screenRecording ? "✅" : "❌ — grant in System Settings → Privacy & Security → Screen Recording")")
    print("Accessibility permission:    \(p.accessibility ? "✅" : "❌ — grant in System Settings → Privacy & Security → Accessibility")")
    if hasFlag("--check") { exit(p.ok ? 0 : 1) }
    print("\nUsage: codex-computer [--width N] [--max-steps N] [--effort low|medium|high|xhigh] [--no-confirm] \"<task>\"")
    exit(0)
}

guard !task.isEmpty else {
    FileHandle.standardError.write(Data("error: no task given. Try: codex-computer \"open Safari\"  (or --check)\n".utf8))
    exit(2)
}
guard let loop = ComputerUseLoop(executor: execOpts, options: opts) else {
    FileHandle.standardError.write(Data("error: OPENAI_API_KEY not set.\n".utf8))
    exit(2)
}

// Top-level main.swift code runs on @MainActor, so a non-detached `Task {}`
// inherits the main actor and is pinned to the main thread — which we then block
// with `sem.wait()`, deadlocking before anything runs. Use `Task.detached` so the
// work runs on the cooperative pool while main blocks.
final class ExitBox: @unchecked Sendable { var code: Int32 = 0 }
let box = ExitBox()
let sem = DispatchSemaphore(value: 0)
Task.detached { [task, loop, box] in
    defer { sem.signal() }
    do {
        print("🖥  task: \(task)\n"); fflush(stdout)
        let result = try await loop.run(task: task)
        if !result.isEmpty { print("\n— \(result)") }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        box.code = 1
    }
}
sem.wait()
let exitCode = box.code
exit(exitCode)
#else
FileHandle.standardError.write(Data("codex-computer requires macOS.\n".utf8))
exit(1)
#endif
