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
    /// Optional source for the bearer used to drive the `computer` loop. When
    /// present and it yields a non-empty token, it is PREFERRED over
    /// `OPENAI_API_KEY` — this lets a session that authenticates with a ChatGPT
    /// OAuth access token drive desktop-control without also exporting a separate
    /// `OPENAI_API_KEY` (the loop hits the same `/v1/responses` endpoint the
    /// session's chat uses, so the OAuth bearer authenticates it). Resolved fresh
    /// per invocation so a rotated/refreshed token is always picked up.
    private let tokenProvider: (@Sendable () async -> String?)?

    public init(targetWidth: Int = 1280,
                defaultMaxSteps: Int = 25,
                env: [String: String] = ProcessInfo.processInfo.environment,
                tokenProvider: (@Sendable () async -> String?)? = nil) {
        self.targetWidth = targetWidth
        self.defaultMaxSteps = defaultMaxSteps
        self.env = env
        self.tokenProvider = tokenProvider
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

    /// Bearer precedence for the desktop loop, factored out so the policy is
    /// independently testable (it decides auth — the highest-stakes branch).
    /// The injected `provided` token (session OAuth) wins over the `envKey`
    /// (`OPENAI_API_KEY`); each is trimmed and an empty/whitespace value counts
    /// as absent, so a present-but-blank provider cleanly falls through to env,
    /// and a blank env yields nil (→ the actionable "no bearer" error).
    static func resolveBearer(provided: String?, envKey: String?) -> String? {
        func nonBlank(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        return nonBlank(provided) ?? nonBlank(envKey)
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              !args.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ToolResult(callId: call.callId,
                              output: "computer_use requires a non-empty \"task\" string argument.",
                              success: false, truncated: false)
        }

        // Resolve the bearer, and BEFORE constructing the executor (which reads
        // `NSScreen.main`) so a key-less environment never touches the display.
        // Prefer the session's injected OAuth bearer (a ChatGPT access token
        // authenticates the same `/v1/responses` endpoint the loop drives); fall
        // back to a direct `OPENAI_API_KEY`. An empty/whitespace token from the
        // provider is treated as absent so we cleanly fall through to the env key.
        let provided = await tokenProvider?()
        guard let key = ComputerUseTool.resolveBearer(provided: provided, envKey: env["OPENAI_API_KEY"]) else {
            return ToolResult(callId: call.callId,
                              output: "computer_use is unavailable: no bearer is available — neither a "
                                  + "session OAuth access token nor OPENAI_API_KEY is set. The desktop-control "
                                  + "loop drives the gpt-5.5 `computer` tool against the OpenAI Responses API "
                                  + "and needs one of them.",
                              success: false, truncated: false)
        }

        var options = ComputerUseLoop.Options()
        options.maxSteps = max(1, min(args.max_steps ?? defaultMaxSteps, 60))
        // Safety-check policy for the integrated tool. The HUMAN approval layer is
        // the session-level `.hostControl` gate (SessionEngine prompts before this
        // whole invocation under cautious policies). Within an already-approved
        // invocation we AUTO-PROCEED past OpenAI's benign navigation checks
        // (sensitive_domain / irrelevant_domain — raised on routine bank/login/
        // email pages), because deny-by-default would abort the entire task on the
        // first such check. But we still BLOCK higher-signal codes
        // (malicious_instructions and any UNRECOGNIZED code) so a prompt-injected
        // high-risk action stops rather than running unattended on the desktop.
        options.confirmRiskyActions = true
        options.confirmHandler = { codes in
            let autoAck: Set<String> = ["sensitive_domain", "irrelevant_domain"]
            return codes.allSatisfy { autoAck.contains($0) }
        }
        let trace = TraceCollector()
        // Capture the loop's progress lines into the result instead of stdout
        // (stdout is the daemon's wire-protocol channel — must stay clean).
        options.log = { line in trace.append(line) }

        let executor = ComputerUseExecutor(targetWidth: targetWidth)
        // Drive with the resolved bearer explicitly (not the env-reading init), so
        // the session OAuth token is honored even when OPENAI_API_KEY is unset. Also
        // pass the live `tokenProvider` so the loop RE-RESOLVES the bearer before
        // each request — a long desktop run can outlive a single OAuth token, and
        // the provider (e.g. validAccessToken()) refreshes it transparently. `key`
        // is the fallback for a transient provider miss.
        let loop = ComputerUseLoop(executor: executor, options: options, apiKey: key,
                                   tokenProvider: tokenProvider)

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
