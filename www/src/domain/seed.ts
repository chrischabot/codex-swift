// Seed data for the in-memory MockConnector. Project / thread names mirror
// the actual Fabric stack (diminuendo / podium / ensemble / chronicle /
// unison / fabric / agents) so the UI demonstrates realistic-looking
// content for the diminuendo backend it will eventually drive.

import type {
  Automation,
  AutomationTemplate,
  DiffFile,
  Hook,
  McpServer,
  Message,
  Plugin,
  PluginApp,
  Project,
  Skill,
  Thread,
  TimelineEvent,
} from "./models";

export const seedProjects: Project[] = [
  { id: "p-diminuendo", name: "diminuendo", workingDirectory: "~/Projects/fabric/diminuendo", kind: "git" },
  { id: "p-podium",     name: "podium",     workingDirectory: "~/Projects/fabric/podium",     kind: "git" },
  { id: "p-ensemble",   name: "ensemble",   workingDirectory: "~/Projects/fabric/ensemble",   kind: "git" },
  { id: "p-chronicle",  name: "chronicle",  workingDirectory: "~/Projects/fabric/chronicle",  kind: "git", collapsed: true },
  { id: "p-unison",     name: "unison",     workingDirectory: "~/Projects/fabric/unison",      kind: "git", collapsed: true },
  { id: "p-fabric",     name: "fabric",     workingDirectory: "~/Projects/fabric/fabric",      kind: "git" },
  { id: "p-agents",     name: "agents",     workingDirectory: "~/Projects/fabric/diminuendo/agents", kind: "plain" },
];

export const seedThreads: Thread[] = [
  // Pinned
  {
    id: "t-pin-fabric-server",
    projectId: "p-diminuendo",
    title: "Fabric server: tighten ingress auth",
    pinned: true,
    status: "active",
    updatedAt: Date.now() - 3600_000,
    hotkey: "⌘1",
    approval: "full-access",
    modelLabel: "5.5",
    modelTier: "High",
    envKind: "worktree",
  },
  {
    id: "t-pin-podium-gateway",
    projectId: "p-podium",
    title: "Podium gateway WS reconnects",
    pinned: true,
    status: "active",
    updatedAt: Date.now() - 7200_000,
    hotkey: "⌘2",
  },
  {
    id: "t-pin-claude-agent",
    projectId: "p-agents",
    title: "claude-agent: coding-agent transcri…",
    pinned: true,
    status: "active",
    updatedAt: Date.now() - 14400_000,
    hotkey: "⌘3",
  },
  // diminuendo
  {
    id: "t-dim-projection",
    projectId: "p-diminuendo",
    title: "Projection store: drop stale items on TTL",
    status: "active",
    updatedAt: Date.now() - 3_600_000 * 24,
    hotkey: "⌘4",
    approval: "full-access",
    modelLabel: "5.5",
    modelTier: "High",
    envKind: "local",
  },
  // podium
  {
    id: "t-pod-runtime",
    projectId: "p-podium",
    title: "Runtime: forward agent events to bridge",
    status: "active",
    updatedAt: Date.now() - 3_600_000 * 26,
    hotkey: "⌘5",
    approval: "full-access",
    modelLabel: "5.5",
    modelTier: "High",
    envKind: "remote",
  },
  {
    id: "t-pod-sandbox",
    projectId: "p-podium",
    title: "Sandbox: hash workspace before sync",
    status: "active",
    updatedAt: Date.now() - 3_600_000 * 28,
    hotkey: "⌘6",
  },
  // ensemble
  {
    id: "t-ens-arch",
    projectId: "p-ensemble",
    title: "Plan: streaming inference architecture",
    status: "active",
    updatedAt: Date.now() - 3_600_000 * 30,
    hotkey: "⌘7",
    approval: "full-access",
    modelLabel: "5.5",
    modelTier: "High",
  },
  // fabric
  {
    id: "t-fabric-coremerge",
    projectId: "p-fabric",
    title: "Merge fabric/core v1.4 into trunk",
    status: "active",
    updatedAt: Date.now() - 6 * 86_400_000,
  },
  // agents
  {
    id: "t-agents-task1",
    projectId: "p-agents",
    title: "Codex Companion Task: <triage>",
    status: "active",
    updatedAt: Date.now() - 15 * 3_600_000,
  },
  {
    id: "t-agents-task2",
    projectId: "p-agents",
    title: "Codex Companion Task: <follow-up>",
    status: "active",
    updatedAt: Date.now() - 15 * 3_600_000,
  },
  {
    id: "t-agents-podium-sandbox",
    projectId: "p-agents",
    title: "Find podium sandbox confi…",
    status: "active",
    updatedAt: Date.now() - 5 * 86_400_000,
  },
  {
    id: "t-fabric-one-world",
    projectId: "p-fabric",
    title: "Fabric: one-world rollout",
    status: "active",
    updatedAt: Date.now() - 6 * 86_400_000,
  },
];

const projectionDiff: DiffFile = {
  path: "src/projection/store.ts",
  delta: "+42 -8",
  added: 42,
  removed: 8,
  lines: [
    { kind: "header", text: "@@ -120,8 +120,42 @@ export class ProjectionStore {" },
    { kind: "context", oldLine: 120, newLine: 120, text: "  private readonly items = new Map<string, PresentationItem>();" },
    { kind: "context", oldLine: 121, newLine: 121, text: "  private readonly threads = new Map<string, Thread>();" },
    { kind: "removed", oldLine: 122, text: "  // TODO: TTL eviction" },
    { kind: "added", newLine: 122, text: "  private readonly itemAddedAt = new Map<string, number>();" },
    { kind: "added", newLine: 123, text: "  private readonly ttlMs: number;" },
    { kind: "context", oldLine: 124, newLine: 124, text: "" },
    { kind: "removed", oldLine: 125, text: "  constructor() {}" },
    { kind: "added", newLine: 125, text: "  constructor(opts: { ttlMs?: number } = {}) {" },
    { kind: "added", newLine: 126, text: "    this.ttlMs = opts.ttlMs ?? 30 * 60_000;" },
    { kind: "added", newLine: 127, text: "  }" },
    { kind: "added", newLine: 128, text: "" },
    { kind: "added", newLine: 129, text: "  addItem(item: PresentationItem): void {" },
    { kind: "added", newLine: 130, text: "    this.items.set(item.id, item);" },
    { kind: "added", newLine: 131, text: "    this.itemAddedAt.set(item.id, Date.now());" },
    { kind: "added", newLine: 132, text: "    this.evictExpired();" },
    { kind: "added", newLine: 133, text: "  }" },
    { kind: "gap", text: "8 unmodified lines" },
    { kind: "added", newLine: 142, text: "  private evictExpired(): void {" },
    { kind: "added", newLine: 143, text: "    const cutoff = Date.now() - this.ttlMs;" },
    { kind: "added", newLine: 144, text: "    for (const [id, addedAt] of this.itemAddedAt) {" },
    { kind: "added", newLine: 145, text: "      if (addedAt < cutoff) {" },
    { kind: "added", newLine: 146, text: "        this.items.delete(id);" },
    { kind: "added", newLine: 147, text: "        this.itemAddedAt.delete(id);" },
    { kind: "added", newLine: 148, text: "      }" },
    { kind: "added", newLine: 149, text: "    }" },
    { kind: "added", newLine: 150, text: "  }" },
  ],
};

const projectionTestDiff: DiffFile = {
  path: "src/projection/store.test.ts",
  delta: "+24 -0",
  added: 24,
  removed: 0,
  lines: [
    { kind: "header", text: "@@ -0,0 +1,24 @@" },
    { kind: "added", newLine: 1, text: 'import { describe, it, expect } from "vitest";' },
    { kind: "added", newLine: 2, text: 'import { ProjectionStore } from "./store";' },
    { kind: "added", newLine: 3, text: "" },
    { kind: "added", newLine: 4, text: 'describe("ProjectionStore", () => {' },
    { kind: "added", newLine: 5, text: '  it("evicts items older than TTL", async () => {' },
    { kind: "added", newLine: 6, text: "    const store = new ProjectionStore({ ttlMs: 10 });" },
    { kind: "added", newLine: 7, text: '    store.addItem({ id: "x", kind: "text", text: "hi" });' },
    { kind: "added", newLine: 8, text: "    await new Promise((r) => setTimeout(r, 25));" },
    { kind: "added", newLine: 9, text: '    store.addItem({ id: "y", kind: "text", text: "bye" });' },
    { kind: "added", newLine: 10, text: '    expect(store.getItem("x")).toBeUndefined();' },
    { kind: "added", newLine: 11, text: '    expect(store.getItem("y")).toBeDefined();' },
    { kind: "added", newLine: 12, text: "  });" },
    { kind: "added", newLine: 13, text: "});" },
  ],
};

export const seedMessages: Message[] = [
  // ensemble: Plan streaming inference — shows mermaid + multiple shell blocks
  {
    id: "m-ens-1",
    threadId: "t-ens-arch",
    role: "user",
    blocks: [{ type: "markdown", content: "Plan: streaming inference architecture" }],
    createdAt: Date.now() - 3 * 86_400_000,
  },
  {
    id: "m-ens-2",
    threadId: "t-ens-arch",
    role: "assistant",
    preamble: "Worked for 6m 12s",
    blocks: [
      {
        type: "markdown",
        content: `Here is the proposed split. Ensemble owns model inference, Podium owns the runtime envelope, Diminuendo handles client ingress. Tokens stream client-bound; metadata flows to Chronicle.`,
      },
      {
        type: "mermaid",
        content: `flowchart LR
  Client[Web / Desktop / TUI] -- WS --> Dim[Diminuendo]
  Dim -- HTTP --> Pod[Podium]
  Pod -- gRPC --> Ens[Ensemble]
  Ens -- token stream --> Pod
  Pod -- presentation/items --> Dim
  Dim -- replay --> Client
  Pod -- write --> Chr[Chronicle]`,
      },
      {
        type: "markdown",
        content: `Bring-up: verify the ensemble GPU node responds with the expected version banner before pinning the model graph:

\`\`\`bash
curl -s http://ensemble.internal/healthz | jq .
ensemble-cli graph --pin core@1.4
\`\`\`

And a minimal TypeScript stub for the ingress envelope:

\`\`\`ts
export type IngressInputPart =
  | { kind: "text"; text: string }
  | { kind: "image"; url: string }
  | { kind: "attachment"; mime: string; bytes: Uint8Array };
\`\`\`

Worst-case backpressure $L_{\\max} = O(n \\log n)$ when Podium queues per-thread:

$$
\\sum_{i=1}^{n} \\frac{1}{i} \\approx \\ln n + \\gamma
$$`,
      },
    ],
    createdAt: Date.now() - 3 * 86_400_000 + 60_000,
  },
  // diminuendo: Projection store TTL
  {
    id: "m-dim-1",
    threadId: "t-dim-projection",
    role: "user",
    blocks: [{ type: "markdown", content: "Projection store keeps every item forever — add TTL eviction" }],
    createdAt: Date.now() - 3_600_000 * 24,
  },
  {
    id: "m-dim-2",
    threadId: "t-dim-projection",
    role: "assistant",
    preamble: "Worked for 1hr 12s",
    blocks: [
      {
        type: "markdown",
        content: `Right call. The projection store grows unbounded because we never evict items past their useful window. I added a TTL (default 30 minutes) and a test that proves eviction.

- [src/projection/store.ts](#) — TTL field, \`addItem\` records arrival time, \`evictExpired\` runs on add and on tick.
- [src/projection/store.test.ts](#) — eviction proof using Vitest fake timers.
- [src/projection/types.ts](#) — no breaking changes to \`PresentationItem\`.

**Validation passed:**`,
      },
      {
        type: "tool-call",
        tool: "Read",
        args: { file_path: "src/projection/store.ts" },
        result: "Read 184 lines.",
        status: "ok",
      },
      {
        type: "tool-call",
        tool: "Edit",
        args: { file_path: "src/projection/store.ts", old_string: "// TODO: TTL eviction", new_string: "private readonly itemAddedAt = new Map<string, number>();\nprivate readonly ttlMs: number;" },
        result: "Replaced 1 occurrence.",
        status: "ok",
      },
      {
        type: "shell",
        cwd: "bash",
        cmd: "bun test src/projection",
        output: "pass  src/projection/store.test.ts\nTests:  4 passed, 4 total\nTime:   0.42s\nALL SUITES: PASS",
        status: "ok",
      },
      {
        type: "markdown",
        content: `Existing warnings remain unrelated: Sentry-init complains under hot-reload, and the Bun ts plugin emits a deprecation for \`type\`-only imports. Both are pre-existing.`,
      },
      {
        type: "attachments",
        items: [
          { id: "att-1", kind: "file", name: "STORE.md", badge: "Document - MD" },
          { id: "att-2", kind: "file", name: "TTL_EVICTION.md", badge: "Document - MD" },
          { id: "att-3", kind: "file", name: "BENCHMARKS.md", badge: "Document - MD" },
        ],
      },
      {
        type: "diff-summary",
        label: "Edited 3 files",
        added: 66,
        removed: 8,
        files: [
          { path: "src/projection/store.ts", delta: "+42 -8" },
          { path: "src/projection/store.test.ts", delta: "+24 -0" },
        ],
        collapsedExtraFiles: 1,
      },
    ],
    createdAt: Date.now() - 3_500_000 * 24,
  },
];

export const diminuendoDiffFiles: DiffFile[] = [projectionDiff, projectionTestDiff];

export const seedPluginsFeatured: Plugin[] = [
  { id: "spreadsheets",   name: "Spreadsheets",     description: "Create and edit spreadsheets",            icon: "📊", category: ["Featured", "Built by OpenAI"] },
  { id: "presentations",  name: "Presentations",    description: "Create and edit presentations",            icon: "📈", category: ["Featured", "Built by OpenAI"] },
  { id: "github",         name: "GitHub",           description: "Access repositories, issues, and PRs",     icon: "GH", iconBg: "#0d0d0d", category: ["Featured", "Built by OpenAI"] },
  { id: "slack",          name: "Slack",            description: "Read and manage Slack",                    icon: "S",  iconBg: "#4a154b", category: ["Featured", "Built by OpenAI"] },
  { id: "notion",         name: "Notion",           description: "Notion workflows for specs, research,…",  icon: "N",  iconBg: "#000",    category: ["Featured", "Built by OpenAI"] },
  { id: "linear",         name: "Linear",           description: "Read and reference issues and projects",  icon: "L",  iconBg: "#5e6ad2", category: ["Featured", "Built by OpenAI"] },
  { id: "statsig",        name: "Statsig",          description: "Bring your Statsig workspace inline",     icon: "ST", iconBg: "#1d1d1d", category: ["Featured", "Built by OpenAI"] },
  { id: "gmail",          name: "Gmail",            description: "Read and manage Gmail",                   icon: "✉",  iconBg: "#ea4335", category: ["Featured", "Built by OpenAI"] },
  { id: "gcal",           name: "Google Calendar",  description: "Manage Google Calendar events and…",     icon: "📅", iconBg: "#4285f4", category: ["Featured", "Built by OpenAI"] },
  { id: "gdrive",         name: "Google Drive",     description: "Work with Google Docs, Sheets, and…",    icon: "▲",  iconBg: "#1aa260", category: ["Featured", "Built by OpenAI"] },
  { id: "teams",          name: "Teams",            description: "Summarize Teams and draft follow-up",     icon: "T",  iconBg: "#5059c9", category: ["Featured", "Built by OpenAI"] },
  { id: "sharepoint",     name: "SharePoint",       description: "Summarize SharePoint sites and files",    icon: "SP", iconBg: "#038387", category: ["Featured", "Built by OpenAI"] },
  { id: "outlook-email",  name: "Outlook Email",    description: "Triage Outlook inboxes and draft…",      icon: "O",  iconBg: "#0078d4", category: ["Featured", "Built by OpenAI"] },
  { id: "outlook-cal",    name: "Outlook Calendar", description: "Summarize Outlook schedules and…",       icon: "O",  iconBg: "#0078d4", category: ["Featured", "Built by OpenAI"] },
  { id: "figma",          name: "Figma",            description: "Design to code workflows powered b…",    icon: "F",  iconBg: "#1e1e1e", category: ["Featured", "Built by OpenAI"] },
  { id: "vercel",         name: "Vercel",           description: "Build and deploy web apps and agents",    icon: "▲",  iconBg: "#000",    category: ["Featured", "Built by OpenAI"] },
];

export const seedApps: PluginApp[] = [
  { id: "alltrails",     name: "AllTrails",        description: "Discover your next hike",                                      iconLetter: "A",  iconBg: "#2c5f2d", enabled: true },
  { id: "github-app",    name: "GitHub",           description: "Access repositories, issues, and pull requests.",              iconLetter: "G",  iconBg: "#0d0d0d", enabled: true },
  { id: "gmail-app",     name: "Gmail",            description: "Find and reference emails from your inbox",                    iconLetter: "✉", iconBg: "#ea4335", enabled: true },
  { id: "gcal-app",      name: "Google Calendar",  description: "Look up events and availability",                              iconLetter: "📅", iconBg: "#4285f4", enabled: true },
  { id: "gcontacts-app", name: "Google Contacts",  description: "Reference saved contact details",                              iconLetter: "👥", iconBg: "#1aa260", enabled: true },
  { id: "gdrive-app",    name: "Google Drive",     description: "Work with Google Docs, Sheets, and Slides",                    iconLetter: "▲",  iconBg: "#1aa260", enabled: true },
];

export const seedAutomationTemplates: AutomationTemplate[] = [
  { id: "scan-commits",  title: "Scan recent commits (since the last run, or last 24h) for likely bugs and propose minimal fixes.", description: "", iconLetter: "🐞", iconBg: "#ffe7d9" },
  { id: "release-notes", title: "Draft weekly release notes from merged PRs (include links when available).",                       description: "", iconLetter: "📒", iconBg: "#e5f3ff" },
  { id: "standup",       title: "Summarize yesterday's git activity for standup.",                                                  description: "", iconLetter: "📣", iconBg: "#f0e7ff" },
  { id: "ci-flakes",     title: "Summarize CI failures and flaky tests from the last CI window; suggest top fixes.",                description: "", iconLetter: "🌀", iconBg: "#e5f3ff" },
  { id: "game",          title: "Create a small classic game with minimal scope.",                                                  description: "", iconLetter: "🎮", iconBg: "#e5f7ee" },
  { id: "skills",        title: "From recent PRs and reviews, suggest next skills to deepen.",                                      description: "", iconLetter: "🧠", iconBg: "#fff4e5" },
  { id: "weekly",        title: "Synthesize this week's PRs, rollouts, incidents, and reviews into a weekly update.",               description: "", iconLetter: "📈", iconBg: "#e5f3ff" },
  { id: "benchmarks",    title: "Compare recent changes to benchmarks or traces and flag regressions early.",                       description: "", iconLetter: "📊", iconBg: "#ffe7d9" },
  { id: "ok",            title: "Daily green-light check.",                                                                         description: "", iconLetter: "✅", iconBg: "#e5f7ee" },
  { id: "alert",         title: "Alert on pipeline regressions.",                                                                   description: "", iconLetter: "🚨", iconBg: "#ffdada" },
];

export const seedAutomations: Automation[] = [];

// ─────────────────────────────────────────────────────────────────────────────
// MCP servers (side-panel MCP_APP tab + Settings > MCP servers).
// ─────────────────────────────────────────────────────────────────────────────
export const seedMcpServers: McpServer[] = [
  {
    id: "mcp-filesystem",
    name: "filesystem",
    command: "npx -y @modelcontextprotocol/server-filesystem ~/Projects/fabric",
    status: "connected",
    toolCount: 6,
    tools: ["read_file", "write_file", "list_directory", "search_files", "move_file", "get_file_info"],
    source: "project",
  },
  {
    id: "mcp-github",
    name: "github",
    command: "npx -y @modelcontextprotocol/server-github",
    status: "connected",
    toolCount: 9,
    tools: ["search_repositories", "get_file_contents", "create_issue", "list_pull_requests", "merge_pull_request"],
    source: "user",
  },
  {
    id: "mcp-postgres",
    name: "postgres",
    command: "npx -y @modelcontextprotocol/server-postgres postgres://localhost/fabric",
    status: "error",
    toolCount: 0,
    tools: [],
    source: "project",
  },
  {
    id: "mcp-puppeteer",
    name: "puppeteer",
    command: "npx -y @modelcontextprotocol/server-puppeteer",
    status: "disabled",
    toolCount: 4,
    tools: ["navigate", "screenshot", "click", "evaluate"],
    source: "user",
  },
];

// ─────────────────────────────────────────────────────────────────────────────
// Per-thread timeline events (side-panel TIMELINE tab). Keyed by thread id.
// ─────────────────────────────────────────────────────────────────────────────
export const seedTimeline: Record<string, TimelineEvent[]> = {
  "t-dim-projection": [
    { id: "tl-1", kind: "turn", title: "Opened thread", detail: "Projection store: drop stale items on TTL", at: Date.now() - 3_600_000 * 24 },
    { id: "tl-2", kind: "file", title: "Read src/projection/store.ts", detail: "184 lines", at: Date.now() - 3_600_000 * 23.9 },
    { id: "tl-3", kind: "file", title: "Edited src/projection/store.ts", detail: "+42 −8", at: Date.now() - 3_600_000 * 23.8 },
    { id: "tl-4", kind: "sandbox", title: "Sandbox ready", detail: "sbx-9f2 · ~/Projects/fabric/diminuendo", at: Date.now() - 3_600_000 * 23.7 },
    { id: "tl-5", kind: "approval", title: "Approved: fetch benchmark suite", detail: "network · allow once", at: Date.now() - 3_600_000 * 23.6 },
    { id: "tl-6", kind: "turn", title: "Tests passed", detail: "4 passed, 4 total · 0.42s", at: Date.now() - 3_600_000 * 23.5 },
  ],
  "t-pin-fabric-server": [
    { id: "tl-f1", kind: "branch", title: "Created worktree", detail: "fabric/ingress-auth", at: Date.now() - 3_600_000 * 2 },
    { id: "tl-f2", kind: "file", title: "Edited server/ingress.ts", detail: "+18 −4", at: Date.now() - 3_600_000 * 1.5 },
    { id: "tl-f3", kind: "commit", title: "Commit", detail: "tighten ingress auth checks", at: Date.now() - 3_600_000 * 1 },
  ],
};

// ─────────────────────────────────────────────────────────────────────────────
// Skills + hooks (Settings + Plugins manage page).
// ─────────────────────────────────────────────────────────────────────────────
export const seedSkills: Skill[] = [
  { id: "skill-pdf", name: "pdf", description: "Extract text and tables from PDF documents", enabled: true, source: "builtin" },
  { id: "skill-frontend", name: "frontend-design", description: "Produce distinctive, production-grade UI", enabled: true, source: "user" },
  { id: "skill-review", name: "code-review", description: "Review a diff for correctness and cleanups", enabled: true, source: "project" },
  { id: "skill-research", name: "deep-research", description: "Fan-out web research with cited synthesis", enabled: false, source: "user" },
];

export const seedHooks: Hook[] = [
  { id: "hook-fmt", event: "PostToolUse", command: "prettier --write $CODEX_EDITED_FILES", enabled: true },
  { id: "hook-test", event: "Stop", command: "bun test --bail", enabled: false },
  { id: "hook-guard", event: "PreToolUse", command: "scripts/guard-protected-paths.sh", enabled: true },
];

// A second changed-file set for the fabric ingress-auth thread, so more than one
// thread surfaces a side-panel diff (the env layer drives which threads have one).
const ingressDiff: DiffFile = {
  path: "server/ingress.ts",
  delta: "+18 -4",
  added: 18,
  removed: 4,
  lines: [
    { kind: "header", text: "@@ -42,7 +42,21 @@ export async function handleIngress(req: Request) {" },
    { kind: "context", oldLine: 42, newLine: 42, text: "  const token = req.headers.get(\"authorization\");" },
    { kind: "removed", oldLine: 43, text: "  if (!token) return new Response(\"unauthorized\", { status: 401 });" },
    { kind: "added", newLine: 43, text: "  if (!token) return deny(req, \"missing bearer token\");" },
    { kind: "added", newLine: 44, text: "  const claims = await verifyJwt(token, { audience: INGRESS_AUD });" },
    { kind: "added", newLine: 45, text: "  if (!claims) return deny(req, \"invalid token\");" },
    { kind: "added", newLine: 46, text: "  if (claims.exp < Date.now() / 1000) return deny(req, \"expired\");" },
    { kind: "context", oldLine: 44, newLine: 47, text: "  return forward(req, claims);" },
    { kind: "context", oldLine: 45, newLine: 48, text: "}" },
  ],
};

export const ingressDiffFiles: DiffFile[] = [ingressDiff];

