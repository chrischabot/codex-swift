// Domain models for the diminuendo-shadcn UI. The block kinds mirror Fabric's
// `PresentationBlock` union (clients/shared/src/fabric/types.ts and
// @fabric/core's profile-presentation). Each kind has a dedicated renderer
// under `src/components/chat/blocks/`. The visual treatment is modeled after
// the Codex.app decompiled bundles at /Users/chabotc/Projects/CodexApp/output.

export type ID = string;

export type ApprovalMode = "full-access" | "approval-required" | "read-only";

export type ModelTier = "Low" | "Medium" | "High";

export interface Model {
  id: string;
  label: string;
  tiers: ModelTier[];
}

export interface Project {
  id: ID;
  name: string;
  workingDirectory: string;
  pinned?: boolean;
  collapsed?: boolean;
  // Whether the working directory is a git repo ("git") or a plain folder
  // ("plain"). Drives the HomePage heading copy ("What should we build in X?"
  // vs the shorter fallback) matching the original home-page-greeting module.
  kind?: "git" | "plain";
}

export type ThreadStatus = "active" | "archived";

export interface Thread {
  id: ID;
  projectId: ID | null;
  title: string;
  pinned?: boolean;
  status: ThreadStatus;
  unread?: boolean;
  updatedAt: number;
  hotkey?: string;
  approval?: ApprovalMode;
  modelLabel?: string;
  modelTier?: ModelTier;
  // Where the agent runs for this thread. Drives the thread-header environment
  // icon (Monitor / Cloud / GitBranch) matching the original env-kind chip.
  envKind?: "local" | "remote" | "worktree" | "cloud";
}

export interface MessageAttachment {
  id: ID;
  // "comment" = a code comment with a line range; "pull-request" = a PR ref.
  kind: "file" | "image" | "comment" | "pull-request";
  name: string;
  mime?: string;
  badge?: string;
  // For comment attachments: the file + line range the comment targets.
  lineRange?: string;
}

export type MessageRole = "user" | "assistant" | "system";

// ─────────────────────────────────────────────────────────────────────────────
// Block kinds — one variant per Fabric PresentationBlock kind.
// Each carries a `status` (when streaming-aware) and an optional `blockId`
// that lets the connector apply deltas.
// ─────────────────────────────────────────────────────────────────────────────

export type BlockStatus = "streaming" | "ok" | "error" | "cancelled";

export type MessageBlock =
  | { type: "markdown"; blockId?: string; content: string; status?: BlockStatus }
  // Internal reasoning chain (rendered shimmery + collapsed by default)
  | { type: "thinking"; blockId?: string; content: string; status?: BlockStatus }
  // Auto-summarization indicator (collapsed view of one or more turns)
  | { type: "summary"; blockId?: string; content: string }
  | { type: "code"; blockId?: string; language: string; content: string; status?: BlockStatus }
  // Output of executed code (distinct visual from `code`)
  | {
      type: "code-result";
      blockId?: string;
      language?: string;
      content: string;
      exitCode?: number | null;
      status?: BlockStatus;
    }
  // Shell / terminal exec block. `cwd` is the working dir, `cmd` the command.
  | {
      type: "shell";
      blockId?: string;
      cwd?: string;
      cmd: string;
      output?: string;
      exitCode?: number;
      status?: BlockStatus;
    }
  | { type: "mermaid"; blockId?: string; content: string; status?: BlockStatus }
  // Pretty-printed JSON (fold/unfold per node)
  | { type: "json"; blockId?: string; value: unknown; status?: BlockStatus }
  // Inline tool call card (Bash / Read / Edit / Write / Search / WebFetch)
  | {
      type: "tool-call";
      blockId?: string;
      tool: string;
      args: Record<string, unknown>;
      result?: string;
      status?: BlockStatus;
      // Optional richer summary line ("Read 184 lines.")
      summary?: string;
    }
  // Result of a previous tool call (when separately presented)
  | { type: "tool-result"; blockId?: string; tool: string; output: unknown; status?: BlockStatus }
  // A single file diff inline in the chat
  | {
      type: "diff";
      blockId?: string;
      path: string;
      oldText?: string | null;
      newText?: string;
      unifiedDiff?: string;
      added?: number;
      removed?: number;
    }
  // Compact rollup card pointing at the side-panel diff
  | {
      type: "diff-summary";
      blockId?: string;
      label: string;
      added: number;
      removed: number;
      files: { path: string; delta: string }[];
      collapsedExtraFiles?: number;
    }
  | { type: "attachments"; blockId?: string; items: MessageAttachment[] }
  | { type: "image"; blockId?: string; url: string; alt?: string; mime?: string }
  | { type: "audio"; blockId?: string; url: string; filename?: string }
  | { type: "video"; blockId?: string; url: string; filename?: string }
  // Embedded PDF / docx / xlsx (uses the same card as the document panel)
  | { type: "document"; blockId?: string; url: string; filename: string; mime?: string }
  // External link / file reference / artifact reference rendered as a card
  | { type: "ref"; blockId?: string; uri: string; title?: string; refKind?: "resource" | "file" | "artifact" }
  // Numbered list of source citations (for search/RAG agents)
  | {
      type: "citations";
      blockId?: string;
      items: { title?: string; url: string; snippet?: string }[];
    }
  // Inline approval-required card — distinct from the side-panel inbox
  | {
      type: "approval";
      blockId?: string;
      approvalId: string;
      kind: "exec" | "patch" | "network" | "delivery" | "custom";
      title: string;
      detail?: string;
      risk?: "safe" | "low" | "modify" | "network" | "destructive";
      command?: string[];
      cwd?: string;
      patch?: string;
      decisions?: ("allow_once" | "allow_always" | "deny_once" | "deny_always" | "cancel")[];
      decided?: "allowed" | "denied" | "cancelled";
      // Some approvals double as an MCP elicitation: render a field form and
      // reply via the {action, content} channel instead of {decision}.
      prompt?: string;
      fields?: QuestionField[];
      elicitation?: boolean;
    }
  // Inline question form (text / choice / boolean)
  | {
      type: "question";
      blockId?: string;
      questionId: string;
      title: string;
      prompt?: string;
      fields: QuestionField[];
      answer?: Record<string, unknown>;
    }
  // Plan checklist (mission-style)
  | {
      type: "plan";
      blockId?: string;
      title?: string;
      steps: { id: string; content: string; status: "pending" | "in_progress" | "completed" }[];
    }
  // High-level mission dashboard (longer-lived than a single plan)
  | {
      type: "mission";
      blockId?: string;
      missionId: string;
      status: "running" | "paused" | "completed" | "failed" | "halted" | "error";
      features: { id: string; label: string; status: "pending" | "running" | "completed" | "failed" }[];
      metrics: { elapsed: number; completed: number; failed: number; total: number };
    }
  // "N previous messages summarized into <summary>" indicator
  | {
      type: "compaction";
      blockId?: string;
      summary: string;
      compactedCount: number;
    }
  // Sandbox lifecycle marker
  | {
      type: "sandbox";
      blockId?: string;
      event: "starting" | "ready" | "stopped" | "crashed";
      sandboxId: string;
      cwd?: string;
      durationMs?: number;
    }
  // Sub-agent invocation (cadenza-agent, research-agent, title-agent, …)
  | {
      type: "sub-agent";
      blockId?: string;
      agentId: string;            // "claude-agent" | "research-agent" | …
      agentName: string;          // pretty name
      goal: string;               // 1-line description of why it was invoked
      childThreadId?: string;     // open in side panel
      status: "running" | "ok" | "error";
      summary?: string;           // post-hoc summary line
    }
  // Web fetch — URL + favicon + status
  | {
      type: "web-fetch";
      blockId?: string;
      url: string;
      title?: string;
      status?: "fetching" | "ok" | "error";
      contentSnippet?: string;
    }
  // Browser action (the agent navigated / clicked something)
  | {
      type: "browser-action";
      blockId?: string;
      action: "navigate" | "click" | "type" | "screenshot";
      target: string;
      screenshotUrl?: string;
    }
  // Error / retry banner
  | {
      type: "error";
      blockId?: string;
      message: string;
      code?: string;
      retryable?: boolean;
    }
  // Token-usage chip (when the agent surfaces it inline)
  | {
      type: "token-usage";
      blockId?: string;
      input: number;
      output: number;
      cacheRead?: number;
      cost?: number;
    }
  // Model switch announcement ("switched to Sonnet for this turn")
  | {
      type: "model-switch";
      blockId?: string;
      from?: string;
      to: string;
      reason?: string;
    }
  // Visual separator with optional label ("Phase 2: implementation")
  | { type: "section-heading"; blockId?: string; label: string };

export interface QuestionField {
  id: string;
  label: string;
  kind: "text" | "choice" | "boolean";
  required?: boolean;
  options?: string[]; // when kind === "choice"
}

export interface Message {
  id: ID;
  threadId: ID;
  role: MessageRole;
  preamble?: string;          // "Worked for 24m 45s" — or "Working" while live
  blocks: MessageBlock[];
  createdAt: number;
  // Optional metadata for the message header / actions
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
}

export type DiffLineKind = "context" | "added" | "removed" | "header" | "gap";

export interface DiffLine {
  kind: DiffLineKind;
  oldLine?: number;
  newLine?: number;
  text: string;
}

export interface DiffFile {
  path: string;
  delta: string;
  added: number;
  removed: number;
  lines: DiffLine[];
  // File-level change kind — drives the per-file badge in the diff panel.
  kind?: "added" | "deleted" | "renamed" | "binary" | "modified";
}

export interface DiffEnvironment {
  changes: { added: number; removed: number };
  local: boolean;
  branch: string;
  hasCommit: boolean;
  sources: { id: ID; label: string; icon?: string }[];
}

export type PluginCategory = "Featured" | "Built by OpenAI" | "All";

export interface Plugin {
  id: ID;
  name: string;
  description: string;
  icon: string;
  iconBg?: string;
  category: PluginCategory[];
  installed?: boolean;
}

export interface PluginApp {
  id: ID;
  name: string;
  description: string;
  iconLetter: string;
  iconBg: string;
  enabled: boolean;
}

export interface AutomationTemplate {
  id: ID;
  title: string;
  description: string;
  iconLetter: string;
  iconBg: string;
}

export interface Automation {
  id: ID;
  name: string;
  schedule: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Side-panel + settings surfaces.
// ─────────────────────────────────────────────────────────────────────────────

// An MCP server registered with the host — surfaced in the side-panel MCP tab
// (app-shell-tab-controller.js MCP_APP) and the Settings > MCP servers section.
export interface McpServer {
  id: ID;
  name: string;
  command: string;
  status: "connected" | "connecting" | "error" | "disabled";
  toolCount: number;
  tools?: string[];
  source?: "user" | "project";
}

// A single entry in the thread TIMELINE tab — turns, commits, approvals,
// sandbox lifecycle, file edits. Mirrors the original timeline event stream.
export interface TimelineEvent {
  id: ID;
  kind: "turn" | "commit" | "approval" | "sandbox" | "file" | "branch";
  title: string;
  detail?: string;
  at: number;
}

// A recommended/installed skill — Settings > Skills + Plugins manage page.
export interface Skill {
  id: ID;
  name: string;
  description: string;
  enabled: boolean;
  source?: "user" | "project" | "builtin";
}

// A registered host hook — Settings > Hooks + Plugins manage page.
export interface Hook {
  id: ID;
  event: string; // "PreToolUse" | "PostToolUse" | "Stop" | …
  command: string;
  enabled: boolean;
}
