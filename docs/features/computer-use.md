# Computer Use (Desktop Control)

*Let the agent drive the real macOS desktop — mouse, keyboard, and screen — to do the GUI-only tasks the shell and file tools can't reach.*

## Why it matters

Most of what an agent does, it does through a terminal: run a command, edit a file, commit, grep. But a real machine has a whole class of work that lives only behind a graphical interface. There is no shell command to flip a toggle in System Settings, to click through a native app's onboarding wizard, or to read a value off a calculator's display.

Picture this: you ask the agent to "turn on Dark Mode" or "open the Calculator and compute 12 x 9." There is no clean CLI for either on a stock Mac. Without desktop control the agent is stuck — it can describe the steps, but it can't take them. Computer Use closes that gap: the agent literally sees the screen and moves the mouse and keyboard, the same way a person would.

That power is also why it needs careful framing. Handing a model the real mouse and keyboard is inherently untrusted, so this feature ships with a dedicated approval gate and is **off by default**.

## What it is

Computer Use is a capability that lets gpt-5.5 operate this Mac's GUI on your behalf. You give it one plain-English task; it runs a closed loop — look at the screen, decide the next UI action, perform it, look again — until the task is done. Concretely it can open apps, click and double-click, type text, press key chords (e.g. ⌘Space, Enter), scroll, and drag.

It shows up in two places:

- **`codex-computer`** — a standalone CLI you point at a task: `codex-computer "open Safari and go to apple.com"`. Good for one-off automation and for verifying the plumbing.
- **`computer_use`** — a first-class agent tool the model can choose mid-conversation, so a normal coding/agent session can reach out and drive the GUI when (and only when) nothing else will do.

It was live-validated end to end: `codex-computer "open the Calculator app and compute 12 x 9"` opened Calculator via Spotlight, typed `1 2 * 9 ⏎`, and left **108** on screen.

## How it works

Under the hood is an agent loop talking to OpenAI's native `computer` tool. The model reasons over screenshots and returns `computer_call` actions; the executor performs them on the real desktop and replies with a fresh screenshot. Two halves do the physical work:

- **Eyes** — `screencapture -x -t png -D 1` grabs the *main* display, then the image is resized to ~1280px wide (aspect preserved; full Retina res is wasteful) and sent to the model.
- **Hands** — CoreGraphics `CGEvent` synthesizes mouse moves/clicks/drags/scroll and keyboard input. Model coordinates (in screenshot space) are mapped back to on-screen points.

```
task ─► screenshot ─► model returns computer_call(s) ─► execute via CGEvent
          ▲                                                     │
          └──────── send fresh screenshot (computer_call_output)◄┘
                       repeat until the model stops acting (or max steps)
```

A few mechanism details worth a correct mental model:

- The loop uses the **non-streaming Responses API**, chaining turns with `previous_response_id`, so it can parse `computer_call` / `computer_call_output` items directly.
- gpt-5.5's tool is the **bare `{"type":"computer"}`** — no `display_width`/`display_height`/`environment` params (those are rejected). The model infers the screen from the screenshots; the resize width is purely our concern for coordinate mapping.
- The map deliberately tracks `CGDisplayBounds(CGMainDisplayID())` (the `-D 1` display), **not** `NSScreen.main` (the keyboard-focused screen). On a multi-monitor setup those diverge, and using the wrong one makes every click land on the wrong display.
- It needs two macOS TCC permissions, granted to whatever binary hosts it: **Screen Recording** (for the capture) and **Accessibility** (for synthetic input). The loop preflights both and fails with an actionable message if either is missing.

### Integration without bloating the agent

The native `computer` tool round-trips images, which the main agent's `function_call`-based protocol doesn't model. Rather than thread image handling through the whole protocol/streaming/context stack, `computer_use` is exposed as an ordinary **function tool** whose handler runs the native loop to completion. The screenshots stay *inside* that sub-loop — the agent gets back a compact action trace plus the loop's final message, so its context and rollout are never flooded with images. (Same delegation pattern used for sub-agents.)

## Using it

### The standalone CLI

Prereqs: an `OPENAI_API_KEY` in the environment, plus Screen Recording and Accessibility permissions for the binary.

```
# permission preflight only (no task)
codex-computer --check

# run a task
codex-computer "open the Calculator app and compute 12 x 9"

# capture a screenshot to a file (verifies Screen Recording + capture path)
codex-computer --screenshot /tmp/shot.png
```

Flags:

| Flag | Meaning |
|------|---------|
| `--width N` | Screenshot/model image width (default 1280). |
| `--max-steps N` | Cap on screenshot→action iterations (default 40; must be a positive integer). |
| `--effort low\|medium\|high\|xhigh` | gpt-5.5 reasoning effort (default `low`, recommended for computer use; validated up front — `minimal` is **not** valid). |
| `--no-confirm` | Don't pause on OpenAI safety checks; proceed and auto-acknowledge. |
| `--dry-run` | Log the actions but do **not** touch mouse/keyboard. |

What you see: a streaming progress log — permission status, the initial screenshot capture, then per-step lines like `• step 3: click @640,400` and `• step 4: type "12*9"`, ending in `✓ done after N step(s): …` and a final result line.

### Inside an agent session

The `computer_use` tool is **opt-in and off by default** (keeps the upstream-parity tool list and tests unchanged). The real runtimes — `codex-session` and `codexd` — enable it only for **LOCAL** sessions (`remoteEnvironment == nil`): a remote-exec session controls a container, not this host, so driving the local desktop would be meaningless. It is also macOS-gated (`#if canImport(AppKit)`). Registration flows through `DefaultTools.register(... computerUseEnabled:)`.

When enabled, the model can call `computer_use` with a single `task` string (and optional `max_steps`, capped at 60). The tool needs a **direct** `OPENAI_API_KEY` in the session environment — the gpt-5.5 `computer` tool is separate from the session's chat auth — and returns an actionable error if it's missing.

### The approval posture (safety)

Because handing the model the mouse and keyboard is inherently untrusted, `computer_use` gets its own approval category, **`.hostControl`** — not the command/patch escalation path (whose escalate branch would mis-run the JSON args as a shell command). It has no sandbox to escalate out of, so the gate is binary: prompt-then-run, or run.

- Under cautious policies (`unlessTrusted`, `onRequest`, and `granular`) the session **prompts first**: *"Allow the agent to control this Mac's desktop (mouse, keyboard, screen)?"* Choosing *accept for session* is remembered so you aren't re-prompted every call.
- Under `never` and `onFailure` it runs without a prompt — the tool is already opt-in per session.
- `granular` **always** prompts, deliberately: there's no sandboxed fallback, so mapping it to the sandbox-approval flag would invert the safety meaning.

Layered beneath the human gate is OpenAI's own `pending_safety_checks`. The standalone CLI **blocks by default** on any flagged action (use `--no-confirm` to proceed). The integrated tool — already behind the human `.hostControl` prompt — auto-acknowledges only the benign navigation checks (`sensitive_domain`, `irrelevant_domain`, raised on routine bank/login/email pages) and **blocks** `malicious_instructions` and any *unrecognized* code, so a prompt-injected high-risk action stops rather than running unattended. Safety checks are also pre-scanned across all calls in a step *before* any action fires, so a blocked check can't leave the desktop half-driven. The loop also honors cancellation promptly (an interrupted turn stops mid-batch).

## What it enables

- **GUI-only work becomes reachable.** Native-app onboarding, System Settings toggles, screenshots of a rendered page, clicking through interfaces with no CLI — the agent can now actually do these, not just describe them.
- **One model, both modalities.** gpt-5.5 natively supports the `computer` tool, so the same model that writes and runs code can also drive the GUI when that's the only path.
- **Clean composition.** Because `computer_use` is just another function tool with its own approval op, it slots into the existing tool surface alongside `shell`, `apply_patch`, and friends without touching the protocol/streaming/context machinery. The guidance is explicit: use it *only* for genuine GUI/desktop automation; anything achievable in a terminal should go through the shell/file/code tools, which are faster and more reliable.

It pairs naturally with the [Web Gateway](./web-gateway.md) and the session runtimes — a daemon or local session can opt the capability in for trusted local work.

## Status

Shipped and live-validated, but with honest edges. It is **off by default** and macOS-only. As of #7 the integrated tool now drives the loop with the **session's OAuth bearer** when the session authenticates via ChatGPT (broker / stored auth): `ComputerUseTool.tokenProvider` prefers a non-blank session token over `OPENAI_API_KEY`, and the loop **re-resolves the bearer before each request** so a long desktop run survives an OAuth-token refresh — falling back to a direct `OPENAI_API_KEY` only when no OAuth token is available. It is gated OFF under a mock model (so a mock session never reaches the live API via the env fallback). Deferred TODOs: a kill-switch hotkey, ScreenCaptureKit (instead of shelling out to `screencapture`), and multi-display support (today it targets the single main display).

## Go deeper

Internals: `Sources/ComputerUse/ComputerUseLoop.swift` (the action loop + safety gating), `Sources/ComputerUse/ComputerUseExecutor.swift` (screenshot + CGEvent eyes/hands + coordinate mapping), `Sources/Tools/ComputerUseTool.swift` (agent-tool wrapper), `Sources/codex-computer/main.swift` (the CLI), and the approval posture in `Sources/HarnessCore/Approvals.swift` (`decideHostControl`) and `Sources/HarnessCore/SessionEngine.swift` (the `.hostControl` gate).
