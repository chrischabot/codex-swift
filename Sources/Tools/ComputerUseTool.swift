import Foundation
#if canImport(AppKit)
import ComputerUse

/// `computer_use` — lets the agent drive the REAL macOS desktop (mouse,
/// keyboard, and screen) to accomplish a natural-language GUI task it cannot do
/// through the shell / file / code tools.
///
/// This is a thin, faithful wrapper around the native OpenAI `computer` action
/// loop (`ComputerUse.ComputerUseLoop`): the loop screenshots the desktop, asks
/// gpt-5.5 for the next `computer_call`, executes it via CGEvent, sends a fresh
/// screenshot back, and repeats until the model stops acting. The screenshots
/// stay INSIDE that sub-loop, so the calling agent's context / rollout is never
/// bloated with images — the agent receives a compact action trace plus the
/// loop's final message.
///
/// Architectural note: the `computer` tool is a NATIVE Responses tool that round-
/// trips images (`computer_call` ⇄ `computer_call_output` screenshot), which the
/// main turn loop's `function_call`-based protocol does not model. Rather than
/// thread an image path through the entire protocol/streaming/context stack, we
/// expose the capability as an ordinary function tool whose handler runs the
/// native loop to completion — the same delegation pattern used for sub-agents.
///
/// Registered only for LOCAL (non-remote) macOS sessions — controlling the host
/// desktop from a session bound to a remote exec container would be meaningless.
public struct ComputerUseTool: Tool {
    public let name = "computer_use"
    /// Drives the GLOBAL mouse + keyboard; it can never run concurrently with any
    /// other tool, so it always takes the exclusive (write) side of the gate.
    public let parallelSafe = false

    private let targetWidth: Int
    private let defaultMaxSteps: Int
    private let env: [String: String]

    public init(targetWidth: Int = 1280,
                defaultMaxSteps: Int = 25,
                env: [String: String] = ProcessInfo.processInfo.environment) {
        self.targetWidth = targetWidth
        self.defaultMaxSteps = defaultMaxSteps
        self.env = env
    }

    public var toolDescription: String {
        """
        Control the local macOS desktop — mouse, keyboard, and screen — to \
        accomplish a GUI task that cannot be done through the shell, file, or \
        code tools. Use it for operating GUI-only applications, clicking through \
        a native app's interface, interacting with windows, or anything that \
        requires seeing and manipulating what is on screen (e.g. "open the \
        Calculator app and compute 12 x 9", "in System Settings turn on Dark \
        Mode", "open Safari and take a screenshot of apple.com").

        Provide a single, self-contained natural-language `task`. The tool then \
        runs autonomously: it captures the screen, decides the next UI action \
        (open-app / click / double-click / type / keypress / scroll / drag), \
        performs it on the REAL desktop, takes a fresh screenshot, and repeats \
        until the task is complete. It returns a trace of the actions it took \
        plus a short result summary.

        Use this ONLY for genuine GUI/desktop automation. For files, builds, \
        git, scripts, or anything achievable in a terminal, use the \
        shell/apply_patch/file tools instead — they are faster and more \
        reliable. While this tool runs it takes over the mouse and keyboard, so \
        never use it for work the other tools can do. Requires macOS Screen \
        Recording + Accessibility permissions and an OpenAI API key.
        """
    }

    public var jsonSchema: String {
        """
        {"type":"object","properties":{\
        "task":{"type":"string","description":"A single, self-contained \
        natural-language description of the GUI/desktop task to accomplish, \
        e.g. 'Open the Calculator app and compute 12 x 9'."},\
        "max_steps":{"type":"integer","description":"Optional cap on the number \
        of screenshot->action iterations (default 25, max 60). Raise for longer \
        multi-step tasks."}},\
        "required":["task"],"additionalProperties":false}
        """
    }

    private struct Args: Decodable { var task: String; var max_steps: Int? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              !args.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ToolResult(callId: call.callId,
                              output: "computer_use requires a non-empty \"task\" string argument.",
                              success: false, truncated: false)
        }

        // Surface the no-key case precisely, and BEFORE constructing the executor
        // (which reads `NSScreen.main`) so a key-less environment never touches
        // the display. The `computer` action loop uses a direct OpenAI key (the
        // gpt-5.5 `computer` tool is separate from the session's chat auth).
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty else {
            return ToolResult(callId: call.callId,
                              output: "computer_use is unavailable: OPENAI_API_KEY is not set in the "
                                  + "session environment. The desktop-control loop needs a direct OpenAI "
                                  + "API key (it drives the gpt-5.5 `computer` tool, which is separate "
                                  + "from the session's chat authentication).",
                              success: false, truncated: false)
        }

        var options = ComputerUseLoop.Options()
        options.maxSteps = max(1, min(args.max_steps ?? defaultMaxSteps, 60))
        let trace = TraceCollector()
        // Capture the loop's progress lines into the result instead of stdout
        // (stdout is the daemon's wire-protocol channel — must stay clean).
        options.log = { line in trace.append(line) }

        let executor = ComputerUseExecutor(targetWidth: targetWidth)
        guard let loop = ComputerUseLoop(executor: executor, options: options, env: env) else {
            // Unreachable given the key guard above (the only nil cause), but
            // keep a faithful fallback rather than force-unwrapping.
            return ToolResult(callId: call.callId,
                              output: "computer_use is unavailable: the desktop-control loop could not be initialized.",
                              success: false, truncated: false)
        }

        do {
            // `loop.run` performs its own TCC permission preflight and throws
            // `LoopError.permissions` with an actionable message if missing.
            let finalText = try await loop.run(task: args.task)
            var out = "Computer-use actions performed:\n" + trace.joined()
            if !finalText.isEmpty { out += "\n\nResult: \(finalText)" }
            return ToolResult(callId: call.callId, output: out, success: true, truncated: false)
        } catch {
            let attempted = trace.joined()
            var out = "computer_use failed: \(error)"
            if !attempted.isEmpty { out += "\n\nActions attempted:\n" + attempted }
            return ToolResult(callId: call.callId, output: out, success: false, truncated: false)
        }
    }
}

/// Thread-safe sink for the action-loop progress lines (the loop calls `log`
/// from its own async context; `dispatch` may observe it from the actor).
private final class TraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func joined() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
#endif
